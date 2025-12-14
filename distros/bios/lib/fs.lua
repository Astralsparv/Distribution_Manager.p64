--[[

	fs.lua

	filesystem / pod

]]


do


	local _env = env
	local _sandbox = _env().sandbox
	local _signal = _signal
	local _send_message = _send_message

	local _fetch_local = _fetch_local
	local _fetch_remote = _fetch_remote
	local _fetch_anywhen = _fetch_anywhen
	local _list_anywhen_by_day = _list_anywhen_by_day
	local _list_anywhen_by_loc = _list_anywhen_by_loc
	local _list_anywhen_folder_moment = _list_anywhen_folder_moment
	local _fetch_remote_result = _fetch_remote_result
	local _store_local = _store_local
	local _cache_store = _cache_store
	local _cache_fetch = _cache_fetch

	local _fetch_userland
	local _store_userland
	local _fstat_userland

	local _fetch_metadata_from_file = _fetch_metadata_from_file
	local _store_metadata_str_to_file = _store_metadata_str_to_file
	local _pod = _pod
	local _fstat = _fstat
	local _pwd = _pwd
	local _mount = mount
	local _cd = _cd
	local _rm = _rm
	local _cp = _cp
	local _mv = _mv
	local _ls = _ls
	local _normalise_userland_path = _normalise_userland_path
	local _is_well_formed_bbs_path = _is_well_formed_bbs_path
	local _get_process_list = _get_process_list
	local _pid = pid

	local _fcopy = _fcopy
	local _fdelete = _fdelete
	local _fullpath = _fullpath
	local _mkdir = _mkdir

	local _split = split
	local _printh = _printh

	local _yield = yield

	-- fileview can be extended via request_file_access messages
	local fileview = unpod(pod(_env().fileview))


	--[[--------------------------------------------------------------------------------------------------------------------------------

		extra protocols:  bbs // later: anywhen, podnet

		moving protocol handling into userspace means that some functionality normally handled by _fullpath needs 
		to be duplicated: path collapsing (_normalise_userland_path), auto mounting, pwd prefixing

	----------------------------------------------------------------------------------------------------------------------------------]]
	
	-- per-process record of prot://file cached as ram files
	-- later: lower-level mounting? need for writeable protocols (podnet)

	local prot_to_ram_path={}
	local ram_to_prot_path={}

	local prot_driver = {}
	
	-- test protocol
