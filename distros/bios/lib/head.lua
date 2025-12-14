-- **** head.lua should not have any metadata; breaks load during bootstrapping // to do: why? ****
--[[

	head.lua -- kernal space header for each process
	(c) Lexaloffle Games LLP

]]

do

-- system libraries can define functions usable by head by exporting to populate hf
-- (protect again rewrite attacks)
local hf = {
	fullpath = _fullpath -- bootstrap
}
function _export_functions_to_head(f)
	for k,v in pairs(f) do
		-- printh("setting head function: "..k)
		hf[k] = v
	end
end

-- constant for lifetime of process
local _envdat = env()
local _pidval = pid()

-- keep a local copy of any functions used in head
-- used by create_process and boot.lua without _ENV duplication (_include_lib)
-- --> need to take care of rewrite attacks

local _stop = _stop
local _load = load
local _create_process_from_code = _create_process_from_code
local _fetch_metadata_from_file = _fetch_metadata_from_file
local _pod = _pod

local _halt = _halt
local _mkdir = _mkdir

local _signal = _signal
local _split = split
local _ext = _ext
local _path = _path
local _hloc = _hloc
local _md5 = _md5

local _sub = string.sub
local _find = string.find
local _tostring  = tostring

local _send_message  = _send_message

local _printh = _printh -- not used but for safety (often add debugging lines)
local _notify -- defined after referenced below

local _stat = stat

----------------------------------------------------------------

--[[
-- debugging; log which globals are accessed
local GLOBALS = _G

local globals_mt = {
	__index = function(t, k)
--		printh("GLOBAL ACCESSED:".._tostring(k))
		local val = rawget(GLOBALS, k)
		if val ~= nil then
			if type(val) == "function" then
				return function(...)
					printh("GLOBAL CALLED:".._tostring(k))
					return val(...)
				end
			end
			return val -- return non function value
		end
		if (GLOBALS) printh("GLOBAL ACCESSED BUT NOT FOUND:".._tostring(k))
		return nil
	end
}

if (_pidval > 3) then	
	_G = {}
	setmetatable(_G, globals_mt)
end
--]]




----------------------------------------------------------------------------------------------------------------------------

-- local helpers because don't want to call functions from the string metatable (sandbox security)

local function _is_cart_ext(str)
	return str=="p64" or str=="p64.png" or str=="p64.rom"
end
local function _is_bbs_cart(loc)
	return _sub(loc,1,6) == "bbs://"
end

--[[
	0.2.1e: follow c stdlib convention:

	dirname prints all but the final slash-delimited component of each name. 
	Slashes on either side of the final component are also removed. If the string contains no slash, dirname prints ‘.’

	basename - strip directory and suffix from filenames

		path         dirname    basename
		"/usr/lib"    "/usr"    "lib"
		"/usr/"       "/"       "usr"
		"usr"         "."       "usr"
		"/"           "/"       "/"

	-- pre-0.2.1e included the ending slash; dirname("/foo/1.txt") -> /foo/
]]

