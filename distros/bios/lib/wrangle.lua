--[[pod_format="raw",created="2024-03-12 18:17:15",modified="2025-07-07 05:32:30",revision=4]]
--[[

	wrangle.lua

	// not designed to be customisible; aim to take care of 90% of cases with a minimal replacement for boilerplate.
	to customise: copy and modify (internals will not change [much] after 0.1) -- update: ha!

	// 0.2.1e note: should try to support old / minimal versions of wrangler from wm so that this implementation can be
	copied and modified even while still in development. e.g. okpal has own wrangler.

	wrangle_working_file(save_state, load_state, untitled_filename, get_hlocation, set_hlocation, state_hint)

	user supplies two callbacks, similar to create_undo_stack():

		save_state()          -- should return data (and optionally metadata)
		load_state(dat, meta) -- takes data and restores program state

	and 3 optional callbacks: 

		get_hlocation         -- return the string that goes after "#" in the location (e.g. foo.lua#33 -> "33")
		set_hlocation,        -- given the sub-location string (33), apply to editor state (jump to line 33)
		state_hint            -- used for efficient unsaved changes detection; return value can be anything,
		                         but should change when state of file /might/ have changed. more info: notebook.p64/main.lua

]]


local current_filename -- should be "current_location"

local last_synced_state = nil -- state at time of load / save (i.e. when known to be in sync with disk)
local last_synced_state_md5 = nil

local last_synced_hint_value = nil
local last_hint_value = nil
local unsaved_changes = false

-- deleteme; don't need the concept of staleness at the wrangler / wm level (can do everything with unsaved_changes())
local is_stale = false

local _env = env
local _send_message = _send_message
local split = split
local create_process = create_process
local _signal = _signal
local pid = pid
local fetch = fetch
local store = store

local save_state_callback_exists = nil -- used when generating menu items

function pwf()
	return current_filename
end

-- used by infobar to highlight line of code when opened from error messages
local highlight_from_env = env().highlight


local function update_menu_items()
	
	-- don't need -- can do file open, CTRL-I to get file info
	-- also: can hover over tab to see filename
	-- ** maybe: right click on tab gives a different tab-specific menu
	--    at the moment it is only really useful for "close tab", and maybe confusing that there is the same menu twice
--[[
	menuitem{
		id = "file_info",
		label = "\^:1f3171414141417f About "..current_filename:basename(),
		action = function() create_process("/system/apps/about.p64", {argv={current_filename}, window_attribs={workspace = "current"}}) end
	}
	-- \^:1c367f7777361c00  -- i in circle
]]


	--** fundamental problem (maybe wrangler could tackle):
	--** when edit metadata, doesn't feel like anything changes on disk until save it
	--** But then Save As, what happens? Should wrangler store current metadata and pass it on?
--[[
	menuitem{
		id = "file_info",
		label = "\^:1c367f7777361c00 File Metadata",
		action = function() create_process("/system/apps/about.p64", {argv={current_filename}, window_attribs={workspace = "current"}}) end
	}
]]
--	menuitem()

	menuitem{
		id = "open_file",
		label = "\^:7f4141417f616500 Open File",
		shortcut = "CTRL-O",
		action = function()
			local path = current_filename:dirname() -- same folder as current file (or "/")
			
			-- printh("ctrl-o path from wrangler: "..pod{current_filename, current_filename:dirname()})

			--create_process("/system/apps/filenav.p64", {path = path, window_attribs= {workspace = "current", autoclose=true}})

			local open_with = _env().argv[0]

			-- can assume when program is terminal, co-running /ram/cart and should use that to open the file (useful for developing tools that use file wrangler)
			--> use /ram/cart to run it.   //  allows wrangling files from load'ed cartridge; useful for tool dev
			if (open_with == "/system/apps/terminal.lua") then
				open_with = "/ram/cart/main.lua"
			end

			-- printh("open_with: "..open_with)

			create_process("/system/apps/filenav.p64", {path = path, open_with = open_with, window_attribs= {workspace = "current", autoclose=true}})
		end
	}

	-- open include save items when a save_state callback is provided
	if (save_state_callback_exists) then

		-- save file doesn't go through filenav -- can send straight to even handler installed by wrangle.lua
		if (current_filename:sub(1,10) == "/ram/cart/") then
			menuitem{
				id = "save_file",
				label = "\f6\^:7f4141417f616500 Save File (auto)",
				shortcut = "CTRL-S", -- ctrl-s is handled by window manager
				action = function() _send_message(pid(), {event = "save_file"}) return true end -- can still save just in case!
			}
		else
			menuitem{
				id = "save_file",
				label = "\^:7f4141417f616500 Save File",
				shortcut = "CTRL-S", -- ctrl-s is handled by window manager
				action = function() _send_message(pid(), {event = "save_file"}) end
			}
		end

		menuitem{
			id = "save_file_as",
			label = "\^:7f4141417f616500 Save File As",

			action = function() 
				local segs = split(current_filename,"/",false)
				local path = string.sub(current_filename, 1, -#segs[#segs] - 2) -- same folder as current file
				create_process("/system/apps/filenav.p64", 
					{path=path, intention="save_file_as", use_ext = current_filename:ext(), window_attribs={workspace = "current", autoclose=true}})
			end
		}

	end

	menuitem("---")

end




local function set_current_filename(fn)
	fn = fullpath(fn) -- nil for bad filenames
	if (not fn) return false
	current_filename = fn
	window{
		title = current_filename:basename(),
		location = current_filename
	}
	update_menu_items() -- (auto) shown on /ram/cart files
	return true -- could set
end

function set_last_synced_state(content, hint_val)
	last_synced_state = pod(content, 0x3) -- to do: (efficiency) extract from caller store() / fetch() process which also uses format 0x3 by default
	last_synced_state_md5 = nil
	if (#last_synced_state > 0x40000) then
		-- when state string is > 256k (unusual), use md5 instead to save memory
		-- if dealing with a large file, preferable to conserve memory
		-- introduces tiny risk of collisions, but not very dangerous (skip a single version change every 3.4e+38 autosaves)
		last_synced_state_md5 = last_synced_state:md5()
		last_synced_state = nil -- allow to be garbage collected
	end

	-- reset 
	last_hint_value = nil
	unsaved_changes = false
	last_synced_hint_value = hint_val
	send_message(3, {event = "set_unsaved_changes", val = false, filename = fullpath(current_filename)})

	-- to do: maybe also maintain an unsaved_changes bit somewhere so that app can check status 
	-- (+ 2 other locations in this file where unsaved_changes is set)
	-- 

end


--[[
	wrangle_working_file() // the user-facing api

	untitled_filename is also used to specifiy default extension (foo.pal -> auto appends .pal on save)

	state_hint:
		should complete quickly and return value should change when there /might/ be unsaved changes
		always confirmed by last_synced_state comparison

	to do: move to table parameters if gets too unweildy
]]
function wrangle_working_file(save_state, load_state, untitled_filename, get_hlocation, set_hlocation, state_hint)

--[[
	-- to do: move to table parameters; review names
	local opt = {}

	if (type(save_state) == "table") then
		opt = save_state
		save_state = opt.save_state
		load_state = opt.load_state
		untitled_filename = opt.untitled_filename
		get_hlocation = opt.get_hlocation
		set_hlocation = opt.set_hlocation
	else
		opt = {
			save_state = save_state,
			load_state = load_state,
			untitled_filename = untitled_filename,
			get_hlocation = get_hlocation,
			set_hlocation = set_hlocation
		}
	end
]]
	save_state_callback_exists = save_state	

	local w = {
		save = function(w)
--			printh("## save "..current_filename..  " // unsaved_changes: "..tostr(w:unsaved_changes()))

			if (not save_state) return -- NOP if no callback defined

			local content, meta = save_state()
			if (not meta) meta = {}

			local err = store(current_filename, content, meta)

			if (err) then
				return err
			end

			set_last_synced_state(content, state_hint and state_hint())

			-- use callback to modify current_filename with new location suffix (e.g. foo.lua#23 line number changes)
			if (get_hlocation) then
				w:update_hloc(get_hlocation())
			end

		end,

		load = function(w)
			local content, meta = fetch(current_filename)
			local hloc = split(current_filename, "#", false)[2]

			-- call load_state() even when content is not found; might do some initialisation
			set_last_synced_state(content, state_hint and state_hint())
			load_state(content, meta)
			if (set_hlocation) set_hlocation(hloc, highlight_from_env)

			if not content and save_state then
				-- this is needed when working file doesn't yet exist -- want to set the synced state to the default program state
				--printh("could not load "..current_filename.." --> setting last synced state to current content")
				local content, meta = save_state()
				set_last_synced_state(content, state_hint and state_hint())
			end
			highlight_from_env = false -- first time only


			return content, meta
		end,


		update_hloc = function(w, newloc, extra)

			newloc = tostring(newloc) -- could be a number
			if (type(newloc) ~= "string") return

			current_filename = split(current_filename, "#", false)[1].."#"..newloc

			-- tell wm new location
			window{location = current_filename}

			-- apply the new location via the app callback (e.g. set cursor position in code editor)
			-- extra is a table of arbitrary parameters attached to "jump_to_hloc" messages
			-- ~ ephemeral options that shouldn't be stored in the location; e.g. {highlight = true} for the code editor
			if (set_hlocation) set_hlocation(newloc, extra)

		end,
		
		--[[
			unsaved_changes

			test for changes made by /this/ process since last load / save
			(there might still be changes made by another process or externally)
			currently expensive; later: can be a fallback if app doesn't supply its own unsaved_changes callback
				// update: not really that expensive
				// but in any case app might want finer control in deciding when unsaved changes exist
		]]
		unsaved_changes = function(w)

			local result

			if (not save_state) return false

			-- printh("@@ testing state (expensive)")

			local state1 = pod(save_state(), 0x3)

			result = not (
				(last_synced_state and last_synced_state == state1) or
				(last_synced_state_md5 and last_synced_state_md5 == state1:md5())
			)

			return result
		end

	}

	untitled_filename = untitled_filename or "untitled.pod"
	
	
	-- derive current_file
	
	cd(_env().path)

	-- look for current filename first in environment (location) and then on commandline

	if (fullpath(_env().location)) then
		current_filename = _env().location
	elseif (fullpath(_env().argv and _env().argv[1])) then
		current_filename = _env().argv[1] -- can only ever pass filename as first argument; match sandboxed access rule in terminal.lua::run_program_in_new_process
	else
		current_filename = untitled_filename -- last resort: use default
	end

	current_filename = fullpath(current_filename)

	if not fullpath(current_filename) then
		-- can't resolve: use /appdata. happens when e.g. /ram/cart is not available because sandboxed
		if type(untitled_filename) == "string" then
			current_filename = "/appdata/"..untitled_filename:basename()
		else
			current_filename = "/appdata/wrangler_undefined.txt"
		end
	end

	local current_file_exists = fstat(current_filename)

	-- when file doesn't exist, w:load() also serves to init state by calling load_state(nil, ..)
	-- to do: can this fail?
	w:load()

	-- create  -- 0.2.0h: no need! don't need to assume file exists, and normally don't want to e.g. write untitled.txt to the desktop
--[[
	if (not current_file_exists) then
		w:save() -- don't care about result
	end
]]

	-- tell window manager working file
	-- ** [currently] needs to happen after creating window **

	window{
		title = current_filename:basename(),
		location = current_filename,

		-- extend default timeout to 2 seconds. default in wm is 0.2 seconds
		-- can do this because save_file event sends "back save_file_completed" to wm.lua, and so timeout is almost never needed
		-- custom wrangler implementations should implement save_file_completed if set this value to > ~0.5
		-- using a short timeout is very low stakes; /maybe/ an autosave to /ram/cart will finish late for the requesting save or info command to observe the changes 
		-- but using a timeout that is too long can cause long pauses when running / saving when the save_file_completed message is never received by wm
		save_timeout = 2.0 
	}

	------ install events ------

	-- invoked directly from app menu, and by wm when about to run / save cartridge
	on_event("save_file", function(msg)
		-- if (msg.filename) current_filename = msg.filename -- ** 0.2.0h commented; dangerous! deleteme ~ seems nothing using this (use "save_file_as" instead)

		if (msg.autosave) then
			-- when auto-saving /ram/cart files, don't save if there are no unsaved changes. 
			-- otherwise: strawberry_src /ram/cart/main.lua getting clobbered by default code.p64 tab
			if (not w:unsaved_changes()) then
				if (msg.notify_on_complete) then
					-- still need to send "save_file_completed" message so that wm.lua::pending_saves can reach 0
					_send_message(msg.notify_on_complete, 
						{event = "save_file_completed", filename = current_filename, skipped = true, autosave = msg.autosave})
				end
				
				return
			end
		end

		-- save to current_filename

		_signal(43) -- short-lived high priority operation starting 
			local err = w:save()
			
			if (msg.notify_on_complete) then
				_send_message(msg.notify_on_complete, {event = "save_file_completed", filename = current_filename, err = err, autosave = msg.autosave})
			end
		_signal(44)
		
		if (err) then 

			notify(err) -- uncommented for 0.2.0i ~ was this commented because clobbering some other message?
			return err
	
		elseif not msg.autosave then -- autosaving /ram/cart files does not produce any notifications

			if (fullpath(current_filename) and fullpath(current_filename):sub(1,8) == "/system/") then
				notify("\^:0f19392121213f00 saved "..current_filename.." ** warning: changes to /system/ not written to disk **")
			else
				notify("\^:0f19392121213f00 saved "..current_filename)

			end
		end

	end)

	-- invoked by filenav intention
	on_event("open_file", function(msg)
		set_current_filename(msg.filename)
		w:load()
		update_menu_items()
	end)

	on_event("jump_to_hloc", function(msg)
		-- to do: the msg.extra pattern could be used for other events
		w:update_hloc(msg.hloc, msg.extra)
	end)

	-- invoked by filenav intention
	on_event("save_file_as", function(msg)
		
		if (set_current_filename(msg.filename)) then

			-- 0.1.0c: automatically add extension if none is given
			if (not current_filename:ext() and untitled_filename:ext()) then
				set_current_filename(current_filename.."."..untitled_filename:ext())
			end

			local err = w:save()
			if (err) then
				notify(err)			
			else
				notify("\^:7f4141417f616500 saved as "..current_filename) -- show message even if cart file
			end
		end
		
	end)


	-- autosave /ram/cart file when editor loses focus
	--> when editing multiple copies of same file: means the version auto-saved to disk is LAST EDITED, OR LAST CTRL-S'ed
		-- ahh.. unless that process continues doing something to change the state while in the background
		-- in that case it will keep clobbering after ctrl-r / ctrl-s. but that kind of makes sense!

	on_event("lost_focus", function(msg)

		if (sub(current_filename, 1, 10) == "/ram/cart/") then
			if (w:unsaved_changes()) then
				local err = w:save()
				if (err) notify(err) -- something fundamentally wrong if saving to /ram/cart is unsuccessful
			end
		end
	end)


	on_event("update", function(msg)

		-- optimisation: most of the time editor that is in foreground has unsaved changes
		-- also means state_hint doesn't need to be super lightweight 
		-- (works if not handling 2. below)
		--if (unsaved_changes) return

		local val
		if (state_hint) then
			--dtime()
			val = state_hint()	
			--dtime(0)
		else
			val = time()\1 -- poll every second
		end

		if (not last_synced_hint_value) last_synced_hint_value = val

		if (last_hint_value and val ~= last_hint_value) then

			-- switch changes on
			if not unsaved_changes then
				-- 1. if state hint doesn't match hint value at time of last save/load, then do more expensive test

				if (val ~= last_synced_hint_value) then 

--					dtime()
					local res = w:unsaved_changes()
--					printh("calculating unsaved changes (turn on)") dtime(1)

					if (res) then	
						send_message(3, {event = "set_unsaved_changes", val = true, filename = fullpath(current_filename)})
						unsaved_changes = true
					end

				end

			elseif (state_hint) then -- require that hint is implemented; otherwise too expensive

				-- 2.
				-- same pattern when returning to the state that was saved to disk (usually by undoing)
				-- expensive because need to keep doing expensive state comparisons, but is really nice!
				-- update: doesn't cause /that/ many state comparisons; normally not sitting at the same undo stack position
				-- problem is when polling because hint is not implemented; in that case don't do this step

				if (val == last_synced_hint_value) then
--					dtime()
					local res = w:unsaved_changes()
--					printh("calculating unsaved changes (turn off)") dtime(1)

					if (not res) then -- change no unsaved changes -> unsaved changes
						send_message(3, {event = "set_unsaved_changes", val = false, filename = fullpath(current_filename)})
						unsaved_changes = false
					end
				end
			end
		end

		last_hint_value = val

	end)


	update_menu_items()

	return w
end






