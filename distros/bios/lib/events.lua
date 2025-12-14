--[[pod_format="raw",created="2024-05-28 08:10:08",modified="2024-05-28 08:13:55",revision=5]]
--[[

	events.lua
	part of head.lua

]]

do

	local _envdat = env()
	local _send_message = _send_message
	local _read_message = _read_message
	local _update_buttons = _update_buttons
	local _signal = _signal
	local _flip = _flip

	local _warp_mouse = _warp_mouse
	
	local _window_has_focus = false

	local _pidval = pid()
	local _window_can_read_kbd = _pidval <= 3

	local message_hooks = {}
	local message_subscriber = {}
	local mouse_x = 0
	local mouse_y = 0
	local mouse_b = 0
	local wheel_x = 0
	local wheel_y = 0
	local locked_dx = 0
	local locked_dy = 0

--	local _req_host_clipboard_text = _req_host_clipboard_text -- old approach; deleteme
--	local _get_host_clipboard_text = _get_host_clipboard_text

	local _set_host_clipboard_text = _set_host_clipboard_text
	local _set_userland_clipboard_text = _set_userland_clipboard_text
	local _get_userland_clipboard_text = _get_userland_clipboard_text
	local sandbox_clipboard_text = nil


	local ident = math.random()

	local key_state={}
	local last_key_state={}
	local repeat_key_press_t={}

	local frame_keypressed_result={}
	local scancode_blocked = {} -- deleteme -- not used or needed   //  update: maybe do? ancient sticky keys problem

	local input_response = nil -- used by input()

	local any_key0 = false
	local any_key1 = false

	local halt_corun_program = nil

	local pressed_ctrl_v = false


	function mouse(new_mx, new_my)
		if (new_mx or new_my) then
			new_mx = new_mx or mouse_x
			new_my = new_my or mouse_y
			_warp_mouse(new_mx, new_my);
		end
		return mouse_x, mouse_y, mouse_b, wheel_x, wheel_y -- wheel
	end

	--[[
		do_lock bits
			0x1 enable mouse (P8)       //  ignored; always enabled!
			0x2 mouse_btn    (P8)       //  mouse buttons trigger player buttons (not implemented)
			0x4 mouse lock   (P8)       //  lock cursor to picotron host window when set
			0x8 auto-unlock on mouseup  //  common pattern for dials (observed by gui.lua)
	]]
	function mouselock(do_lock, event_sensitivity, move_sensitivity)
		if (event_sensitivity) poke(0x5f28, mid(0,event_sensitivity*64, 255)) -- controls scale of deltas (64 == 1 per picotron pixel)
		if (move_sensitivity)  poke(0x5f29, mid(0,move_sensitivity *64, 255)) -- controls speed of cursor while locked (64 == 1 per host pixel)
		if (type(do_lock) == "number") poke(0x5f2d, do_lock)    -- set all flags
		if (do_lock == true)  poke(0x5f2d, peek(0x5f2d) | 0x4)  -- don't alter flags, just set the lock bit
		if (do_lock == false) poke(0x5f2d, peek(0x5f2d) & ~0x4) -- likewise
		if ((peek(0x5f2d) & 0x4) == 0) return 0, 0               -- when not locked, always return 0,0
		return locked_dx, locked_dy -- wheel, locked is since last frame
	end



	--[[

		// 3 levels of keyboard mapping:

		1. raw key names  //  key("a", true)
	
			"a" means "the key to the right of capslock"
			defaults to US layout, patched by /appdata/system/scancodes.pod
			example: tracker music input -- layout should physically match a piano

		2. mapped key names  // key("a")

			"a" means the key with "a" written on it
			e.g. the key to the right of tab on a typical azerty keyboard
			defaults to OS mapping, patched by /appdata/system/keycodes.pod
			example: key"f" to flip sprite horiontally should respond to the key with "f" written on it

		3. text entry  // readtext()

			"a" is a unicode string triggered by pressing a when shift is not held (-> SDL_TEXTINPUT event)
			ctrl-a or enter does not trigger a textinput event; need to read with mapped key names using key() + keyp()
			defaults to host OS keyboard layout and text entry method; not configurable inside Picotron [yet?]
	]]
	

	-- physical key names
	-- include everything from sdl -- might want to make a POS terminal; but later could define a "commonly supported" subset
	local scancode_name = {
	"", "", "", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", 
	"m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "1", "2", 
	"3", "4", "5", "6", "7", "8", "9", "0", "enter", "escape", "backspace", "tab", "space", "-", "=", "[", 
	"]", "\\", "#", ";", "'", "`", ",", ".", "/", "capslock", "f1", "f2", "f3", "f4", "f5", "f6", 
	"f7", "f8", "f9", "f10", "f11", "f12", "printscreen", "scrolllock", "pause", "insert", "home", "pageup", "delete", "end", "pagedown", "right", 
	"left", "down", "up", "numlock", "kp /", "kp *", "kp -", "kp +", "kp enter", "kp 1", "kp 2", "kp 3", "kp 4", "kp 5", "kp 6", "kp 7", 
	"kp 8", "kp 9", "kp 0", "kp .", "<", "menu0", "", "kp =", "", "", "", "", "", "", "", "f20", 
	"f21", "f22", "f23", "f24", "execute", "help", "menu1", "select", "stop0", "again", "undo", "", "", "", "find", "", 
	"", "", "", "", "", "kp ,", "kp = (as400)", "", "", "", "", "", "", "", "", "", 
	"", "", "", "", "", "", "", "", "", "alterase", "right alt", "stop1", "clear", "prior", "return", "separator", 
	"out", "oper", "clear / again", "crsel", "exsel", "", "", "", "", "", "", "", "", "", "", "", 
	"kp 00", "kp 000", "thousandsseparator", "decimalseparator", "currencyunit", "currencysubunit", "kp (", "kp )", "kp {", "kp }", "kp tab", 
		"kp backspace", "kp a", "kp b", "kp c", "kp d", 
	"kp e", "kp f", "kp xor", "kp ^", "kp %", "kp <", "kp >", "kp &", "kp &&", "kp |", "kp ||", "kp :", "kp #", "kp space", "kp @", "kp !", 
	"kp memstore", "kp memrecall", "kp memclear", "kp memadd", "kp memsubtract", "kp memmultiply", "kp memdivide", "kp +/-", "kp clear", 
		"kp clearentry", "kp binary", "kp octal", "kp decimal", "kp hexadecimal", "", "", 
	"lctrl", "lshift", "lalt", "lcommand", "rctrl", "rshift", "ralt", "rcommand"
	}



	local raw_name_to_scancode = {}

	for i=1,#scancode_name do
		local name = scancode_name[i]
		if (name ~= "") raw_name_to_scancode[name] = i
	end

	-- patch with /settings/scancodes
	-- e.g. store("/appdata/system/scancodes.pod", {lctrl=57}) to use capslock as lctrl

	local patch_scancodes = fetch"/appdata/system/scancodes.pod"
	if type(patch_scancodes) == "table" then
		for k,v in pairs(patch_scancodes) do
			raw_name_to_scancode[k] = v
		end
	end

	-------------------------------------------------------------------------
	--	name_to_scancodes:  default host OS default mapping
	--  each entry is a table of one or more scancodes that trigger it
	-------------------------------------------------------------------------

	local name_to_scancodes = {}

	for i=1,255 do
		local mapped_name = stat(302, i)
		if (mapped_name and mapped_name ~= "") then
			-- temporary hack -- convert from SDL names (should happen at lower level)
			mapped_name = mapped_name:lower()
			if (mapped_name:sub(1,7) == "keypad ") mapped_name = "kp "..mapped_name:sub(8)
			if (mapped_name:sub(1,5) == "left ") mapped_name = "l"..mapped_name:sub(6)
			if (mapped_name:sub(1,6) == "right ") mapped_name = "r"..mapped_name:sub(7)
			if (mapped_name == "return") mapped_name = "enter"
			if (mapped_name == "lgui") mapped_name = "lcommand"
			if (mapped_name == "rgui") mapped_name = "rcommand"
			if (mapped_name == "loption") mapped_name = "lalt"
			if (mapped_name == "roption") mapped_name = "ralt"