local function _basename(str)
	local segs = _split(_path(str),"/",false)
	if (segs[#segs]=="" and #segs > 1) segs[#segs] = nil -- discard empty segment caused by trailing slash
	if (#segs == 1) return str
	return segs[#segs]
end

local function _dirname(str)
	if (str == "/") return "/"
	local path = _path(str) -- remove hloc
	local segs = _split(path,"/",false)
	if (#segs <= 1) return "."
	if (segs[#segs]=="" and #segs > 1) segs[#segs] = nil -- discard empty segment caused by trailing slash
	local res = _sub(path,1,-(#segs[#segs] + 2))
	return res
end

--------------------------------------------------------------------------------------------------------------------------------
-- for bbs://foo-0.p64/subcart/hoge.p64 --> id should be foo-0, not hoge
-- bbs_id includes the version, but is stripped when creating fileview (all versions share /appdata/foo)
local function get_bbs_id_from_location(loc)
	if (_sub(loc,1,6) ~= "bbs://") return nil
	local pos = _find(loc, ".p64", 1, true)
	if (not pos) return nil
	return _basename(_sub(loc, 1, pos-1))
end

-- bbs://new/0/foo-0.p64/subcart/hoge.p64 -> bbs://foo-0.p64/subcart/hoge.p64
-- to do: also need this for favourites; how to get easily extract bbs id from userland?
local function normalise_bbs_path(path)
	local bbs_id = get_bbs_id_from_location(path)
	if (not bbs_id) return nil

	local pos = _find(path, ".p64", 1, true)
	if (not pos) return nil

	return "bbs://"..bbs_id.._sub(path, pos)
end
--------------------------------------------------------------------------------------------------------------------------------


local function get_short_prog_name(p)
	if (not p) then return "no_prog_name" end
	p = _split(p, "/", false)
	p = _split(p[#p], ".", false)[1]
	return p
end

-- for rate limiting
local create_process_t = 0
local create_process_n = 0

--[[

	create_process(prog, env)

	returns process id on success, otherwise: nil, err_msg

	prog: the cartridge or lua file to run
	env: a table of environment attributes that is merged with the new process environment

]]
-- 
function create_process(prog_name_p, env_patch)

	env_patch = env_patch or {}

	-- 1. sandboxed programs can not create processes

	if _envdat.sandbox and ((_stat(307) & 0x1) == 0) then -- sandboxed program that is not a trusted system app

		local grant_exception = false

		-- 1.a can run /system apps as a "bbs_companion"  --  ** has full fileview ** (except for /appdata)

		if ({
			["/system/apps/filenav.p64"] = true, -- bbs carts can use filenav to gain access to open any file on disk (e.g. strawberry_src
			["/system/apps/notebook.p64"] = true, -- some carts already use this for opening documentation, I think. could open() instead
			["/system/util/open.lua"] = true, -- #picocalendar uses this to open text files
			["/system/util/ls.lua"] = true -- for sandboxed terminal; doesn't modify system and parent can't get information back
		})[prog_name_p] then
			grant_exception = true
			env_patch.sandbox = "bbs_companion"
			env_patch.bbs_id = _envdat.bbs_id
		end

		-- 1.b can run bundled carts in same sandbox

		local pp = _envdat.corun_program and _dirname(_envdat.corun_program) or _envdat.argv[0]
		local pp1 = hf.fullpath(prog_name_p)
		if (pp and _sub(pp1,1,#pp) == pp and pp1[#pp+1] == "/") then
			grant_exception = true
			env_patch.sandbox = "bbs"
			env_patch.bbs_id = _envdat.bbs_id
		end
		
		-- 1.c can run anything from bbs:// (including sub-carts)

		if (get_bbs_id_from_location(prog_name_p)) then
			grant_exception = true 
			env_patch.sandbox = "bbs"
			env_patch.bbs_id = get_bbs_id_from_location(prog_name_p)
		end

		--> fail if no grounds to allow creating process while sandboxed

		if (not grant_exception) then
			-- printh("[create_process] denied from sandboxed program: "..prog_name_p)
			return nil, "sandboxed process can not create_process()"
		end
		-- printh("[create_process] granting exception in sandbox: "..prog_name_p)


		-- rate limiting // prevent bbs cart from process-bombing
		if (time() > create_process_t + 60) create_process_t, create_process_n = time(), 0 -- reset every minute
		if (create_process_n >= 20) return nil, "sandboxed process can not create_process() more than 20 / minute"
		create_process_n += 1

		-- rate limiting for picocalendar (bug in cart that didn't show up earlier when find_existing_window was always implicitly true)
		-- to do: stealth patch cart and delete this
		if (_envdat.argv[0]:sub(1,18) == "bbs://picocalendar") then
			if (last_picocalendar_t and time() < last_picocalendar_t + 0.5) return nil, "picocalendar window spam workaround"
			last_picocalendar_t = time()
		end

	end


	------------------------------------------ resolve program path -------------------------------------

	local prog_name = hf.fullpath(prog_name_p)

	-- normalise bbs paths: remove "new/0/" etc
	if get_bbs_id_from_location(prog_name) then
		-- printh("normalising bbs prog: "..pod{prog_name, normalise_bbs_path(prog_name), get_bbs_id_from_location(prog_name)})
		prog_name = normalise_bbs_path(prog_name)
	end

	------------------------------------------ locate boot file -----------------------------------------
	
	-- .p64 files: find boot file in root of .p64 (and thus set default path there too)
	local boot_file = prog_name
	if (_is_cart_ext(_ext(prog_name))) boot_file ..= "/main.lua"

	------------------------------------------ locate metadata ------------------------------------------

	-- look for metadata inside p64 / folder  (never use metadata from a single .lua file in this context)
	local metadata = _fetch_metadata_from_file(prog_name.."/.info.pod")

	-- special case: co-running /ram/cart from terminal
	if env_patch.corun_program == "/ram/cart/main.lua" then
		metadata = _fetch_metadata_from_file("/ram/cart/.info.pod")
	end
	
	-- running main.lua directly from inside a cart -> should look at attributes of parent directory
	if (not metadata and _basename(prog_name) == "main.lua") then
		metadata = _fetch_metadata_from_file(_dirname(boot_file).."/.info.pod")
	end

	-- no metadata found -> default is {}
	if (not metadata) metadata = {}

	-- check for future cartridge (applies to carts / folders -- lua files don't have this metadata)
	if (type(metadata.runtime) == "number" and metadata.runtime > _stat(5)) then
		_notify("** cartridge has future runtime version: "..prog_name_p)
		return -- to do: settings.allow_future
	end

	------------------------------------------ construct new_env ------------------------------------------

	local new_env = {} -- don't inherit anything from parent 

	-- .. but add new attributes from env_patch (note: can copy trees)
	for k,v in pairs(env_patch) do
		new_env[k] = v
	end

	-- decide program path: same as boot file, or corun program
	local program_path = new_env.corun_program and 
		_dirname(hf.fullpath(new_env.corun_program)) or
		_dirname(boot_file)

	-- standard environment values: pid, argv, argv[0]
	new_env.parent_pid = _pidval
	new_env.argv = type(new_env.argv) == "table" and new_env.argv or {} -- guaranteed to exist at least as an empty table
	new_env.argv[0] = prog_name -- e.g. /system/apps/gfx.p64

	------------------------------------------------------------------------------------------------------------------------------------------------
	-- sandbox validation
	------------------------------------------------------------------------------------------------------------------------------------------------

	-- safety: prog that starts with bbs:// MUST be bbs-sandboxed w/ cart_id derived from that location
	-- for bbs://foo-0.p64/subcart/hoge.p64 --> id should be foo, not hoge
	if get_bbs_id_from_location(prog_name) then
		new_env.sandbox = "bbs"
		new_env.bbs_id = get_bbs_id_from_location(prog_name)
	end

	-- grab sandbox from cartridge metadata if not already set in environment
	-- (can opt to turn sandboxing off in env_patch with {sandbox=false}; or otherwise override sandbox specified in metadata)
	if (not new_env.sandbox and metadata.sandbox and metadata.bbs_id) then
		new_env.sandbox = metadata.sandbox -- "bbs"
		new_env.bbs_id = metadata.bbs_id
	end

--[[
	deleteme ~ set when granting

	-- created by sandboxed program -> MUST be bbs_companion with the same bbs_id (unless already determined to be a bbs cart)
	-- --> ignore metadata or new_env.sandox
	-- means inherit fileview  (e.g. open filenav -> should have same /appdata mapping)
	if (new_env.sandbox ~= "bbs" and _envdat.sandbox == "bbs") then
		new_env.sandbox = "bbs_companion"
		new_env.bbs_id = _envdat.bbs_id
--		printh("create_process bbs_companion: ".._envdat.bbs_id)
	end
]]

	-- sandboxes should be only bbs / bbs_companion, and must have a bbs_id
	if new_env.sandbox and new_env.sandbox ~= "bbs" and new_env.sandbox ~= "bbs_companion" then
		return nil, "only bbs, bbs_companion sandbox profiles are currently supported"
	end

	if (new_env.sandbox and not new_env.bbs_id) then
		return nil, "bad bbs_id -- can not sandbox"
	end


	------------------------------------------------------------------------------------------------------------------------------------------------
	-- construct fileview
	------------------------------------------------------------------------------------------------------------------------------------------------

	if (_stat(307) & 0x1) > 0 then
		-- trusted apps (/system/*) can grant a custom fileview (including to a sandboxed process)
		new_env.fileview = new_env.fileview or {}
	else
		-- otherwise the fileview is derived entirely from new_env.sandbox / new_env.bbs_id
		new_env.fileview = {}
	end

	-- 0.2.0e: fileview rules should not include hash part. but called "location" (and not "path") because should be allowed to pass in a location
	-- (e.g. open.lua does it -- sometimes includes the hash part. callers shouldn't need to know / remember to do that)

	for i=#new_env.fileview,1,-1 do
		if type(new_env.fileview[i].location) == "string" and type(new_env.fileview[i].mode) == "string" then
			-- remove the hash part -- just want the path
			new_env.fileview[i].location = _path(new_env.fileview[i].location) 
		else
			-- invalid rule
			del(new_env.fileview,new_env.fileview[i])
		end
	end

	-- printh("creating process "..prog_name_p.." with starting fileview: "..pod{new_env.fileview})
	-- printh("creating process "..prog_name_p.." with sandbox: "..pod{new_env.sandbox})
	
	-- create fileview / rules for sandbox

	if (new_env.sandbox == "bbs") then

		-- read system libraries and resources
		add(new_env.fileview, {location = "/system", mode = "R"})

		-- cart/program can read itself; includes running main.lua directly, and co-run programs. program_path is same as initial pwd
		-- note: this never happens for stand-alone .lua files as it is not possible to sandbox them separately (only parent .info.pod is observed in this context)
		add(new_env.fileview, {location = program_path, mode = "R"})

		-- partial view of processes.pod and /desktop metadata (only icon x,y available; ref: bbs://desktop_pet.p64)
		add(new_env.fileview, {location = "/ram/system/processes.pod", mode = "X"})
		add(new_env.fileview, {location = "/desktop/.info.pod", mode = "X"})
		
		-- (dev) read/write mounted bbs:// cart while sandboxed
		-- deleteme -- only needed in kernal space in fs.lua
--		add(new_env.fileview, {location = "/ram/bbs/"..new_env.bbs_id..".p64.png", mode = "RW"})
		-- experimental: should be allowed to read mount? seems harmless but shouldn't ever be needed so do not allow
		--add(new_env.fileview, {location = "/ram/bbs/"..new_env.bbs_id..".p64.png", mode = "R"}) 

		-- any carts can read/write /appdata/shared \m/
		add(new_env.fileview, {location = "/ram/shared", mode = "R"})
		add(new_env.fileview, {location = "/appdata/shared", mode = "RW"})

		-- any other /appdata path should be mapped to /appdata/bbs/bbs_id
		local bbs_id_base = split(new_env.bbs_id, "-", false)[1] -- don't include the version part
		_mkdir("/appdata/bbs") -- safety; should already exist (boot creates)
		--_mkdir("/appdata/bbs/"..bbs_id_base) -- to do: only create when actually about to write something?
		add(new_env.fileview, {location = "/appdata", mode = "RW", target="/appdata/bbs/"..bbs_id_base})

	end

	-- bbs_comapnion e.g. open filenav / notebook from bbs cart. always a trusted app from /system
	-- the companion program has full access, except should have same /appdata mapping as parent process
	if (new_env.sandbox == "bbs_companion") then

		new_env.fileview={}

		-- same /appdata mapping as parent process
		local bbs_id_base = split(_envdat.bbs_id, "-", false)[1] -- don't include the version part
		_mkdir("/appdata/bbs")
		_mkdir("/appdata/bbs/"..bbs_id_base) -- create on launch in case want to browse it with filenav
		add(new_env.fileview, {location = "/appdata", mode = "RW", target="/appdata/bbs/"..bbs_id_base})

		-- printh("created companion mapping for /appdata: ".."/appdata/bbs/"..bbs_id_base)

		-- everything else is allowed (e.g. filenav can freely browse drive and choose where to load / save file)
		add(new_env.fileview, {location = "*", mode = "RW"})
	end

	--printh("new_env.fileview: "..pod{new_env.fileview})

	
	
	----


	local str = [[

		-- environment for new process; use _pod to generate immutable version
		-- (generates new table every time it is called)
		env = function() 
			return ]].._pod(new_env,0x0)..[[
		end
		_env = env

		local head_code = load(fetch("/system/lib/head.lua"), "@/system/lib/head.lua", "t", _ENV)
		if (not head_code) then printh"*** ERROR: could not load head. borked file system / out of pfile slots? ***" end
		head_code()

		-- order matters // fs.lua uses on_event
		_include_lib("/system/lib/api.lua")
		_include_lib("/system/lib/mem.lua")
		_include_lib("/system/lib/window.lua")
		_include_lib("/system/lib/coroutine.lua")
		_include_lib("/system/lib/print.lua")
		_include_lib("/system/lib/events.lua")
		_include_lib("/system/lib/fs.lua")
		_include_lib("/system/lib/socket.lua")
		_include_lib("/system/lib/gui.lua")
		_include_lib("/system/lib/app_menu.lua")
		_include_lib("/system/lib/wrangle.lua")
		_include_lib("/system/lib/undo.lua")
		_include_lib("/system/lib/theme.lua")

		_signal(38) -- start of userland code (for memory accounting)
		_signal(15) -- give audio priority to this process; can steal PFX6416 control on note() / sfx() / music()

		-- clear out globals that shouldn't be exposed to userland
		include("/system/lib/jettison.lua")
		
		-- always start in program path
		cd("]]..program_path..[[")

		-- autoload resources (must be after setting pwd)
		-- 0.2.0e: when running /ram/cart, this also blocks to save any files open in editors
		include("/system/lib/resources.lua")

		-- to do: preprocess_file() here // update: no need!
		include("]]..boot_file..[[")

		-- footer; includes mainloop
		include("/system/lib/foot.lua")

	]]


	local proc_id = _create_process_from_code(str, get_short_prog_name(prog_name), prog_name, new_env.sandbox)

	if (not proc_id) then
		return nil
	end

	if (env_patch.window_attribs and env_patch.window_attribs.pwc_output) then
		hf.store("/ram/system/pop.pod", proc_id) -- present output process
	end

	if (env_patch.blocking) then
		-- this process should stop running until proc_id is completed
		-- (update: is that actually useful?)
	end


--	printh("$ created process "..proc_id..": "..prog_name.." ppath:"..program_path)
--	printh("  new_env: "..pod(new_env))

	return proc_id

end


local _create_process = create_process
function open(loc)
	if (type(loc)~="string") return

	-- works for sandboxed carts, but open.lua will be run in a bbs_companion sandbox
	--> can open anything that is accessible to calling processes's fileview
	_create_process("/system/util/open.lua",{argv={loc}})
end


----------------------------------------------------------------------------------------------------------------------------


-- manage process-level data: dispay, env


	-- exit()
	-- immediately close program & window 
	-- exit_code currently not used by anything! to do: maybe that's a good thing?
	-- does picotron really need something like bash style scripts-as-functions? is meant to value self-contained lua programs!
	-- the only result that needs to be communicated is directly to the end user (via print() or notify() or drawn to screen)
	function exit(exit_code)
		-- exit_code = exit_code or 0 
		_send_message(2, {event="kill_process", proc_id=_pidval})
		_halt() -- stop executing immediately
	end

	-- stop executing in a resumable way 
	-- use for debugging via terminal: stop when something of interest happens and then inspect state
	-- unlike PICO-8, always prints to terminal (can't use to print to display ~ no need)
	function stop(txt)
--		if (txt) print(txt,...) -- parameters are same as a regular print() -- can set colour or draw to back page

		if (_envdat.corun_program) then
			_send_message(_pidval, {event="halt", description=txt}) -- same as pressing escape; goes to terminal
			hf.flip() -- halt immediately
		elseif _draw then
			-- unusual case:
			-- for a graphical program, nothing to print to but should still stop. -> use notify()
			-- is unlikely the author meant this to happen outside of a debugging context, but seems
			-- worse to ever disregard the request to halt (maybe about to do something dangerous?)
			_notify(txt)
			_halt()
		else
			-- similar; shouldn't be using stop() as a way to end carts (noted in manual)
			-- instead use print("message") error(err_code)
			print(txt)
			_send_message(2, {event="kill_process", proc_id=_pidval})
			_halt() -- stop executing immediately
		end
		
	end

	_stop = stop

	-- any process can kill any other process!
	-- deleteme -- send a message to process manager instead. process manager might want to decline.
	--[[
	function kill_process(proc_id, exit_code)
		_send_message(2, {event="kill_process", proc_id=proc_id, exit_code = exit_code})
	end
	]]

	


	
	---------------------------------------------------


	--[[
		include()

		shorthand for: fetch(filename)()  //  so always relative to pwd()

		// not really an include, but for users who don't care about the difference, serves the same purpose
		// and is used in the same way: a bunch of include("foo.lua") at the start of main.lua

		related reading: Lua Module Function Critiqued // old module system deprecated in 5.2 in favor of require()
			// avoids multiple module authors writing to the same global environment
			http://lua-users.org/wiki/LuaModuleFunctionCritiqued
			https://web.archive.org/web/20170703165506/https://lua-users.org/wiki/LuaModuleFunctionCritiqued

	]]

	local included_files = {}



	function include(filename_p)
		local filename = hf.fullpath(filename_p)
		local src = filename and hf.fetch(filename) or nil
		if (not src) then
			_notify("could not include "..tostring(filename_p))
			_stop()
		end

		-- temporary safety: each file can only be included up to 256 times
		-- to do: why do recursive includes cause a system-level out of memory before a process memory error?
		if (included_files[filename] and included_files[filename] > 256) then
			_notify("too many includes "..tostring(filename_p).." (max:256) // circular reference?")
			_stop()
		end
		included_files[filename] = included_files[filename] and included_files[filename]+1 or 1

		if (type(src) ~= "string") then 
			if (_pidval <= 3) printh("** could not include "..filename)
			_notify("could not include "..filename.." (fetch failed)")
			_stop()
		end

		-- https://www.lua.org/manual/5.4/manual.html#pdf-load
		-- chunk name (for error reporting), mode ("t" for text only -- no binary chunk loading), _ENV upvalue
		-- @ is a special character that tells debugger the string is a filename
		local func,err = _load(src, "@"..filename, "t", _ENV)

		-- syntax error while loading
		if (not func) then 
			_send_message(3, {event="report_error", content = "*syntax error"})
			_send_message(3, {event="report_error", content = "(could not include: "..filename..")"})
			_send_message(3, {event="report_error", content = _tostring(err)})
			_stop()
		end

		return func() -- 0.1.1e: allow private modules (used to return true)
	end
	


	--[[
		0.2.1c: 
		when including /system/lib/*, make a copy of environment that is inaccessible to userland code to
		protect against rewriting functions (and metamethods) used inside system libraries. otherwise can
		use as a foothold for escaping sandbox. test:

			local prot0 = string.prot
			function string:prot(...) printh("hi from userland") return prot0(...) end
			fullpath("/") -- calls :prot()

		-- previous strategy was to make a local copy of each function used in kernal code
		-- causes circular dependencies, doesn't work for string metamethods and easy to miss otherwise
		--> should have a blanket safety measure like this in any case; use on top of local function references
	]]

	local function copy_env_funcs(tbl, depth)
		if (depth > 3) return nil
		local out = {}
		for k,v in pairs(tbl) do
			if k ~= "_G" and k ~= "_ENV" then 
				if type(v) == "table" then
					out[k] = copy_env_funcs(v, depth+1)
				else
					out[k] = v
				end
			end
		end
		return out
	end

	function _include_lib(filename)

		local src = fetch(filename) -- hf.fetch not defined yet, but _include_lib only used before userland entry
		local env2 = copy_env_funcs(_G, 0)
		local func,err = _load(src, "@"..filename, "t", env2)

		-- syntax error while loading
		if (not func) then 
			printh("_include_lib error: "..pod{filename, _tostring(err)})
			_stop()
		end

		func()

		-- spill changes back into main global scope. userland can still redefine those new functions if desired
		-- (but the modified versions will not be used from inside library code)
		-- includes _ENV.string, so can't overwrite string metamethods used in library code (see example above)
			-- to do: understand this better; can it still be circumvented?

		for k,v in pairs(env2) do
			if v ~= _G[k] and k ~= "_G" and k ~= "_ENV" then
				-- print("@@ defined: "..filename.." :: ".._tostring(k))
				_G[k] = v -- copy back
			end
		end

	end

	-- _include_lib = include -- test: 

--------------------------------------------------------------------------------------------------------------------------------

--[[
	
	to do: 
	notify("syntax error: ...", "error") -> shows up in /ram/log/error, as a tab in infobar (shown in code editor workspace)
	
	can also use logger.p64 to view / manage logs
	how to do realtime feed with atomic file access? perhaps via messages to logger? [sent by program manager]

]]
function notify(msg_str)

	-- notify user and add to infobar history
	_send_message(3, {event="user_notification", content = msg_str})

	-- logged by window manager
	-- _send_message(3, {event="log", content = msg_str})
	
	-- web debug
	if (_stat(318)==1) printh("@notify: "..msg_str.."\n")
end
_notify = notify


--[[
	send_message()

	security concern: 
	userland apps may perform dangerous actions in response to messages, not realising they can be triggered by arbitrary bbs carts
		// also: userland apps currently observe "mouse", "textinput" etc in events.lua without filtering (desirable, but not for sandboxed apps)
	-> sandboxed processes can only send messages to self, or to /system processes (0.1.1e)
		-- e.g. sandboxed terminal can send terminal set_haltable_proc_id to wm, or request a screenshot capture
		-- assumption: /system programs can all handle arbitrary messages safely
		-- to do: should accept message going to process 2, but then reject most/all of them from those handlers. clearer
]]
function send_message(proc_id, msg, on_responce)

	if 
		not _envdat.sandbox or                         -- userland processes can send messages anywhere
		proc_id == _pidval or                          -- can always send message to self
		(_stat(307) & 0x1) == 1 or                     -- can always send message if is bundled /system app (e.g. sandboxed filenav)
		proc_id == 3 or                               -- can always send message to wm
		-- special case: sandboxed app can set map/gfx palette via pm; (to do: how to generalise this safely?)
		msg.event == "set_palette" or -- used by #okpal
		(msg.event == "broadcast" and msg.msg and msg.msg.event == "set_palette") -- not sure if used in the wild
	then

		if type(on_responce) == "function" then
			local repy_id = "msg"..flr(_stat(333)) -- unique id
			hf.on_event(repy_id, function(msg1)
				on_responce(msg1)
				hf.on_event(repy_id, nil) -- remove the callback 
			end)
			msg._reply_id = repy_id
			_send_message(proc_id, msg)
		elseif on_responce then
			-- blocking			
			if (proc_id == _pid) return nil, "can not send a blocking message to self" 
			local ret
			local repy_id = "msg"..flr(_stat(333)) -- unique id
			hf.on_event(repy_id, function(msg1)
				ret = msg1
				hf.on_event(repy_id, nil) -- remove the callback 
			end)
			msg._reply_id = repy_id
			_send_message(proc_id, msg)
			while (ret == nil) do hf.flip(0x5) end -- same as input(): 0x1 superyield (no time advance or frame end)  0x4 to process messages
			return ret
		else
			-- fire and forget
			_send_message(proc_id, msg)
		end
	else
		--printh("send_message() declined: "..pod(msg))
	end

end



--------------------------------------------------------------------------------------------------------------------------------
-- string functions 
-- need to be at top level to function as metamethods used by other library files (esp fs.lua)
-- to do: move to c  // not performance cricial though, and kind of nice to see in code what it's doing
--------------------------------------------------------------------------------------------------------------------------------

string.split = _split
string.ext = _ext   -- _ext("foo.p64.png") -> "p64.png"
string.path = _path -- everything before first #
string.hloc = _hloc -- everything after first # (or nil when no # found)
string.md5 = _md5


string.basename = _basename
string.dirname = _dirname

-- max 8 chars // to do: move to c; only accept when lowercase alphanumeric characters
function string:prot(only_prefix)
	if (not only_prefix and _find(_path(self), "@", 1, true)) return "anywhen"
	local segs = _split(_path(self),":",false)
	return (type(segs[2]) == "string" and _sub(segs[2],1,2) == "//") and #segs[1] <= 8 and segs[1] or nil
end

function string:is_cart()
	return self=="p64" or self=="p64.png" or self=="p64.rom"
end


-- PICO-8 style string indexing;  ("abcde")[2] --> "b"   // to do: implement in lvm.c?
local string_mt_index=getmetatable('').__index
local _strindex = _strindex
getmetatable('').__index = function(str,i) 
	return string_mt_index[i] or _strindex(str,i)
end


----------------------------------------------------------------------------------------------------------------
-- initial state // to do: move to process.c
----------------------------------------------------------------------------------------------------------------

-- default instrument definitions // later: standard set of ~16?

local function clear_instrument(i)
	local addr = 0x40000 + i * 0x200
	memset(addr, 0, 0x200)
	
	-- node 0: root
	poke(addr + (0 * 32), -- node 0
	
			0,    -- parent (0x7)  op (0xf0)
			1,    -- kind (0x0f): 1 root  kind_p (0xf0): 0  -- wavetable_index
			0,    -- flags
			0,    -- unused extra
				
			-- MVALs:  kind/flags,  val0, val1, envelope_index
			
			0x2|0x4,0x20,0,0,  -- volume: mult. 0x40 is max (-0x40 to invert, 0x7f to overamp)
			0x1,0,0,0,     -- pan:   add. center
			0x1,0,0,0,     -- tune: +0 -- 0,48,0,0 absolute for middle c (c4) 261.6 Hz
			0x1,0,0,0,     -- bend: none
			-- following shouldn't be in root
			0x0,0,0,0,     -- wave: use wave 0 
			0x0,0,0,0      -- phase 
	)
	
	
	-- node 1: triangle wave
	poke(addr + (1 * 32), -- instrument 0, node 1
	
			0,    -- parent (0x7)  op (0xf0)
			2,    -- kind (0x0f): 2 osc  kind_p (0xf0): 0  -- wavetable_index
			0,    -- flags
			0,    -- unused extra
				
			-- MVALs:  kind/flags,  val0, val1, envelope_index
			
			0x2,0x20,0,0,  -- volume: mult. 0x40 is max (-0x40 to invert, 0x7f to overamp)
			0x1,0,0,0,     -- pan:   add. center
			0x21,0,0,0,    -- tune: +0 -- 0,48,0,0 absolute for middle c (c4) 261.6 Hz
			               -- tune is quantized to semitones with 0x20
			0x1,0,0,0,     -- bend: none
			0x0,0x40,0,0,  -- wave: triangle
			0x0,0,0,0      -- phase 
	)

end


-- to do: move to process.c
local pal,memset,poke,color,fillp,srand = pal,memset,poke,color,fillp,srand

function reset()

	-- reset palette (including scanline palette selection, rgb palette)

	pal()  -- 
	pal(2) -- reset display palette

	-- line drawing state

	memset(0x551f, 0, 9)

	-- bitplane masks

	poke(0x5508, 0x3f) -- read mask    //  masks raw draw colour (8-bit sprite pixel or parameter)
	poke(0x5509, 0x3f) -- write mask   //  determines which bits to write to
	poke(0x550a, 0x3f) -- target mask  //  (sprites)  applies to colour table lookup & selection
	poke(0x550b, 0x00) -- target mask  //  (shapes)   applies to colour table lookup & selection


	-- draw colour

	color(6)

	-- fill pattern 0x5500

	fillp()

	-- fonts (reset really does reset everthing!)

	poke(0x5f56, 0x40) -- primary font
	poke(0x5f57, 0x56) -- secondary font
	poke(0x4000,get(fetch"/system/fonts/lil.font"))
	poke(0x5600,get(fetch"/system/fonts/p8.font"))

	-- set tab width to be a multiple of char width

	poke(0x5606, (@0x5600) * 4)
	poke(0x5605, 0x2)             -- apply tabs relative to home

	-- mouselock event sensitivity, move sensitivity (64 means x1.0)
	poke(0x5f28, 64)
	poke(0x5f29, 64)

	-- window draw mask, interaction mask 
	poke(0x547d,0x0,0x0)

	-- audio 
	poke(0x5538,
		0x40,0x40, -- (1.0) global volume for sfx, music
		0x40,0x40, -- (1.0) default volume parameters when not given to sfx(), music()
		0x03,0x03  -- base address for sfx, music (0x30000, 0x30000)
	)

end



srand()

-- needs to be in head to wake up audio system for boot sound
clear_instrument(0)

-- reset() does most of the work but is specific to draw state; sometimes want to reset() at start of _draw()!  (ref: jelpi)
reset()


end