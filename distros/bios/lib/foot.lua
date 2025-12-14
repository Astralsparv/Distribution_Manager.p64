--[[pod_format="raw",created="2024-03-11 18:02:01",modified="2024-04-23 11:47:10",revision=5]]
--[[
	foot.lua
]]

local pidval = pid()
local envdat = env()

-- init first; might set window inside _init
-- to do: no visual feedback while _init does a lot of work. maybe need to spin the picotron button gfx!
if (_init) _init() 

-- create a fullscreen window if _draw exists at this point, but program didn't explicitly call window() yet
if (_draw and not get_display() and not envdat.corun_program) then
	window()
end

-- 0x20: has draw function (used for automatic priority adjustment in get_process_list)
--       when not set, implies background_updates
if (_draw) poke(0x547f, peek(0x547f) | 0x20)

-- mainloop: when _draw or _update exists // this mainloop used by /everything/ including wm
while (_draw or _update) do

	--local t0 = stat(1) -- debug

	-- __process_event_messages called once before every _update -- assumed by keyp() and btnp
	-- when only _draw exists (and not _update), still called once per frame
	__process_event_messages()

	-- debug: look for spikes in wm message processing (> 1%)
	-- if (pidval==3 ((stat(1) - t0)\0.001) > 10) printh("[foot] wm messages cpu spike: "..((stat(1) - t0)\0.001))


	if (peek(0x547f) & 0x4) > 0 and pidval > 3 then

		-- paused: nothing left to do this frame; just superyield
		flip(0x1)

	else

		-- set a hold_frame flag here and unset after mainloop completes (in flip) 
		-- window manager can decide to discard half-drawn frame. --> PICO-8 semantics
		-- moved to start of mainloop so that _update() can also be halfway through
		-- drawing something (perhaps to a different target) without it being exposed

		poke(0x547f, peek(0x547f) | 0x2)

		-- 0.2.0h: only run _update when visible (0x01) or app opted in with bit 0x40 // window{ background_updates = true }
		-- OR: if doesn't have a _draw function (^^ 0x20) --> don't need to opt in if program never creates a window (e.g. some kind of daemon)
		if (_update and ((peek(0x547f) ^^ 0x20) & 0x61) > 0) then

			_update()

			local fps = stat(7)
			if (fps < 60) __process_event_messages() _update()
			if (fps < 30) __process_event_messages() _update()

			-- below 20fps, just start running slower. It might be that _update is slow, not _draw.
		end

		if (_draw and (peek(0x547f) & 0x81) > 0) -- window is visible (0x1) or has background draws (0x80)
		then
			_draw()
		elseif (pid() <= 3) then
			-- safety for wm: draw next frame. // to do: why is this ever 0 for kernel processes? didn't received gained_visibility message?
			-- printh("[foot] ** forcing draw of wm (visibility bit not set) **")  -- to do: why is this happening?
			poke(0x547f, peek(0x547f) | 0x1)
		end

		flip(0x0) -- vanilla flip: no more computation this frame, and show whatever is in video memory

	end

end