--			printh("mapping "..mapped_name.." to "..i.."    // ".._get_key_from_scancode(i))

			if (not name_to_scancodes[mapped_name]) name_to_scancodes[mapped_name] = {}

			add(name_to_scancodes[mapped_name], i)

		end
	end


	-- raw  scancode names that are not mapped to anything -> dummy scancode (simplify logic)
	for i=1,#scancode_name do
		if (scancode_name[i] ~= "") then
			if (raw_name_to_scancode[scancode_name[i]] == nil) raw_name_to_scancode[scancode_name[i]] = -i
		end
	end

	
	-- patch keycodes (can also overwrite multi-keys like ctrl)

	local patch_keycodes = fetch"/appdata/system/keycodes.pod"
	if type(patch_keycodes) == "table" then
		for k,v in pairs(patch_keycodes) do
			-- /replace/ existing table; can use keycodes.pod to turn off mappings
			if (type(v) == "table") then
				name_to_scancodes[k] = v
			else
				name_to_scancodes[k] = {raw_name_to_scancode[v] or v} -- can use raw name or scancode directly.
			end
			--printh("mapping keycode "..k.." to "..pod(name_to_scancodes[k]))
		end
	end

	-- scancodes map to themselves unless explicitly remapped
	-- (avoids an extra "or scancode" in get_scancode)

	for i=0,511 do
		name_to_scancodes[i]    = name_to_scancodes[i] or {i}
		raw_name_to_scancode[i] = raw_name_to_scancode[i] or i
	end

	-- faster lookup for lctrl, rctrl, lalt, ralt wm filtering combinations
	local lctrl = (name_to_scancodes.lctrl and name_to_scancodes.lctrl[1]) or -1
	local rctrl = (name_to_scancodes.rctrl and name_to_scancodes.rctrl[1]) or -1
	local lalt =  (name_to_scancodes.lalt  and name_to_scancodes.lalt[1])  or -1
	local ralt =  (name_to_scancodes.ralt  and name_to_scancodes.ralt[1])  or -1


	-- alternative names
	-- (if the name being aliased is unmapped, then inherit its dummy mapping)

	name_to_scancodes["del"]      = name_to_scancodes["delete"] -- 0.1.0b used del
	name_to_scancodes["return"]   = name_to_scancodes["enter"]   
	name_to_scancodes["+"]        = name_to_scancodes["="]
	name_to_scancodes["~"]        = name_to_scancodes["`"]
	name_to_scancodes["<"]        = name_to_scancodes[","]
	name_to_scancodes[">"]        = name_to_scancodes["."]


	-- super-keys that are triggered by a bunch of other keys
	-- common to want to test for "any ctrl" (+ picotron includes apple command keys as ctrl)

	local function create_meta_key(k)
		local result = {}
		for i=1,#k do	
			local t2 = name_to_scancodes[k[i]]
			if (t2) then -- key might not be mapped to anything (ref: rctrl on robot)
				for j=1,#t2 do
					add(result, t2[j])
				end
			end
		end
		--printh("@@@ "..pod(k).."  -->  "..pod(result))
		return result
	end

	name_to_scancodes["ctrl"]  = create_meta_key{"lctrl",  "rctrl",  "lcommand", "rcommand"}
	name_to_scancodes["alt"]   = create_meta_key{"lalt",   "ralt"}
	name_to_scancodes["shift"] = create_meta_key{"lshift", "rshift"}
	name_to_scancodes["menu"]  = create_meta_key{"menu0",  "menu1"}
	name_to_scancodes["stop"]  = create_meta_key{"stop0",  "stop1"}


	-- is allowed to return a table of scancodes that a key is mapped to
	local function get_scancode(scancode, raw)
		local scancode = (raw and raw_name_to_scancode or name_to_scancodes)[scancode]
		--[[
		if (scancode_blocked[scancode]) then
			-- unblock when not down. to do: could do this proactively and not just when queried 
			if (key_state[scancode] != 1) scancode_blocked[scancode] = nil 
			return 0 
		end
		]]
		return scancode
	end

	--[[

		keyp(scancode, raw)

			raw means: use US layout; same physical layout regardless of locale.
			use for things like music keyboard layout in tracker

			otherwise: map via appdata/system/scancodes.pod (should be "kbd_layout.pod"?)

		-- frame_keypressed_result is determined before each call to _update()
		--  (e.g. ctrl-r shouldn't leave a keypress of 'r' to be picked up by tracker. consumed by window manager)

	]]

	function keyp(scancode, raw, depth)

--		if (scancode == "escape") printh("get_scancode(\"escape\"): "..get_scancode(escape))

--		if (not _window_can_read_kbd) return nil

		if (not(scancode)) return any_key1 and not any_key0

		scancode = get_scancode(scancode, raw)

		if (type(scancode) == "table") then			
			
			if (#scancode == 1) then
				-- common case: just process that single scancode
				scancode = scancode[1]
			else
				if (depth == 1) return false -- eh?
				local res = false
				for i=1,#scancode do res = res or keyp(scancode[i], raw, 1) end
				return res
			end
		end

		-- keep returning same result until end of frame
		if (frame_keypressed_result[scancode]) return frame_keypressed_result[scancode]

		-- first press
		if (key_state[scancode] and not last_key_state[scancode]) then
			repeat_key_press_t[scancode] = time() + 0.5 -- to do: configurable
			frame_keypressed_result[scancode] = true

			-- experimental: block all buttons! means can process keypresses first in _update so that they won't interfere with buttons mapped to keyboard
			-- update: nah -- too much magic and not that useful. better to do explicitly in _update() (e.g. ignore button presses while ctrl held)
			-- _signal(23)

			return true
		end

		-- repeat
		if (key_state[scancode] and repeat_key_press_t[scancode] and time() > repeat_key_press_t[scancode]) then
			repeat_key_press_t[scancode] = time() + 0.04
			frame_keypressed_result[scancode] = true
			return true
		end

		return false
	end
	
	
	function key(scancode, raw)

--		if (not _window_can_read_kbd) return nil
		if (not(scancode)) return any_key1

		scancode = get_scancode(scancode, raw)

		if (type(scancode) == "table") then
			local res = false
			for i=1,#scancode do 
				if (key_state[scancode[i]]) return true
			end
			return false
		end

		return key_state[scancode]
	end



	-- clear state until end of frame (update: or until pressed again?)
	-- (mapped keys only -- can't be used with raw scancodes)
	function clear_key(scancode)

		scancode = get_scancode(scancode)

		if (type(scancode) == "table") then
			for i=1,#scancode do 
				frame_keypressed_result[scancode[i]] = nil
				key_state[scancode[i]] = nil
			end
			return
		end

		frame_keypressed_result[scancode] = nil
		key_state[scancode] = nil
	end

	
	local text_queue={}

	function readtext(clear_remaining)
		local ret=text_queue[1]

		for i=1,#text_queue do -- to do: use table operation
			text_queue[i] = text_queue[i+1] -- includes last nil
		end

		if (clear_remaining) text_queue = {}
		return ret
	end

	function peektext(i)
		return text_queue[i or 1]
	end

	-- when window gains or loses focus
	local function reset_kbd_state()
		--printh("resetting kbd")
		text_queue={}
		key_state={}
		last_key_state={}

		-- block buttons
		_signal(23)

		-- block all keys
		--[[
			scancode_blocked = {}
			for k,v in pairs(name_to_scancode) do
				scancode_blocked[v] = true
			end
		]]

	end

	-- 
	function get_clipboard()

		if (_envdat.sandbox) then
			return sandbox_clipboard_text
		end

		return _get_userland_clipboard_text()
		
	end

	function set_clipboard(str)
		if (type(str) == "number") str = tostring(str)
		if (type(str) ~= "string") return

		-- set at all 3 levels regardless of context: sandbox, userland, host
		sandbox_clipboard_text = str
		_set_userland_clipboard_text(str)
		_set_host_clipboard_text(str)
	end


	local function _update_keybd()

		-- 0.1.0g: disable control keys when alt is held
		-- don't want ALTgr + 7 to count as ctrl + 7 (some hosts consider ctrl + alt to be held when ALTgr is held)
		if (key_state[lalt] or key_state[ralt]) then
			key_state[lctrl] = nil
			key_state[rctrl] = nil
		end


		if (_pidval > 3 and key"alt") then
			-- wm workspace flipping shouldn't produce keyp("left") / keyp("right")
			clear_key("left") 
			clear_key("right")
			-- host alt+enter / tab shouldn't produce keyp("enter") / keyp("tab")
			clear_key("enter")
			clear_key("tab")
		end

		-- 0.1.1e: handle ctrl-v (message only sent by wm when window has focus)
		if (pressed_ctrl_v) then

--			printh("@@ event:pressed_ctrl_v ~ simulate ctrl-v keyress")
			key_state[name_to_scancodes["lctrl"][1]] = 1    -- can set any of the physicals keys named "lctrl"
			key_state[name_to_scancodes["v"][1]] = 1        -- ditto
			last_key_state[name_to_scancodes["v"][1]] = nil -- so that keyp("v") == true
			
			-- pretend all keys are released after 0.1 seconds (artifical keypresses have no keyup message; will be sticky)
			--send_message(_pidval, {event="reset_kbd", _delay = 0.1})

			send_message(_pidval, {event="keyup", scancode = name_to_scancodes["lctrl"][1], _delay = 0.1})
			send_message(_pidval, {event="keyup", scancode = name_to_scancodes["v"][1], _delay = 0.1})

			pressed_ctrl_v = false

		elseif stat(318) == 1 then
			-- web: when ctrl-v, pretend the v didn't happen. 
			-- the only way to get ctrl-v is via the "pressed_ctrl_v" message
			if (key("ctrl") and keyp("v")) then
				clear_key("v") 
			end
		end

		-- transfer sandbox clipboard (whether triggered by virtual or regular host)

		if (key("ctrl") and keyp("v")) then
			sandbox_clipboard_text = _get_userland_clipboard_text() -- ctrl-v taken as permission to transfer from userland clipboard to sandbox
			_signal(23) -- also: block buttons. Don't want the "v" press to pass through as a button press
		end

		any_key0 = any_key1 -- last frame
		any_key1 = stat(305) -- this frame

	end




	local future_messages = {}

	--[[
		called in foot exactly once before each _update
		(and once per frame if no _update defined)
	]]
	
	function __process_event_messages()

		frame_keypressed_result = {}

		wheel_x, wheel_y, locked_dx, locked_dy = 0, 0, 0, 0

		last_key_state = unpod(pod(key_state))

		-- send an update message every update if anyone is listening (used by fs.lua fetch job polling and wrangle for watching state changes)
		-- same test as foot in foot
		if (message_hooks["update"] and ((peek(0x547f) ^^ 0x20) & 0x61) > 0) send_message(_pidval, {event="update"})

		local future_index = 1

		repeat
			
			local msg = _read_message()

			if (msg and msg._delay) msg._open_t = time() + msg._delay

			-- future messages: when _open_t is specified, open message at that time

			if (not msg and future_index <= #future_messages) then
				-- look for next future message that is ready to be received
				while (future_index <= #future_messages and future_messages[future_index]._open_t >= time()) do
					future_index += 1
				end
				msg = deli(future_messages, future_index)
			elseif (msg and msg._open_t and time() < msg._open_t) then
				-- don't process yet! put in queue of future messages
				add(future_messages, msg)
				msg = nil
			end

			
			if (msg) then

			--	printh(ser(msg))

				if (message_hooks[msg.event]) then
					for i = 1, #message_hooks[msg.event] do
						responce = message_hooks[msg.event][i](msg)
						-- 0.2.0i: when a _reply_id is present, send a responce back to ._from
						-- at this point, ._from normally has an event handler for that responce_id (installed during initial send_message) 
						if msg._reply_id then -- means sender is expecting a reply
							responce = responce or {}
							responce.event = msg._reply_id
							send_message(msg._from, responce)
						end
					end
				end

				--send to each firehose subscriber (used by wm)

				for i=1,#message_subscriber do
					message_subscriber[i](msg) -- ignore return value in this context
				end

			end -- msg ~= nil

		until not msg

		--------------------------------------------------------------------------------------------------------------------------------

		_update_keybd()

		--------------------------------------------------------------------------------------------------------------------------------

		-- when window does not have focus, ignore controller
		-- window manager can always read controller (need for pause menu control)
		-- to do: app can request background buttons in window()
		_update_buttons(_window_has_focus or _pidval <= 3)

		--------------------------------------------------------------------------------------------------------------------------------

	end

	-- flip()
	-- allow custom mainloop / #putaflipinit / jelpi style fadeout
	-- Farbs on "Meandering Thread of Execution": https://mastodon.social/@Farbs/112691223223669609

	function flip(flags)
		flags = flags or 0x4

		if (not _draw and not _update) flags |= 0x4 -- always pump messages when no mainloop [yet]

		if (flags & 0x4) > 0 and _pidval > 3 then  

			-- e.g. #putaflipinit; need to handle events

			__process_event_messages() 

			if halt_corun_program then
				halt_corun_program = false
				yield() -- to interrupt when corun in terminal
			end

			_flip(flags) -- need to flip before check pause bit

			-- hold program while paused
			while (peek(0x547f) & 0x4) > 0 do
				__process_event_messages() 
				_flip(0x1) -- superyield (don't advance time or end frame)
			end

		else
			-- vanilla flip
			_flip(flags)
		end
	end



	-----------------------------------------------------------------------------------------------------------------------------
	
	function on_event(event, f)

		-- when f is nil (or not a function) remove all hooks for that event
		if (type(f) != "function") then
			if (event and message_hooks) message_hooks[event] = nil
			return
		end

		if (not message_hooks[event]) message_hooks[event] = {}

		-- for file modification events: let pm know this process is listening for that file
		if (sub(event, 1, 9) == "modified:") then
			local filename_userland = sub(event, 10)
			local filename_kernal = filename_userland

			-- for simplicity, sandboxed processes can't subscribe to anything except /ram/shared/* 
			-- (otherwise need to handle location rewrites) in message contents
			-- if (_envdat._sandbox and filename:sub(1,12) ~= "/ram/shared/") return
			-- allow /appdata -- pm.lua can handle it
			if (_envdat._sandbox and filename_userland:sub(1,12) ~= "/ram/shared/" and filename_userland:sub(1,9) ~= "/appdata/") return

			-- sandboxed process: map 
			-- to do: should us _userland_to_kernal_path here but how to safety expost to events.lua?
			-- this is a temporary solution for bbs://trashman
			if (_envdat.sandbox and _envdat.bbs_id) then
				if (filename_userland:sub(1,9) == "/appdata/" and filename_userland:sub(1,16) ~= "/appdata/shared/") then
					filename_kernal = "/appdata/bbs/".._envdat.bbs_id.."/"..filename_userland:sub(10)
				end
			end

			_send_message(2, {
				event = "_subscribe_to_file",
				filename_userland = filename_userland, -- the file as it appears in the modified:foo -- could be relative
				filename_kernal = fullpath(filename_kernal) -- full path of unmapped file on disk / in ram
			})
		end

		add(message_hooks[event], f)
	end

	-- kernel space for now -- used by wm (jettisoned)
	function _subscribe_to_events(f)
		add(message_subscriber, f)
	end


	--[[
		input()
		send "input" event to terminal and then wait for a response 

		flags:
			0x1 hide result
			0x2 return when any key is pressed
			0x4 non-blocking
	]]
	function input(prompt, flags)
		
		flags = flags or 0
		local hide = (flags & 0x1) > 0
		local single_char = (flags & 0x2) > 0
		local non_blocking = (flags & 0x4) > 0

		prompt = prompt or "? "

		local corunning = _envdat.corun_program

--		printh("input() from process: ".._pidval)


		if (corunning) then
			-- when corunning via ctrl+r, should not pause on enter
			-- also creates fullscreen window if one does not already exist (print does this explicitly)
			window{pauseable = false}
			poke(0x547f, peek(0x547f) & ~0x8) -- not a graphical program though; print to terminal
		end

		-- when print_to_proc_id is not specified, print to self (e.g. ctrl-r running in terminal)
		_send_message(_envdat.print_to_proc_id or _pidval, {event="input",prompt=prompt,hide=hide,single_char=single_char})

		-- wandering center of execution
		-- for a terminal script, shouldn't run anything after call to input() until control returns
		repeat

--			if ((t()*8)\1 == t()*8) printh(t()) -- debug: show heartbeat
			if (input_response) then
				local res = input_response
				input_response = nil
				reset_kbd_state()
				return res
			end

			if (corunning) then -- or (peek(0x547f) & 0x8) == 0) then
				-- just yield -- let terminal foot handle the flip (otherwise get double flip and btnp / kepy logic fails) 
				yield()
			else
				-- flip needed for running program from terminal
				flip(0x5) -- 0x1 hold frame (and don't end frame) to avoid flicker; 0x4 process messages (so that input_response can arrive)
			end

		until non_blocking

		return -- non-blocking and no input: return nothing at all
	end


	--------------------------------------------------------------------------------------------------------------------------------
	-- standard events
	--------------------------------------------------------------------------------------------------------------------------------

	on_event("input_response", function(msg)
		input_response = msg.response
	end)

	on_event("mouse", function(msg)
		mouse_x = msg.mx
		mouse_y = msg.my
		mouse_b = msg.mb	
	end)

	on_event("mousewheel", function(msg)
		wheel_x += msg.wheel_x or 0
		wheel_y += msg.wheel_y or 0
	end)

	on_event("mouselockedmove", function(msg)
		locked_dx += msg.locked_dx or 0
		locked_dy += msg.locked_dy or 0
	end)

	on_event("keydown", function(msg)
		key_state[msg.scancode] = 1
	end)

	on_event("keyup", function(msg)
		key_state[msg.scancode] = nil
	end)

	-- needed for web hacks; defer keypress message until after received clipboard contents
	on_event("pressed_ctrl_v", function(msg)
		pressed_ctrl_v = true
	end)

	-- used by wm to stop keypresses getting through
	on_event("clear_key", function(msg)
		-- printh("[".._pidval.."] clear_key: "..tostring(msg.scancode))
		clear_key(msg.scancode)
	end)

	on_event("reset_kbd", function(msg)
		reset_kbd_state()
	end)

	on_event("reset_kbd_for_paste", function(msg)
		clear_key("v")
	end)

	on_event("textinput", function(msg)
		if not(key"ctrl") and #text_queue < 1024 then -- ignore textinput when ctrl is held // do here in (rather than in os_sdlem.c) to respect ctrl mapping
			text_queue[#text_queue+1] = msg.text;
		end
	end)

	on_event("gained_focus", function(msg)
		_signal(15) -- give audio priority to this process; can steal PFX6416 control on note() / sfx() / music()
		_window_has_focus = true
		_window_can_read_kbd = true
		reset_kbd_state()
		poke(0x547f, peek(0x547f) | 0x10)
	end)

	on_event("lost_focus", function(msg)
		_window_has_focus = false
		if (_pidval > 3) _window_can_read_kbd = false
		reset_kbd_state()
		poke(0x547f, peek(0x547f) & ~0x10)
	end)

	on_event("gained_visibility", function(msg)
		poke(0x547f, peek(0x547f) | 0x1)
	end)

	on_event("lost_visibility", function(msg)
		if (_pidval > 3) poke(0x547f, peek(0x547f) & ~0x1) -- safety: only userland processes can lose visibility
	end)

	on_event("resize", function(msg)
		--printh("resize: "..pod(msg))
		-- throw out old display and create new one. can adjust a single dimension
		if (get_display()) then
			-- set x,y because sometimes want to use resize message to also adjust window position so that
			-- e.g. width and x visibly change at the same frame to avoid jitter (ref: window resizing widget)
			window{width = msg.width, height = msg.height, width0 = msg.width0, height0 = msg.height0, x = msg.x, y = msg.y}
		end
	end)

	on_event("squash", function(msg)
		
		window{
			width  = msg.width,
			height = msg.height,
			x = msg.x, y = msg.y, squash_event = true
		}
	end)

	-- placeholder event used when confirming window close from confirm.p64
	-- to do: general solution for allowing programs to do something just before they are closed
	on_event("exit", function(msg)
		if (_pidval > 3 and msg._flags and (msg._flags & 0x1) > 1) exit()
	end)

	-- events used by userland programs

	if (_pidval > 3) then
		on_event("pause",       function() poke(0x547f, peek(0x547f) |  0x4) reset_kbd_state() end)
		on_event("unpause",     function() poke(0x547f, peek(0x547f) & ~0x4) reset_kbd_state() end)
		on_event("exit", exit)
	end

	if _envdat.corun_program then
		on_event("halt", function(msg)
			halt_corun_program = true -- halt in next flip();
		end)
	end


	_export_functions_to_head{
		flip = flip,
		on_event = on_event
	}


end