-- [==[
	prot_driver["echo"] = {
--[===[
		store_path_in_ram = function(path)
			mkdir("/ram/echo")					
			local fn=("/ram/echo/"..#prot_to_ram_path)
			if (path:ext()) fn ..= "."..path:ext()
			_store_local(fn, "["..path.."]", "--[[pod]]") -- no metadata; for bbs:// carts could inject bbs_id, bbs_author? too much magic
			return fn
		end,
]===]
		-- can provide instead of store_path_in_ram 
		get_file_contents = function(path)
			return "["..path.."]", "--[[pod]]"
		end,
		get_listing = function(path)
			return{"[listing: "..path.."]"}
		end,
		get_attr = function(path)
			return "file", #path
		end
	}
-- ]==]
	
	local function get_bbs_host()
		-- bbs web player
		if ((stat(317) & 0x3) == 0x1) then
			if (stat(152) == "localhost") return "http://localhost" -- dev
			return "https://www.lexaloffle.com"
		end

		-- any other exports: bbs:// is not supported (to do: explicit error codepath -- just disable bbs:// ? )		
		if ((stat(317) & 0x1) > 0) return ""

		-- binaries: main server
		return "https://www.lexaloffle.com"
	end

	local function get_versioned_cart_url(bbs_id)
		-- bbs web player: just use get_cart for now -- later: use cdn
		if ((stat(317) & 0x3) == 0x1) return get_bbs_host().."/bbs/get_cart.php?cat=8&lid="..bbs_id
		-- exports: bbs:// otherwise not supported 
		if (stat(317) > 0) return ""
		-- binaries: use cdn
		return "https://carts.lexaloffle.com/"..bbs_id..".p64.png"
	end

	--[[
		normalise_anywhen_path()

		want the /@/m/d part to be as far to right as possible, and should immediately follow file

		/desktop/@/2025-08-01/00:00:00/foo.txt -> /desktop/foo.txt/@/2025-08-01/00:00:00.txt

		-- to do: when multiple  /@/m/d groups exist, perhaps remove all but the last?
		--> allows things like: /desktop/@/2025-08-01/00:00:00/foo.txt/@
			~ only really useful for navigation though; perhaps filenav can handle that
			e.g. filenav > anywhen opens a new window showing /desktop/foo.txt/@
			// seems nicer
	]]
	local function normalise_anywhen_path(path)

		if (type(path) ~= "string") return nil
		local lloc, when = unpack(split(path, "@", false)) 
		lloc = lloc:sub(1,-2)

		-- the moment is inside a folder (simple test: no extension. see get_attr
		local is_folder_moment = not lloc:ext()

		if (is_folder_moment) then

			-- move everything on the right to the left hand side location
			-- /desktop/@/2025-08-01/00:00:00/temp -> /desktop/temp/@/2025-08-01/00:00:00
			lloc ..= when:sub(21)
			when = when:sub(1,20) -- /m/d
			if (lloc:ext()) when ..= "."..lloc:ext() -- /desktop/@/2025-08-01/00:00:00/foo.txt -> /desktop/foo.txt/@/2025-08-01/00:00:00.txt
		end

		return lloc.."/@"..when
	end


	-- anywhen://promo/pap/pap_2025.p64/@/2025-08-02_00:00:00.p64/foo.txt
	-- ?pod{fstat"anywhen://promo/pap/pap_2025.p64/@/2025-08-02_00:00:00"}
	-- ?pod{ls"anywhen://promo/pap/pap_2025.p64/@/2025-07-28"}
	
	--[[
		strip_anywhen()
		0.2.0i: canonical userland paths never have anywhen:// in them
		(they are unambiguously identified by containing an @ character)
		--> add anywhen:// when converting from userland -> kernal path, and then strip to get back to userland
	]]
	local function strip_anywhen(s)
		if (type(s) ~= "string") return s
		if (s:prot(true) == "anywhen") return s:sub(10) -- strip "anywhen:/" keep last /
		return s
	end


	local anywhen_id = 1
	local anywhen_to_ram = {}
	prot_driver["anywhen"] = {

		--[[
			figure out where to split (where subpath starts) 
			and also convert timestamp format so that can drag and drop as a local file (can't have : in filename)
			
			anywhen://promo/pap/pap_2025.p64/@/2025-08-02_00:00:00.p64/foo.txt
				anywhen://promo/pap/pap_2025.p64/@/2025-08-02_00:00:00.p64
				/foo.txt
		]]
		extract_cart_path = function(path)

			if (_sandbox) return nil -- never mount anywhen paths from sandboxed process

			path = normalise_anywhen_path(path)

			local c_path, when = unpack(split(path, "@", false))

			if (not c_path or not when or #when < 20 or when[1] ~= "/") return nil -- no path or no time specified or bad format
			
			c_path = c_path:sub(1,-2)  -- anywhen://promo/pap/pap_2025.p64  (trim just to check extension)
			local c_path_ext = c_path:ext() or ""

			if (not c_path_ext:is_cart()) return nil -- not inside a cart

			-- 3. timestamp part /2025-08-02/00:00:00.p64 -> 2025-08-02/00_00_00

			local ts = when:sub(2,14).."_"..when:sub(16,17).."_"..when:sub(19,20)
			c_path = c_path.."/@/"..ts

			-- 2. subpath // everything after date  (/foo.txt)
--
			local subpath = when:sub(21)

			-- remove extension part of when (and move back to c_path
			if (subpath:sub(1,4) == ".p64") then subpath=subpath:sub(5) c_path..=".p64"
				elseif (subpath:sub(1,8) == ".p64.rom") then subpath=subpath:sub(9) c_path..=".p64.rom"
				elseif (subpath:sub(1,8) == ".p64.png") then subpath=subpath:sub(9) c_path..=".p64.png"
			end

--			printh("[extract_cart_path] "..path.." ->\n   ["..c_path.."]\n   ["..subpath.."]")

			return c_path, subpath
			
		end,


		store_path_in_ram = function(path)

			if (path:ext() == "p64") then
				mkdir("/ram/anywhen") -- to do: do once on startup, like /ram/bbs
				
				if (anywhen_to_ram[path]) then
					return anywhen_to_ram[path]
				end

				-- try to grab cart
				--printh("[store_path_in_ram] trying to fetch for storing: "..path:sub(10))
				local ret, meta = _fetch_anywhen(path:sub(10)) -- strip "anywhen:/" (keep one slash)

				if (ret) then
					local fn = "/ram/anywhen/".._pid().."_"..anywhen_id..".p64"
					--printh("\\o/ could fetch to store: "..path:sub(10).."  as  "..fn) 
					anywhen_id += 1
					_store_local(fn, ret, meta) -- no metadata; for bbs:// carts could inject bbs_id, bbs_author? too much magic
					anywhen_to_ram[path] = fn
					return fn
				end

			end
			return nil -- doesn't exist or not a cart
		end,

		-- for files outside of cart
		get_file_contents = function(path)
			path = normalise_anywhen_path(path)
			path = strip_anywhen(path)
			return _fetch_anywhen(path)
		end,

		get_listing = function(path)
			if (type(path) ~= "string") return nil

			path = normalise_anywhen_path(path)

			local filename, when = unpack(split(path, "@", false))
			local local_loc = path:sub(10)

			----------------------------------------------------------------------------------------

			if (not filename:sub(1,-2):ext()) -- inside a folder when left part has no extension (see get_attr)
			then

				if (when and #when == 11) then
					return _list_anywhen_by_day(local_loc) -- /ld/@/2025-08-27
				end

				if (when == "") then
					return _list_anywhen_by_loc(local_loc:sub(1,-2)) -- /desktop/
				end

				-- listing inside a folder
				if (#when >= 20) return _list_anywhen_folder_moment(local_loc)
				return nil
			end

			----------------------------------------------------------------------------------------

			--printh("[anywhen] get_listing "..pod{path, filename, when})
			if (when and #when == 11) then -- e.g. "/2024-07-01"
				--> show days
				return _list_anywhen_by_day(local_loc) -- /foo.p64/@/2025-08-27
			end

			if (when == "") then -- requesting temporal listing at top level (days by location)
				--> show months
				return _list_anywhen_by_loc(local_loc:sub(1,-3)) -- cut off "/@" at end
			end

			if (not when) then

				-- local file -- update: never happens because not handled by anywhen in that case
				if (fstat(local_loc) == "file" or (local_loc:ext() and local_loc:ext():is_cart())) then
					return {"@"}
				end

				-- location is a folder on host --> same listing as local filesystem
				return _ls(local_loc)

			end
			
			return nil
		end,

		-- is a file only when date-time is fully specified
		get_attr = function(path)
			path = normalise_anywhen_path(path)

			local filename, when = unpack(split(path, "@", false))
			local ext = path:ext()

			if (when) then

				-- don't actually search for existence, but at least reject whens that are not well-formed
				-- important in some sitations; e.g. for distinguishing commands from lua statements in terminal!
				-- to do: more thorough form checking
				if (when[1] and when[1] ~= "/" and tonum(when:sub(1,2) ~= nil)) return false

				local when_ext = when:ext()
				local when_ext_len = when_ext and #when_ext+1 or 0
--				printh("when, when_ext, when_ext:is_cart(), len: "..pod{when, when_ext, when_ext:is_cart(), #when - #when_ext})

				if (#when - when_ext_len == 20) then -- "/2025-08-04/00:00:00.p64" with ".p64" removed
					if (when_ext and when_ext:is_cart()) return "folder", 0
					if (not when_ext) then
						-- not looking at something inside the when --> if filename part doesn't have an exention, is a folder
						if (not filename:sub(1,-2):ext()) return "folder", 0 -- e.g. /desktop/@
					end
					return "file", 0 -- points to a particular version of a single file
				end

				if (when_ext_len > 0) return "file", 0
			end			

--[[
			if (when) then
				local ext = path:ext()
				if (not ext or ext:is_cart()) return "folder", 0
				return "file", 0
			end
]]
			-- don't 
			return "folder", 0 -- no when --> folder at top level
		end
	}


	-- per session cache for listings 
	-- to do: review: cache to disk? maybe should be up to the calling app? (ref: splore list)
	local bbs_listing_cache = {}

	prot_driver["bbs"] = {

		extract_cart_path = function(path)
			local cart_path_pos = string.find(path,".p64",1,true) -- true to turn off pattern matching
			if (cart_path_pos) then
				return
					path:sub(1, cart_path_pos+3),  --  bbs://foo.p64
					path:sub(cart_path_pos+4)      --  /main.lua
			end
		end,

		store_path_in_ram = function(path)

			-- can assume /ram/bbs exists; see create_process()

			--printh("bbs store_path_in_ram: "..tostring(path))

			-- bbs://cart/foo.p64  (or bbs://foo.p64!)
			if (path:ext() == "p64") then
				local bbs_id = path:basename():sub(1,-5)
				local fn = "/ram/bbs/"..path:basename()..".png"

				-- already downloaded to ram by another process
				if (fstat(fn)) return fn

				local is_versioned = bbs_id:sub(-2,-2) == "-" or bbs_id:sub(-3,-3) == "-"

				
				--if (is_versioned) then
				if (true) then -- 0.2.0e: prefer used cached version if available (see notes in next block comments)
					-- when versioned, never changes on server so can always use this if it exists
					-- when not versioned, use here if don't want to do agressive automatic updates per-fetch 
					local cached_cart_png = _cache_fetch("carts", bbs_id..".p64.png")
					if (cached_cart_png and #cached_cart_png >= 512) then
						--printh("copying cached cart to ram: "..fn)
						if (not _store_local(fn, cached_cart_png, "format=\"raw\"")) then
							-- found in cache. if unversioned, initiate download of most recent version (non-blocking)
							-- will be cached on successful download
							cart_png, meta, err = _fetch_remote(get_bbs_host().."/bbs/get_cart.php?cat=8&lid="..bbs_id)
							return fn
						else
							--printh("** store_local failed from fs.lua")
						end
					end
				end

				--[[
					0.2.0e: use whatever can be found on disk
					would rather use an older version immedaitely; important when bbs cart is used as a default editor
					but fetch most recent version to cache (will be used on next mount; probably during next session)
					for now happens every time a non-versioned bbs cart is mounted, but in future can:
						- publish a bloom filter of /published/ cart existence (don't want to expose unlisted cart ids in filter)
						- download all-time (512k), hourly (16k) version of filter proactively
						-> only need to fetch here when higher id is found in filters (false positives ok).  // need to store .nfo files to look up local revision
						// store a byte per hash position: val_n = MAX(version, val_n) --> version lower bound on read is MIN{val0, val1 ..} // 255 means unknown
						// if false positives rare enough, can go back to use blocking fetch (and get immediate updates when new cart has been up for > 1h)
				]]
				if (not is_versioned) then
					local cached_cart_png = _cache_fetch("carts", bbs_id.."-%d.p64.png", true)
					if (cached_cart_png and #cached_cart_png >= 512) then
						--printh("copying cached cart to ram: "..fn)
						_store_local(fn, cached_cart_png, "format=\"raw\"")
						return fn
					end
				end

				-- download (blocking)
	
				-- printh("[bbs://] fetching cart from carts.lexaloffle.com/"..bbs_id..".p64.png -> "..fn)

				local cart_png, meta, err 

				if (is_versioned) then
					cart_png, meta, err = fetch(get_versioned_cart_url(bbs_id))
				end

				-- 0.1.1f "< 512": when response is an error message / too short; no legit cart png is < 512 bytes
				-- (happens in several nearyy locations)
				if (type(cart_png) ~= "string" or #cart_png < 512) then 
					-- fall back to origin; might not be on cdn yet?, or cdn is down? or cloudflare rate-limiting requests?
					--printh("get_cart fallback: "..bbs_id)
					cart_png, meta, err = fetch(get_bbs_host().."/bbs/get_cart.php?cat=8&lid="..bbs_id)
				end

				--if(err)printh("bbs prot error on fetch: "..err)
				if (type(cart_png) == "string" and #cart_png >= 512) then
					-- printh("[bbs://] fetched and cache: "..#cart_png.." bytes")
					-- store(fn, cart_png, meta) -- wrong! can't access when sandboxed
					_store_local(fn, cart_png, "format=\"raw\"")
					_cache_store("carts", bbs_id..".p64.png", cart_png)
					return fn
				end

				-- for ids with no version, check in cache *after* trying download
				-- (always want the latest version if it exists)
				-- to do: could also scan for highest versioned copy in cache
				-- to do: remove this section; now checking cache up front, same as versioned carts
				if (not is_versioned) then
					-- printh("[bbs://] attempting to use non-versioned cart from cache")
					local cached_cart_png = _cache_fetch("carts", bbs_id..".p64.png")
					if (cached_cart_png and #cached_cart_png >= 512) then
						store(fn, cached_cart_png, {format="raw"})
						return fn
					end
				end

				return nil, "cart download failed"
				
			end

			-- test
			if (path == "bbs://news.txt") then
				local text_file, meta, err = fetch(get_bbs_host().."/dl/docs/picotron_bbs_news.txt")
				-- printh("@@ downloading: "..get_bbs_host().."/dl/docs/picotron_bbs_news.txt")

				if (type(text_file) == "string" and #text_file > 0) then
					mkdir("/ram/bbs")
					store("/ram/bbs/news.txt", text_file)
					return "/ram/bbs/news.txt"
				else
					return nil, "cart download failed"
				end
			end

			return nil -- couldn't resolve
		end,
	
		get_listing = function(path)

			--printh("bbs:// listing: "..tostring(path))
			
			-- ** not meant as a public endpoint, please use bbs:// instead! **
			local endpoint = get_bbs_host().."/bbs/pod.php?"
			local req

			local p_page = nil
			local q_str = nil

			-- show page 0 instead of pages

			if (sub(path,1,10) == "bbs://new/")       p_page=sub(path,11)  q_str="sub=2"
			if (sub(path,1,10) == "bbs://wip/")       p_page=sub(path,11)  q_str="sub=3"
			if (sub(path,1,15) == "bbs://featured/")  p_page=sub(path,16)  q_str="sub=2&orderby=featured"

			p_page=tonumber(p_page)
			if (type(p_page) == "number" and q_str) req = endpoint.."cat=8&max=32&start_index="..(p_page*32).."&"..q_str


			if (req) then

				-- printh("req:"..pod{path, req})

				local res = nil
				if (bbs_listing_cache[req] and time() < bbs_listing_cache[req].response_t + 10) then
					-- use session cache
					res = bbs_listing_cache[req].response
				else
					--printh("req:"..pod{path, req})
					res = fetch(req)
					if (res) then
						-- store session cache
						bbs_listing_cache[req] = {
							response = res,
							response_t = time()
						}

						-- also start downloading everything!
						for i=1, #res do
							-- start download if doesn't already exist in cache
							if (not _cache_fetch("carts", res[i].id..".p64.png")) then
								--printh("starting background download: "..res[i].id..".p64.png")
								local job_id, err = _fetch_remote(get_versioned_cart_url(res[i].id))
							end
						end


					elseif bbs_listing_cache[req] then
						-- fallback to session cache (e.g. went offline after getting listing a long time ago)
						res = bbs_listing_cache[req].response
					end
				end

				if (res) then
					local list = {}
					for i=1,#res do
						add(list, res[i].id..".p64")
					end
					return list
				end
			end

			if (path == "bbs://") then 
				return{
--[[
					-- visual test: with icons. maybe should be allowed to view by .label / .title when it exists
					-- or specify an icon to replace folder icon when available -- looks nice in list mode
					"\^:0000637736080800 new",
					"\^:00081c7f3e362200 featured",
					"\^:001c14363e777f00 wip",
]]
					"new",
					"featured",
					"wip",
--[[
					-- to do: browse these from settings
					-- use tags; one cart could be a screensaver or a live desktop (and possibly adapt itself!)
					"screensavers",
					"desktops",
					"widgets",
					"themes", -- a cart that demos theme? bundle multiple themes? separate podnet files?
]]
					"news.txt", -- test; probably want news.pod or news.p64 if do something like this
				}
			end

			-- page navigation
			if (path == "bbs://new" or path == "bbs://featured" or path == "bbs://wip") then
				local ret = {}
				for i=0,31 do
					add(ret, tostring(i))
				end
				return ret
			end
		
			return {}
		end,
		get_attr = function(path)
			-- to do: check for existence of top-level folder / file
			if not _is_well_formed_bbs_path(path) then 
				-- e.g. lua command from terminal tried as util command first
				return nil 
			end
--[[
			-- experimental: probe for file existence?
			local l = ls(prot_driver["bbs"].get_listing(path:dirname()))
			local found = false
			for i=1,#l do
				if (fullpath(l[i]) == fullpath(path)) found = true
			end
--			if (not found) return nil
]]
			local ext = path:ext()
			if (ext == "p64") return "folder", 0 -- cart subfolder is ignored
			if (not ext)      return "folder", 0 -- bbs://new
			if (ext == "txt") return "file", 0   -- news.txt
			return nil -- file doesn't exist
		end,
		get_file_contents = function(path)
			-- 0.2.1e // don't store in ram
			if (path == "bbs://news.txt") return fetch(get_bbs_host().."/dl/docs/picotron_bbs_news.txt")
		end
	}

	----------------------------------------------------------------------------------------------------------------------------------
	-- path remapping
	--
	-- rule: local functions (_mkdir) take raw paths ("/appdata/bbs/bbs_id/foo") 
	--       global functions (mkdir) take userland paths ("/appdata/foo")
	----------------------------------------------------------------------------------------------------------------------------------

	local function path_is_inside(path, container_path)
		local len = #container_path -- the shorter string
		if (container_path == "*") return true
		if (type(path) ~= "string") return false
		path = path:path() -- strip hash part 
		return path:sub(1,len) == container_path and (#path == len or path[len + 1] == "/")
	end

	
	--[[
		_kernal_to_userland_path  (was "_un_sandbox_path")
		
		convert from proc->pwd to pwd():

			/appdata/bbs/bbs_id/foo         -->   /appdata/foo     (when sandboxed)
			podnet://1/appdata/bbs_id/foo   -->   podnet://1/foo   (when sandboxed ~ to do)
			bbs://new                        -->   bbs://new        (because not mounted by bbs:// driver)
			/ram/bbs/blah.p64.png            -->   bbs://blah.p64   (because mounted by bbs:// driver)

		** uses protocol driver to mount carts on demand
	]]


	local function _kernal_to_userland_path(path)
		if (type(path) ~= "string") return nil

		-- /ram/bbs/foo-0.p64.png/gfx/foo.gfx   -->   bbs://new/3/foo-0.p64/gfx/foo.gfx

		if (path:sub(1,9) == "/ram/bbs/") then -- optimisation; most of the time this is not true
			local sub_path = ""
			local ram_cart_path = path
			local ram_cart_path_pos = string.find(path,".p64.png",1,true)  -- 0.2.0h: need ,1,true to turn off pattern matching. "." is a wildcard.

			if (ram_cart_path_pos) then
				ram_cart_path = path:sub(1, ram_cart_path_pos+7)  --  /ram/bbs/foo.p64.png
				sub_path = path:sub(ram_cart_path_pos+8)      --  /main.lua
				--printh("sub_path: "..tostring(sub_path))
				--printh("_kernal_to_userland_path // path, ram_cart_path_pos, ram_cart_path, sub_path: "..pod{path, ram_cart_path_pos, ram_cart_path, sub_path})
				if (ram_to_prot_path[ram_cart_path]) then
					return strip_anywhen(ram_to_prot_path[ram_cart_path]..sub_path)
				end
			end
		end

		-- needed so that e.g. fullpath("anywhen://...") doesn't resolve back to /bbs/anywhen/...
		-- to do: build into protocol definition?
		if (path:sub(1,13) == "/ram/anywhen/") then
			local sub_path = ""
			local ram_cart_path = path
			local ram_cart_path_pos = string.find(path,".p64",1,true)
			if (ram_cart_path_pos) then
				ram_cart_path = path:sub(1, ram_cart_path_pos+3)  --  /ram/bbs/foo.p64
				sub_path = path:sub(ram_cart_path_pos+4)      --  /main.lua
				
				--printh("_kernal_to_userland_path // path, ram_cart_path_pos, ram_cart_path, sub_path: "..pod{path, ram_cart_path_pos, ram_cart_path, sub_path})
				if (ram_to_prot_path[ram_cart_path]) then
					-- printh("anywhen sub_path: "..tostring(sub_path).." -> "..ram_to_prot_path[ram_cart_path]..sub_path)
					return strip_anywhen(ram_to_prot_path[ram_cart_path]..sub_path)
				end
			end
		end

		-- no local mapping for a protocol path -> return as-is
		if (path:prot(true)) return strip_anywhen(path)

		-- is local filesystem path
		if (not _sandbox) return path
		
		--[[
			-- /appdata mapping only when bbs_id is set
			-- commented; handled by backwards rewrite rules below
			if (path:sub(1,9) == "/appdata/bbs/" and _env().bbs_id)
			then  
				local bbs_id_base = split(_env().bbs_id, "-", false)[1] -- don't include the version
				local cart_dir = "/appdata/bbs/"..bbs_id_base..path:sub(9)
				local cart_dir_len0 = #cart_dir
				local cart_dir_len1 = #cart_dir + 1
				if path:sub(1, cart_dir_len0) == cart_dir and (#path == cart_dir_len0 or path[cart_dir_len1] == "/") then
					return "/appdata"..path:sub(cart_dir_len1)
				end
			end
		]]

		-- un-rewrite :: /appdata/bbs/bbs_id/foo/a.txt -> /appdata/foo/a.txt
		-- target is:    /appdata/bbs/bbs_id
		-- location is:  /appdata

		if (fileview) then
			for i=1,#fileview do
				if fileview[i].target and path_is_inside(path, fileview[i].target) then
					-- printh("reversed rule: "..path.."  -->  "..fileview[i].location..path:sub(#fileview[i].target + 1))
					return fileview[i].location..path:sub(#fileview[i].target + 1)
				end
			end
		end

		-- no rule applies; return as-is
		return path
	end


	--[[
		_userland_to_kernal_path
		
		convert from pwd() to proc->pwd:

			/appdata/foo     -->   /appdata/bbs/bbs_id/foo         (when sandboxed)
			podnet://1/foo   -->   podnet://1/appdata/bbs_id/foo   (when sandboxed ~ to do)
			bbs://new        -->   bbs://new                        (because not mounted by bbs:// driver)
			bbs://blah.p64   -->   /ram/bbs/blah.p64                (because mounted by bbs:// driver)

		** uses protocol driver to mount carts to /ram/mountp/[prot_name]/ on demand

	]]
	local prot_lookups = 0

	local function _userland_to_kernal_path(path_p, mode_p)

		if (type(path_p) ~= "string") return nil
		if (path_p == "") return nil -- don't accept fetch("") etc -- is dangerous

		mode_p = mode_p or "R"

		local path

		if (path_p:prot(true) or path_p[1] == "/") then
			-- absolute path: use as-is
			path = path_p
		else
			-- relative path: prepend (userland) pwd() first and normalise first 
			-- e.g. bbs://new/foo.p64/gfx/.. -> /ram/bbs://new/foo.p64/gfx
			local userland_pwd = _kernal_to_userland_path(_pwd())
			if (userland_pwd[#userland_pwd] == "/") then
				path = userland_pwd..path_p -- at start e.g. "bbs://", don't want extra /
			else
				path = userland_pwd.."/"..path_p
			end
		end

		-- normalise (e.g. collapse /foo/./a/../b ->  /foo/b)
		path = _normalise_userland_path(path)

		-- 0.2.0i: userland paths never need to specify anywhen:// !
		-- just: if they contain a @, then prepend anywhen:// for kernal -- kernal form is always prot://..

		if (string.find(path, "@")) then
			if (not path:prot(true)) path = "anywhen:/"..path
		end

		-- resolved path has protocol when explicitly starts with protocol or is relative to _pwd() that has a protocol
		-- (both cases handled above -- path already has protocol prefix at this point)
		local prot = path:prot(true) -- true for efficiency because kernal path form always prot:// (not anywhen's path@/m/d)

		-- undefined protocol should never resolve to anything
		if (prot and not prot_driver[prot]) return nil

		-- if writin to protol, fail (before resolving to ram path)
		if (mode_p == "W" and prot) return nil

		-------------------------------------------------------------------------------------------------------------
		-- protocol driver can opt to map carts to ram by implementing extract_cart_path() and store_path_in_ram() --
		-------------------------------------------------------------------------------------------------------------

		if prot and prot_driver[prot].extract_cart_path then

			-- 0.2.0i safety: block mount pruning until end of frame (46)
			-- because don't want to e.g. prune /ram/anywhen after call to _userland_to_kernal_path while still using those 
			-- ram files. before blocking, yield with pruning enabled to give a chance to prune (in case many repeated calls
			-- that are generating many ram files).

			prot_lookups += 1
			if (prot_lookups % 64 == 0) then
				_signal(47) -- enable mount pruning
				_yield() -- prune mounts if need every 64 file lookups
			end
			_signal(46) -- block mount pruning; expires at end of frame or after 100ms

			-- 1. driver.extract_cart_path() is used to determined where the cart maps to
			local cart_path, sub_path = prot_driver[prot].extract_cart_path(path)

			if (cart_path) then
				
				-- 2. driver.store_path_in_ram() is used to populate that ram path (e.g. by downloading a cart)
				-- store_path_in_ram() can return nil when shouldn't store (e.g. bbs://new)
				if (not prot_to_ram_path[cart_path]) then
					local fn = prot_driver[prot].store_path_in_ram(cart_path)
					if (fn) then
						--printh("@@ stored prot_to_ram_path["..cart_path.."] = "..fn.."  // path: "..path)
						prot_to_ram_path[cart_path] = fn
						ram_to_prot_path[fn] = cart_path
					else
						-- printh("@@ failed to store "..cart_path.."  // src: "..path)
					end
				end
			
				-- 3. kernel path resolves to that ram location, so can use fetch / fstat / ls transparently from userland 
				if prot_to_ram_path[cart_path] then
					local ram_path = prot_to_ram_path[cart_path]..sub_path
					--printh("@ resolved "..path.." to "..ram_path)
					return ram_path
				end
			end

			return path -- could not resolve; return as-is (and let the protocol driver deal with it)
			
		end

		-------------------------------------------------------------------------------------------------------------

		-- no protocol

		path = _fullpath(path) -- raw fullpath; handles relative paths + pwd
		if (type(path) ~= "string") return nil -- couldn't resolve, or nil to start with

		-------------------------------------------------------------------------------------------------------------
		-- apply access rules

		-- no protocol: return path as-is when not sandboxed
		-- (implicit rule: * RW)
		if (not _sandbox) return path

		----> sandboxed <----

		-- sandboxed processes can not read anywhen:// (or write ~ already blocked above)
		if (prot == "anywhen") return nil

		-- otherwise can only access certain locations
		-- to do: could pregenerate lists according to matching mode, but perf shouldn't be an issue here

		if (fileview) then -- safety; should always exist
			for i=1,#fileview do
				local rule = fileview[i]
				if (rule.mode == "RW" or (mode_p == "R" and rule.mode == "R") or (mode_p == "X" and rule.mode == "X")) then
					if path_is_inside(path, rule.location) then
						if (rule.target) then
							-- allow but rewrite
							--printh("allowing: "..path.."   -->   "..rule.target..path:sub(#rule.location+1))

							-- create target on demand; most bbs carts don't ever write anything, and don't want folderjunk 
							--printh("creating bbs appdata folder; path: "..path)
							_mkdir(rule.target)

							return rule.target..path:sub(#rule.location+1) -- "/appdata/bbs/bbs_id".."/foo.txt"
						else
							--printh("allowing: "..path)
							return path -- allow
						end
					end
				end
			end
		end

		-- anything else not allowed

		-- printh("no access from sandbox: "..path.." // mode: "..mode_p)

		return nil
	end


	-- sandboxed versions of some files
	-- to do: /ram/system/process/n.pod for a particular process
	local function _fetch_partial(path)

		if (path == "/ram/system/processes.pod") then

			local p = _get_process_list()
			local out = {}
			for i=1,#p do
				-- sandboxed cart can see: system processes, instances of self, direct children
				if (p[i].id <= 3 or 
					p[i].prog:sub(1,8) == "/system/" or
					p[i].prog == env().argv[0] or p[i].parent_id == _pid()) then
					add(out, p[i])
				else
					add(out, {
						id = 0,
						name = "[hidden]",
						prog = "[hidden]",
						cpu = 0,
						memory = 0,
						priority = 0,
						pwd = ""
					})
				end
			end
			
			return out
		end

		return nil
	end



	--------------------------------------------------------------------------------------------------------------------------------

		-- generate metadata string in plain text pod format
	local function _generate_meta_str(meta_p)

		-- use a copy so that can remove pod_format without sideffect
		local meta = unpod(pod(meta_p)) or {}

		local meta_str = "--[["

		if (meta.pod_format and type(meta.pod_format) == "string") then
			meta_str ..= "pod_format=\""..meta.pod_format.."\""
			meta.pod_format = nil -- don't write twice
		elseif (meta.pod_type and type(meta.pod_type) == "string") then
			meta_str ..= "pod_type=\""..meta.pod_type.."\""
			meta.pod_type = nil -- don't write twice
		else
			meta_str ..= "pod"
		end

		local meta_str1 = _pod(meta, 0x0) -- 0x0: metadata always plain text. want to read it!

		if (meta_str1 and #meta_str1 > 2) then
			meta_str1 = sub(meta_str1, 2, #meta_str1-1) -- remove {}
			meta_str ..= ","
			meta_str ..= meta_str1
		end

		meta_str..="]]"

		return meta_str

	end


	function pod(obj, flags, meta)

		-- safety: fail if there are multiple references to the same table
		-- to do: allow this but write a reference marker in C code? maybe don't need to support that!
		local encountered = {}
		local function check(n)
			local res = false
			if (encountered[n]) return true
			encountered[n] = true
			for k,v in pairs(n) do
				if (type(v) == "table") res = res or check(v)
			end
			return res
		end
		if (type(obj) == "table" and check(obj)) then
			-- table is not a tree
			return nil, "error: multiple references to same table"
		end

		if (meta) then
			local meta_str = _generate_meta_str(meta)
			return _pod(obj, flags, meta_str) -- new meaning of 3rd parameter!
		end

		return _pod(obj, flags)
	end

	

	local function _fix_metadata_dates(meta)
		
		-- time string generation bug that happened 2023-10! (to do: fix files in /system)
		if (type(meta.modified) == "string" and tonumber(meta.modified:sub(6,7)) > 12) then
			meta.modified = meta.modified:sub(1,5).."10"..meta.modified:sub(8)
		end
		if (type(meta.created) == "string" and tonumber(meta.created:sub(6,7)) > 12) then
			meta.created = meta.created:sub(1,5).."10"..meta.created:sub(8)
		end

		-- use legacy value .stored if .modified was not set
		if (not meta.modified) meta.modified = meta.stored

	end

	local function _fix_legacy_metadata(meta)
		if (not meta) return

		_fix_metadata_dates(meta)
		
		-- cartridge icons before 0.2.0c that don't have any colourful pixels set should be treaded as low-colour
		-- same for non-cartridges (no .runtime) when modified before 0.2.0c came out
		-- i.e. always apply theme even when not settings.lowcol_icons
		if (type(meta.icon) == "userdata") then
			if (meta.runtime and meta.runtime < 17) or (not meta.runtime and meta.modified and meta.modified:sub(1, 10) < "2025-03-26")then
				meta.lowcol_icon = true
				local themecols = {[0]=true,[1]=true,[13]=true,[6]=true,[7]=true}
				for i=0,255 do
					if (not themecols[meta.icon[i]]) meta.lowcol_icon = nil -- has a colourful colour
				end
			end
		end
	end

	local function _fetch_metadata(filename)
		local result = _fetch_metadata_from_file(_fstat(filename) == "folder" and filename.."/.info.pod" or filename)
		_fix_legacy_metadata(result)
		return result
	end

	function fetch_metadata(filename_p)
		if (type(filename_p) ~= "string") return nil
		local filename = _userland_to_kernal_path(filename_p)

		if (not filename) then
			-- try directly from .info.pod (perhaps /desktop is not allowed in sandbox, but /desktop/.info.pod is)
			filename = _userland_to_kernal_path(filename_p.."/.info.pod", "X")
			if (filename) then
				local res  = _fetch_metadata_from_file(filename)
				if (not _sandbox) return res -- not sandboxed; return 
				-- otherwise: censor! only return positions, no file names (used by e.g. bbs://desktop_pet.p64)
				local res2 = {file_item={}}
				if (res.file_item) then
					local index = 0
					for k,v in pairs(res.file_item) do
						res2.file_item["file_"..index] = { x = v.x, y = v.y }
						index += 1
					end
				end
				return res2
			end
			return nil
		end

		--printh("fetch_metadata kernal_path: "..filename)
		return _fetch_metadata(filename)
	end



	-- fetch and store can be passed locations instead of filenames
	-- return obj, metadata, err_str
	local fetch_job = nil
	function fetch(location, options)

		if (type(location) != "string") return nil, nil, "location is not a string"

		if (type(options) ~= "table") options = {}

		local filename, hash_part = table.unpack(_split(location, "#", false))
		local prot = location:prot(true)

		-- to do: move http handling into drive (same pattern as anywhen)
		if (prot == "https" or prot == "http") then
			--[[
				remote fetches are logically the same as local ones -- they block the thread
				but.. can be put into a coroutine and polled
			]]

			-- _printh("[fetch] calling _fetch_remote: "..filename)
			local job_id, err = _fetch_remote(filename)
			-- _printh("[fetch] job id: "..job_id)

			if (err) return nil, nil, err

			if type(options.on_complete) == "function" then

				if (not fetch_job) then
					fetch_job = {}
					on_event("update", function(msg)
						for i=#fetch_job,1,-1 do
							local result, meta, err = _fetch_remote_result(fetch_job[i].job_id)
							if (result or err) then
								fetch_job[i].on_complete(result, meta, err)
								fetch_job[i] = nil
							end
						end
					end)
				end

				options.job_id = job_id
				options.location = location
				add(fetch_job, options)
				return nil, nil, "in progress"
			end

			local tt = time()

			while time() < tt + 10 do -- to do: configurable timeout.

				-- _printh("[fetch] about to fetch result for job id "..job_id)

				local result, meta, err = _fetch_remote_result(job_id)

				-- _printh("[fetch] result: "..type(result))

				if (result or err) then
					-- _printh("[fetch remote] err: "..pod(err))
					return result, meta, err
				end

--				flip(0x1)
--				_yield()  -- 0.2.0e: yield is sufficient
				-- 0.2.0i: superyield; want to behave the same when called from inside coroutine
				-- can now use fetch("https://example.com", on_complete = function(obj, metadata, err_str) ... end)
				flip(0x1)

			end
			return nil, nil, "timeout"

		else
			-- local file (update: or generic protocol)
			kpath = _userland_to_kernal_path(filename)

			-- if kpath resolves to a protocol path, use get_file_contents when defined by driver
			-- to do: http should implement get_file_contents callback
			if (kpath and kpath:prot()) then
				prot = kpath:prot()
				if (prot_driver[prot].get_file_contents) then
					return prot_driver[prot].get_file_contents(kpath)
				end
				return nil, nil, "could not access"
			end

			if (not kpath) then
				-- try again with partial view of file (processes.pod)
				kpath = _userland_to_kernal_path(filename, "X")
				if (kpath) return _fetch_partial(kpath)
			end

			if (not kpath) return nil, nil, "could not access path"

			local flags = 0
			if (options.argb) flags |= 0x1
			if (options.raw_str) flags |= 0x2
			local ret, meta = _fetch_local(kpath, flags)
			_fix_legacy_metadata(meta)

			return ret, meta -- no error
		end
	end

	_fetch_userland = fetch

	
	--[[
		mkdir()
		returns string on error
	]]
	function mkdir(p)
		p = _userland_to_kernal_path(p, "W")
		if (not p) return "could not access path"

		if (p:prot()) return -- protocols don't support mkdir / writes yet

		if (_fstat(p)) return -- is already a file or directory

		-- create new folder
		local ret = _mkdir(p)

		-- couldn't create
		if (ret) return ret

		-- can store starting metadata to file directly because no existing fields to preserve
		-- // 0.1.0f: replaced "stored" with modified; not useful as a separate concept
		_store_metadata_str_to_file(p.."/.info.pod", _generate_meta_str{created = date(), modified = date()})
	end


	-- to do: errors
	function store(location, obj, meta)

		if (type(location) != "string") return nil

		-- currently no writeable protocols
		if (location:prot()) then
			return "can not write "..location
		end

		location = _userland_to_kernal_path(location, "W")

		if (not location) return "could not store to path"

		-- special case: can write raw .p64 / .p64.rom / .p64.png binary data out to host file without mounting it
		local ext = location:ext()

		if (type(obj) == "string" and ext and ext:is_cart()) then
			_signal(40)
				_rm(location:path()) -- unmount existing cartridge // to do: be more efficient
			_signal(41)
			return _store_local(location, obj)
		end

		-- ignore location string
		local filename = _split(location, "#", false)[1]
		
		-- grab old metadata
		local old_meta = _fetch_metadata(filename)
		
		if (type(old_meta) == "table") then
			if (type(meta) == "table") then			
				-- merge with existing metadata.   // to do: how to remove an item?			
				for k,v in pairs(meta) do
					old_meta[k] = v
				end
			end
			meta = old_meta
		end

		if (type(meta) != "table") meta = {}
		if (not meta.created) meta.created = date()
		if (not meta.revision or type(meta.revision) ~= "number") meta.revision = -1
		meta.revision += 1   -- starts at 0
		meta.modified = date()


		-- 0.1.1e: store "prog" when is bbs:// -- the program that was used to create the file can be used to open it again
		if (_env().argv[0]:prot(true) == "bbs") then
			meta.prog = _env().argv[0]
		end

		-- use pod_format=="raw" if is just a string
		-- (_store_local()  will see this and use the host-friendly file format)

		if (type(obj) == "string") then
			meta.pod_format = "raw"
		else
			-- default pod format otherwise
			-- (remove pod_format="raw", otherwise the pod data will be read in as a string!)
			meta.pod_format = nil 
		end


		local err_str = _store_local(filename, obj, _generate_meta_str(meta))

		-- notify program manager (handles subscribers to file changes)
		if (not err_str) then
			_send_message(2, {
				event = "_file_stored",
				filename = _fullpath(filename), -- pm expects raw path
				proc_id = pid()
			})
		end

		-- nil if no error
		return err_str

	end
	_store_userland = store


	local function _store_metadata(filename, meta)

		local old_meta = _fetch_metadata(filename)
		
		if (type(old_meta) == "table") then
			if (type(meta) == "table") then			
				-- merge with existing metadata.   // to do: how to remove an item? maybe can't! just recreate from scratch if really needed.
				for k,v in pairs(meta) do
					old_meta[k] = v
				end
			end
			meta = old_meta
		end

		if (type(meta) != "table") meta = {}
		meta.modified = date() -- 0.1.0f: was ".stored", but nicer just to have a single, more general "file was modified" value.


		local meta_str = _generate_meta_str(meta)

		if (_fstat(filename) == "folder") then
			-- directory: write the .info.pod
			_store_metadata_str_to_file(filename.."/.info.pod", meta_str)
		else
			-- file: modify the metadata fork
			_store_metadata_str_to_file(filename, meta_str)
		end
	end

	function store_metadata(filename, meta)
		return _store_metadata(_userland_to_kernal_path(filename, "W"), meta)
	end


	_rm = function(f0, flags, depth)

		flags = flags or 0x0
		depth = depth or 0

		local attribs, size, origin = _fstat(f0)

		if (not attribs) then
			-- does not exist
			return
		end

		if (attribs == "folder") then

			-- folder: first delete each entry using this function
			-- dont recurse into origin! (0.1.0h: unless it is cartridge contents)
			-- e.g. rm /desktop/host will just unmount that host folder, not delete its contents
			if (not origin or (origin:sub(1,11) == "/ram/mount/")) then 
				local l = ls(f0)
				if (type(l) == "table") then
					for k,fn in pairs(l) do
						_rm(f0.."/"..fn, flags, depth+1)
					end
				end
			end
			-- remove metadata (not listed)
			_rm(f0.."/.info.pod", flags, depth+1)

			-- flag 0x1: remove everything except the folder itself (used by cp when copying folder -> folder)
			-- for two reasons:

			-- leave top level folder empty but stripped of metadata; used by cp to preserve .p64 that are folders on host
			if (flags & 0x1 > 0 and depth == 0) then
				return
			end

		end


		-- delete single file / now-empty folder
		
		-- _printh("_fdelete: "..f0)
		return _fdelete(f0)
	end

	function rm(f0)
		local f1 = _userland_to_kernal_path(f0, "W")
		if (not f1) return "could not resolve"
		if (f1:prot()) return "can not modify "..f1:prot() -- protocols don't support writing yet 

		-- 0.2.1e: deleting /ram/mount* is dangerous -- contents of mounted carts deleted and flushed to origin
		if (f1 == "/ram") return "can not delete ram"
		if (f1 == "/ram/mount") return "can not modify ram/mount"
		if (f1:sub(1,11) == "/ram/mount/") return "can not modify ram/mount"

		_signal(40)
			local ret = _rm(f1, 0, 0) -- atomic operation
		_signal(41)
		return ret
	end


	--[[	
		internal; f0, f1 are raw (kernal) paths 

		handles anywhen:// and bbs:// by using userland functions
		(when kernal path has protocol, always same as canonical userland path)

		if dest (f1) exists, is deleted!  (cp util / filenav copy operations can do safety)
	]]
	function _cp(f0, f1, moving, depth, bbs_id)

		depth = depth or 0
		f0 = _fullpath(f0)
		f1 = _fullpath(f1)

		if (not f0)   return "could not resolve source path"
		if (not f1)   return "could not resolve destination path"
		if (f0 == f1) return "can not copy over self"

		local f0_prot = f0:prot()

		local f0_type = f0_prot and fstat(f0) or _fstat(f0) -- need to use userland function for protocol source path (e.g. copy from anywhen)
		local f1_type = _fstat(f1)

		if (not f0_type) then
			--print(tostring(f0).." does not exist") 
			return "could not read source location"
		end

		-- explicitly delete in case is a folder -- want to make sure contents are removed
		-- to do: should be an internal detail of delete_path()?
		-- 0.1.0e: 0x1 to keep dest as a folder when copying a folder over a folder
		-- (e.g. dest.p64/ is a folder on host; preferable to keep it that way for some workflows)
		if (f1_type == "folder" and depth == 0) _rm(f1, f0_type == "folder" and 0x1 or 0x0) 

		-- folder: recurse
		if (f0_type == "folder") then

			-- 0.1.0c: can not copy inside itself   "cp /ram/cart /ram/cart/foo" or "cp /ram/cart/foo /ram/cart" 
			-- 0.1.1:  but cp foo foo2/ is ok (or cp foo2 foo/)
			local minlen = min(#f0, #f1)
			if (sub(f1, 1, minlen) == sub(f0, 1, minlen) and (f0[minlen+1] == "/" or f1[minlen+1] == "/")) then
				return "can not copy inside self" -- 2 different meanings!
			end
			-- 0.1.1e: special case for /  --  is technically also "can not copy inside self", but might as well be more specific
			if (f0 == "/" or f1 == "/") then
				return "can not copy /"
			end

			-- get a cleared out root folder with empty metadata
			-- (this allows host folders to stay as folders even when named with .p64 extension -- some people use that workflow)
			_mkdir(f1)

			-- copy each item (could also be a folder)

			local l = (f0_prot and ls or _ls)(f0)
			for k,fn in pairs(l) do
				local res = _cp(f0.."/"..fn, f1.."/"..fn, moving, depth+1)
				if (res) return res
			end

			-- copy metadata over if it exists (ls does not return dotfiles)
			-- 0.1.0f: also set initial modified / created values 

			local meta = (f0_prot and fetch_metadata or _fetch_metadata)(f0) or {}

			-- also set date [and created when not being used by mv())
			meta.modified = date()
			if (not moving) meta.created = meta.created or meta.modified -- don't want to clobber .created when moving

			-- when copying / moving from bbs:// -> local, carry over bbs_id and sandbox. copy over existing values! (in particular, dev bbs_id)
			if (bbs_id) then
				-- printh("@@ carrying over bbs_id as metadata"..bbs_id)
				meta.bbs_id = bbs_id
				meta.sandbox = "bbs"
			end

			-- store it back at target location. can just store file directly because no existing fields to preserve
			_store_metadata_str_to_file(f1.."/.info.pod", _generate_meta_str(meta))

			return
		end

		-- copy a single file

		if (f0_prot) then
			-- from a protocol: need to do a userland fetch and store
			local obj, meta = _fetch_userland(f0)
			_store_userland(f1, obj, meta)
		else
			-- local -> local: can do a raw binary copy
			_fcopy(f0, f1)
		end

		-- 0.2.1c notify program manager (handles subscribers to file changes)
		if (true) then -- to do: check file could actually be stored
			_send_message(2, {
				event = "_file_stored",
				filename = f1, -- is already kernal fullpath like pm expects
				proc_id = pid()
			})
		end

	end

	--[[
		mv(src, dest)

		to do: rename / relocate using host operations if possible

		to do: currently moving a mount copies it into a regular file and removes the mount;
			-> should be possible to rename/move mounts around?
	]]
	function mv(src_p, dest_p)

		-- special case: moving a file from (read-only) protocol; treat as a copy (e.g. drag and drop from bbs)
		-- cp() handles that case
		if (src_p:prot()) return cp(src_p, dest_p)

		local src  = _userland_to_kernal_path(src_p, "W") 
		local dest = _userland_to_kernal_path(dest_p, "W")
		if (not src) return "could not resolve source path"
		if (not dest) return "could not resolve destination path"
		if (dest:prot()) return "can not write to "..dest:prot().."://" -- protocols don't support writing yet 

		-- skip mv if src and dest are the same (is a NOP but not an error. to do: should it be?)
		if (_fullpath(src) == _fullpath(dest)) return

		-- special case: when copying from bbs://, retain .bbs_id .sandbox as metadata
		local bbs_id = (src_p:prot(true) == "bbs" and src_p:ext() == "p64") and src_p:basename():sub(1,-5) or nil

		_signal(40) -- 0.1.1e compound op lock (prevent flushing cart halfway through moving)
			local res = _cp(src, dest, true, nil, bbs_id) -- atomic operation
		_signal(41)
		if (res) return res -- copy failed

		-- copy completed -- safe to delete src
		_signal(40)
			_rm(src)
		_signal(41)
	end

	function cp(src_p, dest_p)
		local src  = _userland_to_kernal_path(src_p)
		local dest = _userland_to_kernal_path(dest_p, "W")
		if (not src) return "could not resolve source path"
		if (not dest) return "could not resolve destination path"
		if (dest:prot()) return "can not write to "..dest:prot().."://" -- protocols don't support writing yet 

		-- special case: copying a file from protocol; read file via userdata fetch / store (avoid duplicated logic)
		-- happens when source is an anywhen file (so not mounted inside /ram/anywhen) // cp("anywhen://...","1.txt")
		if (src_p:prot() and fstat(src_p) == "file") then
			local dat,meta = _fetch_userland(src_p)
			_store_userland(dest_p, dat, meta)
		end

		-- special case: when copying from bbs://, retain .bbs_id .sandbox as metadata
		local bbs_id = (src_p:prot(true) == "bbs" and src_p:ext() == "p64") and src_p:basename():sub(1,-5) or nil

		_signal(40) -- 0.1.1e: lock flushing for compound operation; don't want to e.g. store a cart on host that is halfway through being copied
			local ret0, ret1 = _cp(src, dest, nil, nil, bbs_id) -- atomic operation   (to do: remove ret1; never used?)
		_signal(41) -- unlock 
		return ret0, ret1
	end

	-- 

	--[[
		ls
		note: ls("not_in_sandbox") returns nil, even if there subdirectories accessible to the sandbox
		--> ls("/") does not list ("/appdata")
	]]
	function ls(p)
		p = p or _pwd()

		kernal_path = _userland_to_kernal_path(p)
		if (not kernal_path) return nil -- not allowed to list if couldn't sandbox / resolve

		-- protocol listing
		local prot = kernal_path:prot()
		if (prot) return prot_driver[prot].get_listing(kernal_path) or {}

		-- local listing
		return _ls(kernal_path)
	end

	function cd(p)
		if (type(p) ~= "string") return nil
		kernal_path = _userland_to_kernal_path(p)

		if (not kernal_path) return nil -- means local path doesn't exist

		-- protocol path
		local prot = kernal_path:prot()
		if (prot) return _cd(kernal_path, true) -- to do: use protocol get_attr first to check it is a folder

		-- local
		return _cd(kernal_path)
	end

	function pwd()
		return _kernal_to_userland_path(_pwd())
	end

	function fullpath(p)
		local kernal_path = _userland_to_kernal_path(p)
		if (not kernal_path) return nil

		-- resolve to protocol location -> no further indirection
		if (kernal_path:prot(true)) then
			return strip_anywhen(kernal_path)
		end

		-- otherwise now have a path on local filesystem or /ram; can convert back after applying _fullpath	
--[[
		if (p:prot()) then
			printh("_fullpath(kernal_path): ".._fullpath(kernal_path))
		end
]]
		return _kernal_to_userland_path(_fullpath(kernal_path))
	end

	function mount(a, b)
		if (_sandbox) return nil -- can't mount anything when sandboxed (or read mount descriptions) 
		if (a:prot() or b:prot()) return nil -- can't mount protocols [yet]
		return _mount(a, b)
	end

	function fstat(p)

		local kernal_path = _userland_to_kernal_path(p)

		if (not kernal_path) return nil
		
		-- protocol path attributes
		local prot = kernal_path:prot(true)
		if (prot) then -- mean protocol exists because otherwise _userland_to_kernal_path returns nil
			-- printh("reading protocol path attributes: "..kernal_path)
			local kind, size = prot_driver[prot].get_attr(kernal_path)
			return kind, size
		end
		
		-- otherwise now have a path on local filesystem (including /ram), can use _fstat
		
		if (_sandbox) then	
			local kind, size = _fstat(kernal_path)
			return kind, size -- don't expose mount description when sandboxed
		end

		return _fstat(kernal_path) -- includes mount description
	end
	_fstat_userland = fstat

	-- system apps (filenav) can request access to particular files
	on_event("extend_fileview", function(msg)
		-- printh("requesting file access via extend_fileview: "..pod(msg))
		if (msg._flags and (msg._flags & 0x1) > 0) then  --  requesting process is a trusted system app (filenav)
			if type(msg.filename) == "string" then
				add(fileview, {
					location = msg.filename:path(), -- 0.2.0e: only want path part for applying rules
					mode = "RW"
				})
			end
		end
	end)

	-- grant access to dropped files

	on_event("drop_items", function(msg)
		if (msg._flags and (msg._flags & 0x1) > 0) then  --  requesting process is a trusted system app (window manager)
			for i=1,#msg.items do
				-- printh("granting file access via dropped item: "..msg.items[i].fullpath)
				if type(msg.items[i].fullpath) == "string" then
					add(fileview, {
						location = msg.items[i].fullpath:path(), -- 0.2.0e: only want path part for applying rules
						mode = "RW"
					}, 1) -- insert at start so that mapping don't interfere. e.g. drop from /appdata/anotherapp
				end
			end
		end
	end)

	_export_functions_to_head{
		fetch = fetch,
		fullpath = fullpath,

		-- the following are not used by head; deleteme
		fetch_metadata = fetch_metadata,		
		store_metadata = store_metadata,
		store = store,
		pwd = pwd,
		fstat = fstat
	}

end
