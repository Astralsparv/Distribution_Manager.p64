
local _envdat = env() -- keep a local copy for speed
local _pid = pid
local _set_draw_target = _set_draw_target
local _send_message  = _send_message
local _unmap = unmap

-- manage process-level data: dispay, env

-- reference to display and draw target owned by window.lua
local _disp = nil
local _target = nil

-- default to display
function set_draw_target(d)

	-- 0.1.0h: unmap existing target (garbage collection)
	_unmap(_target, 0x10000)
	
	d = d or _disp

	local ret = _target
	_target = d
	_set_draw_target(d)

	-- map to 0x10000 -- want to poke(0x10000) in terminal, or use specialised poke-based routines as usual
	-- draw target (and display data source) is reset to display after each _draw() in foot
	memmap(d, 0x10000)
	
	return ret

end

function get_draw_target()
	return _target
end

-- used to have a set_display to match, but only need get_display(). (keep name though; display() feels too ambiguous)
function get_display()
	return _disp
end

---------------------------------------------------------------------------------------------------

local first_set_window_call = true

local function set_window_1(attribs)

	-- to do: shouldn't be needed by window manager itself (?)
	-- to what extent should the wm be considered a visual application that happens to be running in kernel?
	-- if (_pid() <= 3) return

	attribs = attribs or {}


	-- on first call, observe attributes from env().window_attribs
	-- they **overwrite** any same key attributes passed to set_window
	-- (includes pwc_output set by window manager)

	if (first_set_window_call) then

		first_set_window_call = false

		poke(0x547f, peek(0x547f) | 0x8) -- window created; changes behaviour of print()
	
		if type(_envdat.window_attribs) == "table" then
			for k,v in pairs(_envdat.window_attribs) do
				attribs[k] = v
			end
		end

		-- set the program this window was created with (for workspace matching)

		attribs.prog = _envdat.argv[0]


		-- special case: when corunning a program under terminal, program name is /ram/cart/main.lua
		-- (search /ram/cart/main.lua in wrangle.lua -- works with workspace matching for tabs)

		if (attribs.prog == "/system/apps/terminal.lua") then
			attribs.prog = "/ram/cart/main.lua"
		end

		
		-- first call: decide on an initial window size so that can immediately create display

		-- default size: fullscreen (dimensions set below)
		if not attribs.tabbed and (not attribs.width or not attribs.height) then
			attribs.fullscreen = true
		end

		-- not fullscreen, tabbed or desktop, and (explicitly or implicitly) moveable -> assume regular moveable desktop window
		if (not attribs.fullscreen and not attribs.tabbed and not attribs.wallpaper and
			(attribs.moveable == nil or attribs.moveable == true)) 
		then
			if (attribs.has_frame  == nil) attribs.has_frame  = true
			if (attribs.moveable   == nil) attribs.moveable   = true
			if (attribs.resizeable == nil) attribs.resizeable = true
		end


		-- wallpaper has a default z of -1000
		if (attribs.wallpaper) then
			attribs.z = attribs.z or -1000 -- filenav is -999
		end

		-- clear background processing bits on first window() call; 
		-- need to set with window{background_updates=true} (0x40) and/or window{background_draws=true} (0x80)
		-- there might be a bit set by terminal for bootstrapping to get to this point
		poke(0x547f, peek(0x547f) & 0x3f)

	end

	-- video mode implies fullscreen

	if (attribs.video_mode) then
		attribs.fullscreen = true
	end


	-- setting fullscreen implies a size and position

	if attribs.fullscreen then
		attribs.width = 480
		attribs.height = 270
		attribs.x = 0
		attribs.y = 0
	end

	-- setting tabbed implies a size and position  // but might be altered by wm

	if attribs.tabbed then
		attribs.fullscreen = nil
		attribs.width = 480
		attribs.height = 248+11
		attribs.x = 0
		attribs.y = 11
	end

	-- setting new display size
	if attribs.width and attribs.height then

		local scale = 1
		if (attribs.video_mode == 3) scale = 2 -- 240x135
		if (attribs.video_mode == 4) scale = 3 -- 160x90
		local new_display_w = attribs.width  / scale
		local new_display_h = attribs.height / scale


		local w,h = -1,-1
		if (get_display()) then
			w = get_display():width()
			h = get_display():height()
		end

		-- create new bitmap when display size changes
		if (w != new_display_w or h != new_display_h) then
			-- this used to call set_display(); moved inline as it should only ever happen here

			-- 0.1.0h: unmap existing display (garbage collcetion)
			_unmap(_disp, 0x10000)

			_disp = userdata("u8", new_display_w, new_display_h)
			memmap(_disp, 0x10000)
			set_draw_target() -- reset target to display

			-- set display attributes in ram
			poke2(0x5478, new_display_w)
			poke2(0x547a, new_display_h)

			poke (0x547c, attribs.video_mode or 0)

			poke(0x547f, peek(0x547f) & ~0x2) -- safety: clear hold_frame bit
			-- 0x547d is blitting mask; keep previous value
		end
	end

	if (attribs.background_updates) poke(0x547f, peek(0x547f) | 0x40)
	if (attribs.background_draws)   poke(0x547f, peek(0x547f) | 0x80)

--		printh("set_window_1: "..pod(attribs))

	_send_message(3, {event="set_window", attribs = attribs})

end

-- set preferred size; wm can still override
function window(w, h, attribs)

	-- this function wrangles parameters;
	-- set_window_1 doesn't do any further transformation / validation on parameters

	if (type(w) == "table") then
		attribs = w
		w,h = nil,nil

		-- special case: adjust position by dx, dy
		-- discard other 
		if (attribs.dx or attribs.dy) then
			_send_message(3, {event="move_window", dx=attribs.dx, dy=attribs.dy})
			return
		end

	end

	attribs = attribs or {}
	attribs.width = attribs.width or w
	attribs.height = attribs.height or h
	attribs.parent_pid = _envdat.parent_pid

	return set_window_1(attribs)
end


-- fullscreen videomode with no cursor
function vid(mode)
	window{
		video_mode = mode,
		cursor = 0
	}
end
