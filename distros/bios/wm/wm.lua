--[[

	Picotron Window Manager
	(c) Lexaloffle Games LLP

	Warning: this is a WIP -- a lot of internals are experimental and/or will change

]]


include("/system/wm/toolbar.lua")
include("/system/wm/infobar.lua")
include("/system/wm/sparkles.lua")

local default_cursor_gfx = userdata("[gfx]10100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000001710000000000000177100000000000017771000000000001777710000000000177110000000000001171000000000000000000000000000000000000[/gfx]")


local bar_h = 12 -- same as toolbar.lua. how to sync? global data?
local tooltray_default_h = 80

local mx, my, mb, mdx, mdy

local head_gui = nil

local workspace = {} -- desktop workspace
local ws_gui = nil   -- current workspace
local tooltray_gui = nil   -- global tooltray gui
local tooltray_active_window = nil -- set to a tooltray window when has focus
local workspace_index = 1
local last_desktop_workspace = nil
local last_fullscreen_workspace = nil
local toolbar_y        = 0
local toolbar_y_target = 0
local infobar_y        = 270 --270-11
local infobar_y_target = infobar_y
local held_frames = 0
local next_ws_id = 100 -- start high for debugging; easy to distinguish between index vs id
local created_fullscreen_terminal = false

local sdat = fetch"/appdata/system/settings.pod" or {}


local _set_userland_clipboard_text = _set_userland_clipboard_text
local _get_host_clipboard_text = _get_host_clipboard_text

local last_draw_window = nil

function show_reported_error() -- happens when error is reported
	open_infobar()
	infobar_y_target = 200 -- not too high, want to see code
end

-- to do: remove; can use a stat() and keep track at a lower level (do anyway for battery saver logic)
local last_input_activity_t = 0

-- store some things by process so that they can be manipulated before window is created
local proc_icon = {}
local proc_menu = {}

local char_w = peek(0x5600)

local prev_frame = nil

local last_mx, last_my, last_mb

local pending_saves = {}
local pending_save_errors = 0
local save_working_cart_files_t = 0

-- keep track of pwc unsaved changes
local pwc_unsaved_changes = false
on_event("reset_pwc_unsaved_changes",function() pwc_unsaved_changes = false end) -- used by load, save utilities
on_event("pwc_unsaved_changes", function() return {result = pwc_unsaved_changes} end)


-- wrangle.lua uses this to report changes to the in-memory version of the file for that process
on_event("set_unsaved_changes", function(msg) 
	if (time() < 5) return -- ignore changes made during boot (/ram/cart/main.lua etc)
	local win = get_window_by_proc_id(msg._from)
	if (win) win.unsaved_changes = msg.val
	if (msg.filename:sub(1,10) == "/ram/cart/" and msg.val) pwc_unsaved_changes = true -- 0.2.1c: only when msg.val is truthy >_<
end)

-- include present working cartridge and open files
-- (used by shutdown / reboot in confirm.p64)
on_event("any_unsaved_changes", function() 
	if (pwc_unsaved_changes) return {result = true}

	-- search windows
	for i=1,#workspace do
		for j=1, #workspace[i].child do
			local win = workspace[i].child[j]
			if (win.unsaved_changes) return {result = true}
		end
	end

	return {result = false} 
end)



function generate_head_gui()

--	printh("generate_infobar_gui "..time())
	
	head_gui = create_gui{
		x = 0, y = 0, 
		width = 480, height = 270
	}

--[[
	-- debug
	function head_gui:draw()
		cls(9)
		camera() clip()
		rectfill(0,0,1000,1000,8)
		rectfill(0,0,1000,30,10)
		for i=1,#head_gui.child do
			local c = head_gui.child[i]
			print(pod{c.sx, c.sy, c.width, c.height}, 340, 30+i*10, 7)
		end
		for i=1,#ws_gui.child do
			local c = ws_gui.child[i]
			print(pod{c.sx, c.sy, c.width, c.height}, 340, 90+i*10, 7)
		end
	end
]]

	toolbar_gui = generate_toolbar_gui()
	infobar_gui = generate_infobar_gui()

	head_gui.child = {}
	head_gui:attach(tooltray_gui)
	head_gui:attach(tooltray_overlay)
	head_gui:attach(ws_gui)
	head_gui:attach(ws_gui_overlay)

	head_gui:attach(toolbar_gui)
	head_gui:attach(infobar_gui)


	function head_gui:update()

		-- slide infobar / infobar to targets
		toolbar_y = (toolbar_y * 3 + toolbar_y_target) / 4
		infobar_y = (infobar_y * 3 + infobar_y_target) / 4
		
		-- move towards target a pixel so that can reach exact value. also just nicer motion (no single-pixel creep at end; small transitions are faster)

		if (toolbar_y < toolbar_y_target) then
			toolbar_y = min(toolbar_y + 1, toolbar_y_target) else
			toolbar_y = max(toolbar_y - 1, toolbar_y_target) end

		if (infobar_y < infobar_y_target) then
			infobar_y = min(infobar_y + 1, infobar_y_target) else
			infobar_y = max(infobar_y - 1, infobar_y_target) end
		

		-- tooltray visibility
		if (tooltray_is_open() ~= last_tooltray_is_open) then
			for i=1,#tooltray_gui.child do
				send_message(tooltray_gui.child[i].proc_id, {event=tooltray_is_open() and "gained_visibility" or "lost_visibility"})
			end
		end
		last_tooltray_is_open = tooltray_is_open()

		-- don't draw under toolbar (optimisation)
		tooltray_gui.height = toolbar_y - tooltray_gui.y


		-- to do: show_bars should be initial state, and then docked is optional
		local show_toolbar = ws_gui.show_toolbar 
--		local show_infobar = ws_gui.show_infobar
		local show_infobar = get_show_infobar()

		if (key("alt")) show_toolbar = true

		-- auto-showing bars using mouse position is annoying in fullscreen; just for tools / desktop
		-- fullscreen has ESC, but tools have no other way to reach toolbar (without knowing kbd shortcut)
		--if (false) then
		if (ws_gui.style ~= "fullscreen") then
			--if ((my < 2 and mb == 0) or my < toolbar_y + toolbar_gui.height) then 
			if ((my < 2 and mb == 0)) then -- don't need second test if doing ws_gui.show_toolbar = true; allows ctrl-1 to immediately hide even while mouse is at top
				show_toolbar = true
				ws_gui.show_toolbar = true -- experimental: low friction to de-fullscreenify. can turn off at system settings level
			end
			-- if ((my >= 270-2 and mb == 0) or my >= infobar_y) show_infobar = true
		end

		if (screensaver_proc_id) then
			show_toolbar, show_infobar = false, false
		end

		-- never show toolbar when export is locked in fullscreen mode
		if (is_locked_in_fullscreen()) show_toolbar = false

		if (show_toolbar) then
			toolbar_y_target = max(toolbar_y_target, 0)
			-- snap. assumption: never want to leave an 8px (or less) sliver visible at top
			if (toolbar_y_target < 8 and mb == 0) toolbar_y_target = 0
		else
			-- hide [unless pulled out]
			--if (toolbar_y < 40) 
			toolbar_y_target = -toolbar_gui.height 
		end

		if (show_infobar) then
			infobar_y_target = min(infobar_y_target, 270-12)
			-- snap. assumption: never want to leave an 8px (or less) sliver visible at top
			if (infobar_y_target >= 270 - 12-8 and mb == 0) infobar_y_target = 270-12 -- can't use infobar_gui.height -- is 270, not 12!
		else
			-- hide [unless pulled out]
			--if (infobar_y > 270-40) 

			infobar_y_target = 270
		end



		-- jump when workspace changed (otherwise can see uncovered area e.g. above tabbed window)
		if (time() < head_gui.t0 + 0.2) then
			toolbar_y = toolbar_y_target
		end


		--------- apply toolbar / infobar position --------		

--		tooltray_gui.y = min(0, - tooltray_default_h / 1.5 + toolbar_y / 1.5) \ 1 -- move at different speed; feels more like a deep drawer. ottoman
--		tooltray_gui.y = toolbar_y - tooltray_default_h  -- same speed (testing concept: toolbar / tray is more of a single thing. too chunky)
		
		toolbar_gui.y  = toolbar_y \ 1
		toolbar_gui.sy = toolbar_y \ 1
		ws_gui.y       = max(0, toolbar_y \ 1) -- when toolbar is overlapping (fullscreen) and above top, workspace stops moving up at 0
		infobar_gui.y  = infobar_y \ 1
		infobar_gui.sy = infobar_gui.y

	end

end

-- new version: derive attributes from window and calling program
function create_workspace_1(proc_id, win_attribs)
	local ws = head_gui:new()
	ws.x = 0
	ws.y = 0
	ws.width = 480
	ws.height = 270
	ws.id = next_ws_id  next_ws_id += 1
	ws.icon = win_attribs.icon 
	ws.head_proc_id = proc_id
	ws.prog = win_attribs.prog
	ws.tabs = {}

	-- workspace inherits some of the attributes of window; 
	-- used when deciding which workspace to create windows in
	ws.style = "fullscreen"
	if (win_attribs.fullscreen) ws.style = "fullscreen"       -- default, but tested here for clarity
	if (win_attribs.workspace == "new") ws.style = "desktop"  -- requesting new workspace mean requesting new desktop
	if (win_attribs.tabbed) ws.style = "tabbed"               -- ignore fullscreen if it is set

	-- workspace inherits pwc_output during recovery (out of memory crash requires recreating terminal)
	if (win_attribs.pwc_output) ws.pwc_output = true  ws.recovering = false

	-- default desktop workspace icon
	if not ws.icon then
		ws.icon = ws.style == "desktop" and 
			userdata"[gfx]08087777777777777777777777777777777700000000777777777700007700000000[/gfx]" or  -- desktop
			userdata"[gfx]09070007070000000700007777777777700000777700000777700000777777777770[/gfx]"     -- tv
	end

	-- initialise toolbar / infobar docking based on style
	ws.show_toolbar = ws.style ~= "fullscreen"
	ws.show_infobar = false

	-- opening a window into a desktop that has no underlay -> clear each frame 
	-- (harmless if false positive -- just slightly inefficient)
	if (ws.desktop and win_attribs.width < 480) then
		ws.clear_each_frame = true
	end
	
	-- ignore workspace flow while booting
	visit_workspace(ws)

	function ws:draw()
		--cls(3) -- debug: see when workspace is redrawn
		if (not self.child or #self.child == 0) then
--[[
			-- pinboard pattern
			fillp(0x1,0,0,0,0,0,0,0)
			rectfill(0,0,self.width,self.height,0x0501)
			fillp()
			rrectfill(self.width/2-45, self.height/2-5-7, 90, 19, 0, 1)
			
			print("\014[ empty workspace ]",self.width/2-19*2,self.height/2-5,6)
]]			
			rectfill(0,0,self.width,self.height,16)
			print("[ empty workspace ]",self.width/2-19*2.5,self.height/2-5,6)
			-- print("~ click to close ~",self.width/2-18*2.5,self.height/2+10,13)
		end
	end

	-- 0.2.0i: autoclose only fullscreen workspaces (that are not pwc output)
	--> cart can have their own Exit functionality and call exit()
	function ws:update()

		if (not self.child or #self.child == 0) then
			if self.style == "fullscreen" and not self.pwc_output then
				close_workspace(workspace_index)
				set_workspace(previous_workspace)
			else


				-- ctrl-o to open a file; copied and modified from toolbar.lua::make_new_tab_button()
				if key"ctrl" and keyp"o" then

					create_process("/system/apps/filenav.p64", 
					{
						path=get_workspace().last_dir,
						intention="new_tab",
						use_ext= get_workspace().last_ext or ".txt",
						window_attribs={workspace = "current",autoclose=true},
						open_with = get_workspace().prog,
					})

				end



				-- open file navigator
				-- meh ~ can use the [+] new tab button. Don't need to introduce a new concept
--[[
				create_process("/system/apps/filenav.p64", {argv={"/ram/cart"},
					window_attribs = {
						workspace = "current",
						show_in_workspace = true, -- don't become active
						width = 480-80, height = 258-80,
						x = 0+40, y = 11+40,
						has_frame = false,
						moveable = false,
						resizeable = false,
						empty_workspace_file_chooser = true -- a bit different to autoclose; doesn't respond to ESC
					}
				
				})
]]
			end
		end
	end

--[[
	-- deleteme -- fullscreen workspaces now close automatically, and
	-- other workspaces should be harder to close (right click on workspace icon)
	function ws:tap()
		if (not self.child or #self.child == 0) then
			close_workspace(workspace_index)
			set_workspace(previous_workspace)
		end
	end
]]

	local pos = 1
	while (workspace[pos] and ws.head_proc_id > workspace[pos].head_proc_id) do
		pos += 1
	end

	local result = add(workspace, ws, pos)

	return result, pos
end

-- globals used by toolbar.lua

function get_workspace(index)
	if (not index) return ws_gui or {}
	return workspace[index] or {}
end

function get_num_workspaces()
	--printh("get_num_workspaces(): "..tostr(#workspace))
	return #workspace
end

function get_workspace_index()
	return workspace_index
end

function get_workspace_tabs()
	return (ws_gui and ws_gui.tabs) or {}
end

function get_workspace_icon(index)
	local icon = nil
	if (workspace[index]) then
		icon = proc_icon[workspace[index].head_proc_id]
		if (not icon and workspace[index].style == "desktop") then
			icon = userdata("[gfx]08087777777777777777777777777777777700000000777777777700007700000000[/gfx]")
		end
	end

	-- default: tv
	if (not icon) icon = userdata("[gfx]0907000707000000070000777777777770000077770000077770000077777777777[/gfx]")
	return icon
end



local last_active_win = nil


local put_x = 0
local put_y = 0



function tooltray_is_open()
	return toolbar_y > 0
end

-- used for keeping track of which workspace to toggle between (ESC) or where desktop is
-- when deciding to put new windows
function visit_workspace(ws)

	if (ws.style == "fullscreen") last_fullscreen_workspace = ws
	if (ws.style ~= "fullscreen") last_non_fullscreen_workspace = ws
	if (ws.style == "desktop") last_desktop_workspace = ws
	if (ws.style ~= "desktop") last_non_desktop_workspace = ws
	if (ws.pwc_output) last_pwc_output_workspace = ws

end



--[[
	set_workspace(index)

	index can be the workspace value -- this is because index might change
	when creating new workspace, so sometimes references should be by value
	(last_desktop_workspace, last_fullscreen_workspace)
]]
function set_workspace(index)

	if (index == nil) return

--	printh("set_workspace "..tostring(index))

	-- find by value
	if (type(index) == "table") then		
		for i=1,#workspace do
			if (workspace[i] == index) index = i
		end
	end

	-- couldn't find; use first workspace
	if (type(index) == "table") then
		index = 1
	end

	-- hide any modal gui elements
	dismiss_modal()

	-- safety: no workspaces exists
	if (#workspace == 0) then
		return
	end

	-- loop around
	workspace_index = 1 + ((index - 1) % #workspace)

	ws_gui = workspace[workspace_index]
	
	visit_workspace(ws_gui)

	-- invalidate active window if not found
	if (ws_gui.active_window) then
		local found = 0
		for i=1,#ws_gui.child do
			if (ws_gui.child == ws_gui.active_window) found = true
		end
		if (not found) ws_gui.active_window = false
	end

	generate_head_gui()


end

-- can return nil
function get_active_window()

	-- to do: might not need this
	if (tooltray_active_window and tooltray_is_open()) then 
		return tooltray_active_window
	end
	
	if (not ws_gui or #ws_gui.child == 0) then 
		return nil 
	end

	-- prefer last clicked window
	
	if (ws_gui.active_window and not ws_gui.active_window.closing and not ws_gui.active_window.wallpaper) then
		return ws_gui.active_window
	end

	-- look backwards through list of windows
	for i=#ws_gui.child, 1, -1 do
		if not ws_gui.child[i].closing and not ws_gui.child[i].wallpaper then
			return ws_gui.child[i]
		end
	end

	-- safety: return last child // happens during startup?
	-- printh("using last child in get_active_window")
	return ws_gui.child[#ws_gui.child]
end

function _init()

	cursor_gfx = fetch"/system/misc/cursors.gfx"

	prev_frame = userdata("u8", 480, 270)

	------------------------ separate font for window manager ------------------------


	poke(0x4000,get(fetch"/system/fonts/lil.font"))
	poke(0x5600,get(fetch"/system/fonts/p8.font"))

--	poke(0x5600,get(fetch"/system/fonts/pug.font"))

--	poke(0x4002, (@0x4002)+3)
--	poke(0x4004, 1) -- offset_y


	----------------------------------------------------------------------------------


	-- safety: window manager itself needs to be visible! (also safety in foot though)
	send_message(pid(), {event="gained_visibility"})  --  pokes 0x547f:0x1

--	open initial processes: desktop (default workspace), code, gfx, map, sfx, full-screen terminal (esc to toggle)
	
	-- ==========================================================================================================================================
	-- single global tooltray gui
	-- ==========================================================================================================================================
	-- 

	tooltray_gui = {x=0, y=0, width=480, height=270, 
		draw=function(self, msg) 
			--[[
			rectfill(0,0,self.width,self.height, 3) -- green background for debugging
			print("tooltray:"..#self.child, 4,4, 7)
			for i=1,#self.child do
				local c = self.child[i]
				print(pod{c.x,c.y,c.width,c.height},30,12+i*10,7)
				
			end
			]]
		end
	}

	tooltray_overlay = {x=0, y=0, width=0, height=0, -- don't interact
		draw=function(self, msg)
			if (msg.mb and dragging_window and dragging_window.parent ~= tooltray_gui and msg.my < toolbar_y) then
				clip()
				local win = dragging_window
				local x0 = msg.mx - dragging_window_xo
				local y0 = msg.my - (dragging_window_yo - toolbar_y)
				if (win.has_frame) y0 -= 12 -- drop down because titlebar not drawn
				y0 = max(y0, 0) -- snap to y >= 0 when dropped
				_blit_process_video(win.proc_id, 0, 0, nil, nil,x0, y0)
			end
		end,
		-- abuse visibility mechanism: don't draw in window actual position this frame		
		update=function(self, msg)
			local mx,my = mouse()
			if (msg.mb and dragging_window and dragging_window.parent ~= tooltray_gui and msg.my < toolbar_y) then
				dragging_window.visible = false
			end
		end
		
	}

	-- for dragging windows from toolbar -> ws_gui (copied and modified from above)
	ws_gui_overlay = {x=0, y=0, width=0, height=0, -- don't interact
		draw=function(self, msg)
			if (msg.mb and dragging_window and dragging_window.parent == tooltray_gui and msg.my >= toolbar_y) then
				clip()
				local win = dragging_window
				local x0 = msg.mx - dragging_window_xo
				local y0 = msg.my - dragging_window_yo
				if (win.has_frame) y0 -= 12 -- drop down because titlebar not drawn
				y0 = max(y0, toolbar_y + 12) -- snap to under toolbar (same as when dragging from desktop -> tooltray)
				_blit_process_video(win.proc_id, 0, 0, nil, nil,x0, y0)
			end
		end,
		-- abuse visibility mechanism: don't draw in window actual position this frame		
		update=function(self, msg)
			if (msg.mb and dragging_window and dragging_window.parent == tooltray_gui and msg.my >= toolbar_y) then
				dragging_window.visible = false	
			end
		end
	}



	-- ==========================================================================================================================================

	-- forward (low-level) event messages to active window
	-- should be fast; everything has to go through here

	local forward_events = {keydown=1, keyup=1, textinput=1, mousewheel=nil, mouselockedmove=1, pressed_ctrl_v=1, reset_kbd=1}
	local activity_events = {keydown=1, keyup=1, textinput=1, mousewheel=1, mouse=1, pressed_ctrl_v=1}

	_subscribe_to_events( 
		function(msg)
			if (ws_gui == nil) then return end

			if msg.event == "keydown" then

				last_input_activity_t = time()

				-- alt + left,right,enter filtered out (used by window manager)
				-- needs to be here (and not in events.lua) because key state is reset when switching tabs

				if key("alt") then
					if (msg.scancode == 79 or msg.scancode == 80 or msg.scancode == 40) return
				end

				-- filter ctrl combinations
				if key("ctrl") then
					-- needs to be here (and not in events.lua) because key state is reset when switching tabs
					if (msg.scancode == 43) return -- tab / ctrl+shift+tab

					-- moved to events.lua so that can be mapped; especially for ctrl-s
					-- if (msg.scancode == 22) return -- ctrl+s 
					-- if (msg.scancode == 35) return -- ctrl+6 capture screenshot
					-- if (msg.scancode == 36) return -- ctrl+7 capture label
				end

			end


			if (forward_events[msg.event]) then

				local win = get_active_window()
				if (win and win.proc_id) then
					send_message(win.proc_id, msg)
				end

			elseif msg.event == "mousewheel" then
				-- special case: mousewheel sent to window under cursor even when window is not active
				-- e.g. scroll a text file that is partially hidden
				local hover_win = head_gui:el_at_xy(mx, my)
				if (hover_win and hover_win.proc_id) then
					send_message(hover_win.proc_id, msg)
				end
--[[
			else
				printh("wm event: "..msg.event)
]]
			end

		end
	)

	-- 0.1.1e forward drop_items to active window, but need to add mx,my ("drop_items" was in forward_events)
	-- when from hosts, always choose mx,my at center of window for now
	-- (mouse position not available on all platforms, best just to not expose it)
	on_event("drop_items", function(msg)
		-- 0.2.0i only system process can drop items (incl sandboxed filenav)
		-- 0.2.1c fixed; _flags wasn't set when sent by process_dropped_files()
		if (not msg._flags or msg._flags & 0x1 == 0) return 
		local win = get_active_window()
		if (win and win.proc_id) then
			msg.mx = win.width \ 2
			msg.my = win.height \ 2
			msg.from_proc_id = 0 -- special meaning: dropped from host
			send_message(win.proc_id, msg)
		end
	end)

	-- ==========================================================================================================================================

	on_event("drag_toolbar",
		function (msg)
			--toolbar_y_target = mid(0, toolbar_y + msg.dy, tooltray_default_h) -- limiting feels bad
			toolbar_y_target = mid(0, toolbar_y + msg.dy, infobar_y-11)
			toolbar_y = toolbar_y_target
		end
	)

	on_event("drag_infobar",
		function (msg)
			infobar_y_target = mid(0, infobar_y + msg.dy, 270-11)
			infobar_y = infobar_y_target
		end
	)

	-- used by toolbar; maybe should just be a function call
	on_event("bring_window_to_front",
		function (msg)
			local win = get_window_by_proc_id(msg.proc_id)
			if (win) set_active_window(win)		
		end
	)


	on_event("modified:/appdata/system/settings.pod",
		function (msg)
			sdat = fetch"/appdata/system/settings.pod"
		end
	)

	-- window can request that it be grabbed (normally used by frameless windows)
	on_event("grab", function(msg)
		local win = get_window_by_proc_id(msg._from)
		local mx,my,mb = mouse()
		if (win and mb == 1) then
			dragging_window = win
			if (win) set_active_window(win)
			local mx, my = mouse()
			dragging_window_xo = mx - win.x
			dragging_window_yo = my - win.y
			win.start_grab_x = win.x\1
			win.start_grab_y = win.y\1
			win.start_grab_t = time()
		end
	end)

	-- deleteme; staleness is being decomissioned (see wrangle.lua)
--[[
	on_event("set_stale_windows", function(msg)

		local win = get_window_by_proc_id(msg._from)
		if (not win) return

		-- let other windows know they are stale (same test for sameness as next block)
		for i=1,#workspace do
			for j=1, #workspace[i].child do
				local win2 = workspace[i].child[j]
				if win2 ~= win and not win2.closing and type(win.location) == "string" and type(win2.location) == "string" and 
					win.location:path() == win2.location:path() 
				then
					win2.stale = true
					send_message(win2.proc_id, {event = "set_stale", val = true, filename = win2.location})
				end
			end
		end
	end)
]]


	
	toolbar_gui = toolbar_init()
	infobar_gui = infobar_init()

	generate_head_gui()

	--_signal(36) -- finished loading core processes  (deleteme -- shouldn't need)
	--flip()
end

local dark_col = {0,0,1,19, 20,21,22,6, 2,25,9,27, 16,18,24,22,  1,19,1,1, 21,0,5,24, 2,4,27,3, 12,13,24,4}
for i=1,#dark_col do dark_col[i] |= 0x40 end -- it is the colour table entry that sets stencil bits in the target


function draw_window_frame(win)

	-- screen coordinates; want to use clip() for title
	-- to do: how to use clip() relative to camera? there should be a nice way
	camera()
	local x0 = win.sx
	local y0 = win.sy
	local x1 = win.sx + win.width  - 1
	local y1 = win.sy + win.height - 1
	
	local bar_col = theme"dormant_frame"
	local border_col = theme"dormant_border"
	local title_col = theme"dormant_title"

	-- adjust for base gui position; to do: shouldn't be necessary

	

	if (get_active_window() == win) then 
		-- active window colours
		
		bar_col = theme"window_frame"
		border_col = theme"window_border"
		title_col = theme"window_title"
	end

	rectfill(x0,y0-bar_h, x1,y0-1,  bar_col)
	rectfill(x0,y0-1, x1,y0-1,  border_col)

	-- outside outline: cuts into corners by 1 pixel
	y0 = y0 - bar_h


	-- to do: need to calculate width for variable width font
	-- to do: need to calculate y offset based on font

	clip(x0+16, y0, (x1-x0)-26, y1-y0)
	local title1 = win.title
	if (win.unsaved_changes and title1[1] ~= "*") title1 = "*"..title1
	--if (win.stale) title1 = "["..title1.."]" -- debug: show which window(s) are stale   -- deleteme
	print(title1,max(x0 + 16, (x0+x1)/2 - #title1*char_w/2), y0+2, title_col)
	clip()

	line(x0+1, y0-1, x1-1, y0-1, border_col)
	pset(x0,y0,border_col)
	pset(x1,y0,border_col)

	if not sdat.squishy_windows or (get_active_window() != win) then

		-- sides, bottom
		line(x0+1, y1+1, x1-1, y1+1, border_col)
		line(x0-1, y0+1, x0-1, y1-1, border_col)
		line(x1+1, y0+1, x1+1, y1-1, border_col)

		-- bottom corners
		pset(x0,y1,border_col)
		pset(x1,y1,border_col)

	else

		-- partial sides for active squishy window
		line(x0-1, y0+1, x0-1, y0+12, border_col)
		line(x1+1, y0+1, x1+1, y0+12, border_col)
	end


	-- shadow around the side: 2px left 3px down
	-- promising, but need to spend some reserved colours for a more gentle shadow
	-- and needs to support squishy windows, shaped windows (could be a feature of _blit_process_video)
	-- also: _blit_process_video needs to mask out stencil bits and/or observe 0x40 (e.g. for filenav item shadows)
	if (false) then

		poke(0x8000, unpack(dark_col)) -- to do: memmap a 4k block
		poke4(0x5508,0x7f7f7f7f)
		color(0)

		-- left
		rectfill(x0-2, y0+3, x0-2, y1+1)
		rectfill(x0-3, y0+4, x0-3, y1+1)

		-- bottom
		rectfill(x0-3, y1+2, x1-1, y1+2)
		rectfill(x0-2, y1+3, x1-2, y1+3)
		rectfill(x0-1, y1+4, x1-3, y1+4)

		-- L-shaped gap bottom left
		rectfill(x0-1,y1,x0-1,y1+1)
		rectfill(x0,y1+1,x0,y1+1)

		palt(0,true)
		poke4(0x5508,0x3f3f3f)
	end


end


function draw_window_paused_menu(win,sx,sy)
	
	if (not win.pmenu) return

	local ww,hh = 70, 12 + (#win.pmenu) * 6
	local winw = win.width / pixel_scale()
	local winh = win.height / pixel_scale()
	local x0,y0 = sx + winw/2 - ww, sy + winh/2 - hh
	local x1,y1 = x0 + ww*2 - 1, y0 + hh * 2 - 1

	rectfill(x0,y0,x1,y1,0)
	rect(x0+1,y0+1,x1-1,y1-1,7)


	for i=1,#win.pmenu do 
		local xx = x0 + 20
		local yy = y0 + 3 + i * 12
		local label = "??"

		if (type(win.pmenu[i].label) == "function") label = win.pmenu[i].label()
		if (type(win.pmenu[i].label) == "string")   label = win.pmenu[i].label
		print(label, xx, yy, 7)
		if (i == win.pmenu.ii) print("\^:0103070f07030100",xx-10,yy,7)
	end
end

function update_window_paused_menu(win)

	if (not win) return

	poke(0x3, win.paused and 1 or 0) -- for shell

	if (win.paused) then
		local buttons = btnp()
		if (win.pmenu) then

			if ((buttons & 0x73) > 0) then
				-- printh("selected pause menu item "..win.pmenu.ii)
				local item = win.pmenu[win.pmenu.ii]
				if (type(item.action) == "function") item.action(buttons)
			end

			if (btnp(2)) win.pmenu.ii -= 1
			if (btnp(3)) win.pmenu.ii += 1
			if (win.pmenu.ii < 1) win.pmenu.ii = #win.pmenu
			if (win.pmenu.ii > #win.pmenu) win.pmenu.ii = 1
		end

--	else
	elseif (win.pauseable) then -- 0.2.0h
		-- pause button to pause (not within first 0.5 seconds ~ could be left over button state used to launch the window or resume)
		if (btnp(6) and time() > win.created_t + 0.5 and (not win.resumed_t or time() > win.resumed_t + 0.5)) then
			win.paused = true
			generate_paused_menu(win)
			send_message(win.proc_id, {event = "pause"})
		end
	end

end

on_event("resume_pwc", function(msg)
	local win = get_window_by_proc_id(msg._from)
	if (not win) return	
	if (win.was_pauseable ~= nil) win.pauseable = win.was_pauseable -- restore pauseable state at time of last halt
	win.resumed_t = time()-- used to stop pause menu from immediately reopening
end)


on_event("toggle_pause_menu", function(msg)
	local win = get_active_window()
	if (not win or not win.pauseable) return -- e.g. can't pause desktop wallpaper from html shell
	if (win.paused) then
		win.paused = false
		send_message(win.proc_id, {event = "unpause"})
	else
		win.paused = true
		win.pmenu_mode = nil 
		generate_paused_menu(win)
		send_message(win.proc_id, {event = "pause"})
	end
end)

on_event("close_pause_menu", function(msg)
	local win = get_active_window()
	if (win.paused) then -- only happens for fullscreen apps
		win.paused = false
		win.pmenu_mode = nil 
		send_message(win.proc_id, {event = "unpause"})
		send_message(win.proc_id, {event = "update_menu_labels"}) -- might as well; sometimes labels change as a result of selected item
	end
end)

--[[
	fullscreen binary exports:
		- have an Exit option in pause menu that quits to Host OS
		- can not navigate away from the fullscreen workspace they are running in
		-> users who know how can't sneak into desktop and view source code etc

	// to disable this behaviour for exports, set the window's can_escape_fullscreen attribute:
	window{can_escape_fullscreen = true}

]]

function is_fullscreen_export(win)
	local win = win or get_active_window()
	if (not win) return false
	return win.fullscreen and win.player_cart and (stat(317)&0x3) == 0x3 and not win.can_escape_fullscreen
end

function is_locked_in_fullscreen()
	return is_fullscreen_export(get_active_window())
end



function generate_paused_menu(win)
	win.pmenu = {}

	_signal(23) -- block buttons

	if (win.pmenu_mode == "options") then

		add(win.pmenu,{
			label  = function(self) return (sdat.mute_audio and "Sound: Off" or "Sound: On") end,
			action = function(b) send_message(pid(), {event = "toggle_mute"}) end
		})

		add(win.pmenu,{
			label  = function(self) return (sdat.fullscreen and "Fullscreen: On" or "Fullscreen: Off") end,
			action = function(b)  
				sdat.fullscreen = not sdat.fullscreen
				store("/appdata/system/settings.pod", sdat)
			end
		})

		add(win.pmenu,{
			label = "Back",
			action = function() win.pmenu_mode = nil generate_paused_menu(win) end
		})

		win.pmenu.ii = 1

		return
	end


	-- let app know it should update menu items (the ones that are functions)
	-- to do: how to get results back in time to display menu? see last value for a moment
	send_message(win.proc_id, {event = "update_menu_labels"})

	add(win.pmenu, {label = "Continue", action = function() 
		win.paused = false
		send_message(win.proc_id, {event = "unpause"})
	end})

	-- insert userland menu items
	local menu = proc_menu[win.proc_id]

	if (menu) then
		for i=1,#menu do
			add(win.pmenu,
			{
				id = menu[i].id,
				label = menu[i].label or "??",
				action = function(b)
					send_message(win.proc_id, {event="menu_action", id=menu[i].id, b=b})
				end
			})
		end
	end


--[[
	add(win.pmenu, {
		label = function() return "Favourite "..(win.favourited and "\^:367f7f7f3e1c0800" or "\^:3649414122140800") end,
		action = function(b)
			win.favourited = not win.favourited -- to do: keep in sync with favourites.pod
		end 
	}) 
]]


	add(win.pmenu,{
			label = "Options",
			action = function() win.pmenu_mode = "options" generate_paused_menu(win) end
		})

	add(win.pmenu, {label = "Reset Cartridge", action = function() 

		if (haltable_proc_id == win.proc_id) then
			-- pwc: same as hitting ctrl-r (dupe)
			haltable_proc_id = create_process("/system/apps/terminal.lua",{
				corun_program = "/ram/cart/main.lua",       -- program to run // terminal.lua observes this and is also used to set pwd
				window_attribs = {
					pwc_output = true,                      -- replace existing pwc_output process			
					show_in_workspace = true,               -- immediately show running process
				}
			})
		else
			send_message(2, {event="restart_process", proc_id = win.proc_id})
			win.paused = false
			win.resetting = true -- don't kill process in win:update() while resetting
		end

	end})

	-- to do: can the process that launched a process have a say in its pause menu?
	-- add(win.pmenu, {label = "Exit to Splore", action = function() end})

	local has_exit = true -- normally there is "Exit" at end of pause menu, except..
	if (haltable_proc_id == win.proc_id) has_exit = false    -- running /ram/cart via ctrl+r; just press escape instead
	if (win.player_cart and stat(318) == 1) has_exit = false -- running entry point cart / bbs cart under web (nothing to exit to)
	
	if (has_exit) then
		add(win.pmenu, {label = "Exit Cartridge", action = function()
			if is_fullscreen_export(win) and stat(318) == 0 then
				-- 0.2.0b playing the entry point cart in a binary export -> quit to host OS (update: same as esc when autoclose=true)
				send_message(2, {event="shutdown"})
			elseif (haltable_proc_id == win.proc_id) then
				-- halt program and enable command prompt
				win.paused = false
				send_message(win.proc_id, {event = "unpause"})
				send_message(haltable_proc_id, {event="halt"})
				haltable_proc_id = false
			else
				if (win.fullscreen) then
					close_workspace(workspace_index) -- fullscreen: assume running as sole child in a workspace created for that purpose
					set_workspace(previous_workspace)
				else
					close_window(win, true) -- windowed programs can be pauseable too, but is not on by default
				end
			end
		end})
	end

	-- always start at Continue
	win.pmenu.ii = 1

	
	
end

	

-- doesn't kill process -- that's up to process manager
-- update: seems almost always want to kill at the same time; added as a parameter
function close_window(win, do_kill)
	
	_kill_process(do_kill and win and win.proc_id)

	win = win or get_active_window() -- is the get_active_window default ever used? to do: review and remove

	if (win.closing) then return end -- already started the closing process. don't want to send messages twice

	-- invalidate active window
	if (win.parent.active_window == win) win.parent.active_window = nil

	-- headless process should not be hogging cpu / calling _draw
	send_message(win.proc_id, {event="lost_visibility"})

	-- send message to self to close after end of frame
	-- (otherwise can invalidate an iterator somewhere?)

	send_message(pid(), {event="close_window",proc_id = win.proc_id})
	win.closing = true

end

function close_window_with_confirmation(win, do_kill)

	local found_unsaved_changes

	if win.location and string.sub(win.location, 1, 10) ~= "/ram/cart/" then

		if (win.unsaved_changes) then
			create_process("/system/misc/confirm.p64", 
			{prompt = "Discard Unsaved Changes?", title = "Close", window_attribs = {workspace="current", autoclose=true}, proc_id = win.proc_id})
			return
		end

	else
		-- ram/cart/* autosaves when closed
		if (win.unsaved_changes) then
			send_message(win.proc_id, {event="save_file", autosave = true})
			send_message(win.proc_id, {event="exit"}) -- will be processed after save_file
			return
		end
	end

	-- go ahead
	return close_window(win, do_kill)
	
end


function generate_windat()

	local windat = {
		--{x=0,y=infobar_y,width=480,height=270-infobar_y} -- first entry is always infobar
	}

	for i=1,#ws_gui.child do
		local w2 = ws_gui.child[i]
		-- only windows that have a frame and are solid
		-- later: could send a low-res 160x90 mask including non-rectangular windows
		-- minimal information: non-sandboxed programs can use the proc_id to look up more info 
		if (w2.has_frame and _ppeek(w2.proc_id, 0x547d) == 0 and w2 ~= win) then
			add(windat, {
				x = w2.x, y = w2.y - bar_h,
				width = w2.width, height = w2.height + bar_h,
				proc_id = w2.proc_id
			})
		end
	end

	return windat
end


function set_active_window(win)

	if (not win) return

	-- bring to front of same-z group
	win:bring_to_front()

	-- set active window for that sub-gui
	win.parent.active_window = win

	-- give focus to / take focus from tooltray
	tooltray_active_window = (win.parent == tooltray_gui) and win or nil
end


function install_widget(win)

	if (win.prog:sub(1,9) == "/ram/cart" and (win.prog[10] == "/" or win.prog[10] == nil)) then
		notify("installed "..win.prog.." as a temporary widget")
		return
	end

--	printh(pod{win.prog, win.location})

	local widgets = fetch("/appdata/system/widgets.pod") or {}
	add(widgets,{
		x = win.x,
		y = max(win.y, 0),
		width = win.resizeable and win.width or nil,
		height = win.resizeable and win.height or nil,
		location = win.location,
		prog = win.prog,
		had_frame = win.had_frame
	})
	store("/appdata/system/widgets.pod", widgets)
	notify("installed widget: "..win.prog)
end

function update_widget_position(win)

	local widgets = fetch("/appdata/system/widgets.pod") or {}

	local found_widget_to_update

	for i=1,#widgets do
		local wid = widgets[i]
		-- identify by position and prog
		-- always happen after a grab and drag (so start_grab_x/y is set)
		if (wid.x\1 == win.start_grab_x and wid.y\1 == win.start_grab_y and wid.prog == win.prog) 
		then
			found_widget_to_update = true
			wid.x = win.x\1
			wid.y = win.y\1
		end
	end

	if (found_widget_to_update) then
		store("/appdata/system/widgets.pod", widgets)
		--notify("updated widget: "..win.prog)
	end
end


function uninstall_widget(win)
	local widgets = fetch("/appdata/system/widgets.pod") or {}

	local widget_to_delete
	for i=1,#widgets do
		local widget = widgets[i]
		-- identify by (old or grabbed) position and program
		if (widget.x\1 == win.x\1 or widget.x\1 == win.start_grab_x) and (widget.y\1 == win.y\1 or widget.y\1 == win.start_grab_y) and widget.prog == win.prog 
		then
			widget_to_delete = widget		
		end
	end

	if (widget_to_delete) then
		del(widgets, widget_to_delete)
		store("/appdata/system/widgets.pod", widgets)
		notify("uninstalled widget: "..win.prog)
		return widget_to_delete.width
	else
		notify("** could not uninstall widget: "..win.prog)
	end

end

function pop_out_widget(win, new_x, new_y)
	local size_was_set = uninstall_widget(win)
	-- move window to desktop
	win:detach()
	ws_gui:attach(win)
	win.x = new_x
	win.y = max(new_y, 12) -- can't drop on toolbar
	-- give frame -- to do: store original setting
	if (win.had_frame) then
		win.has_frame = true
		win.moveable = true    -- a fair assumption if it was installed in the first place
		if (size_was_set) win.resizeable = true  -- if there was a width set on widgets.pod item, must be resizeable (usually the case)
		create_window_frame(win)
	end
end


local function drag_window(win)

	local mx, my = mouse()
	local x0, y0 = win.sx, win.sy
	local x1 = mx - dragging_window_xo
	local y1 = my - dragging_window_yo
	local min_y1 = win.has_frame and 24 or 12
	if (win.parent == tooltray_gui) min_y1 = 0
	y1 = max(min_y1, y1)

	-- let application know; app can also send message requesting move
	send_message(win.proc_id, {event="move", x = x1, y = y1, dx = x1 - x0, dy = y1 - y0})

	-- this section is needed to keep display size in sync with window size when it is squashed
	-- tricky because gui element changes size too late for display size to change before draw
	--> detect if it is /going/ to be changed, and defer window position change to next frame
	--  via a drag_squashable_window message
	local squashed_display_changed_size = false -- or unsquashed; changed size due to squashing
	if (win.squashable) then
		local pwidth, pheight = _get_process_display_size(win.proc_id)
		-- predict new squashed width this frame -- logic needs to match gui.lua (!)
		local ww = min(win.width0, (x1 + win.width0) - 0)
		ww = max(win.min_width, min(ww, ws_gui.width - x1))
		local hh = min(win.height0, (y1 + win.height0) - 0)
		hh = max(win.min_height, min(hh, ws_gui.height - y1))
		if (ww ~= pwidth or hh ~= pheight) then
			send_message(win.proc_id, {event="squash", width = ww, height = hh})
			squashed_display_changed_size = true
		end
	end

	if (squashed_display_changed_size) then
		-- move next frame (otherwise display size is a frame behind)
		send_message(3, {event="drag_squashable_window", x = x1, y = y1, proc_id = win.proc_id})
	else
		-- can move same frame
		win.x = x1
		win.y = y1
	end
end

function drop_window(win)
	-- drop into tooltray

	local mx,my = mouse()

	if (my < toolbar_y) 
	then
		if (win.parent == tooltray_gui) then
			-- already in tooltray: store position (e.g. can drag owl around)
			-- printh("moved within tooltray")
			if (win.start_grab_x) then
				local dx,dy = win.x - win.start_grab_x,  win.y - win.start_grab_y
				if (dx*dx+dy*dy>=3*3 or time() > win.start_grab_t + 0.7) then
					update_widget_position(win)
				else
					-- snap back when move less than 3 pixels and dragged for less than 0.7 seconds (might be intended to be a click / tap)
					win.x = win.start_grab_x
					win.y = win.start_grab_y
				end
			end
		else
			-- printh("dropped into tooltray: "..my)
			win:detach()				
			win.x = mx - dragging_window_xo
			win.y = my - dragging_window_yo + toolbar_y - (win.has_frame and 12 or 0)
			win.y = max(0, win.y) -- never off the top

			-- remove frame if there is one
			win.had_frame = win.has_frame and true or nil -- remember for when popping out
			win.has_frame = false
			win.child={}
			tooltray_gui:attach(win)

			-- remove squashy attributes (interesting, but maybe later)
			update_squashable_attributes(win)
			
			-- install in /system/appdata/widgets.pod
			install_widget(win)
		end
	elseif (win.parent == tooltray_gui) then
		pop_out_widget(win, mx - dragging_window_xo, my - dragging_window_yo - toolbar_y)
		
	end

end


function create_window_frame(win)

	local bar = win:attach(
		{
			x = 0, y = -bar_h,
			width_rel = 1.0,
			height = bar_h,
			clip_to_parent = false,
			cursor = "grab", -- to do: why doesn't this work? because outside of parent?
			is_window_bar = true
		}
	)

	-- close button
	bar:attach(
		{
			cursor = "pointer",
			x = -2, justify="right",
			y = 0, vjustify="center",
			width = 12, height = 12,
			tap = function(self)
				close_window_with_confirmation(self.parent.parent, true)
			end,
			draw = function(self, msg)
				(msg.has_pointer and circfill or circ)(self.width / 2, self.height / 2 - 1, 2, 
					win.parent.active_window == win and theme("window_button") or theme("dormant_button")) 					
			end,
			update = function(self)
				-- make space for tiny window
				if(self.width < 32) self.x = 0
			end
		}
	)

	-- app menu button
	bar:attach(make_window_button(bar, "app menu", 4, 1, 12, 10 +1)) -- height +1 so that window frame border is not clobbered

	function bar:update(event)
		self.col_k = win.parent.active_window == win and "window_button" or "dormant_button"
	end

	-- to do: keep offset; when go up into tooltray area and back down, relative grab position should stay the same
	function bar:drag(event)
		if (not win.moveable) return
		drag_window(win)
	end

	function bar:release(msg)
		--printh("dropped: "..pod(msg))
		dragging_window = false
		drop_window(win)
	end

	function bar:click(msg)
		if (not key("lshift")) then -- key state test, but actually quite useful! drag windows around underneath
			bar.parent:bring_to_front()
		end
		win.parent.active_window = win -- either way: this window becomes the active window

		if (not win.fullscreen) then
			dragging_window = win
			local mx, my = mouse()
			dragging_window_xo = mx - win.x
			dragging_window_yo = my - win.y
		end
	end

	function bar:doubletap()
		-- maximise
--			win.x = 0
--			win.y = 12

		if (not win.resizeable) return

		if (win.maximised) then
			win.maximised = false
			send_message(win.proc_id, {event="resize", x = win.old_x, y = win.old_y, width = win.old_width, height = win.old_height})
		else
			win.maximised = true
			win.old_x = win.x
			win.old_y = win.y
			win.old_width = win.width
			win.old_height = win.height
			-- space to see frame
			send_message(win.proc_id, {event="resize", x = 1, y = 24, width = 478, height = 245})
		end

	end



	--[[--------------------------------------------------------------------------------------------------------------

		resize widget

		// always attach if not resizeable; window attribute can change after creation

		to do: could be a single large rectangle behind window
		(so only works when cursor is slightly outside of window)
		or -- put in front and use test_point (ha!)
	
	--------------------------------------------------------------------------------------------------------------]]--

	local function resize_click(self, event) 

		-- burn in evaluated size and position (for squashable windows)
		win.x = win.sx - win.parent.sx
		win.y = win.sy - win.parent.sy
		win.width0 = win.width
		win.height0 = win.height

		-- resize modifications relative to a starting position and size
		win.start_mx, win.start_my = mx, my
		win.start_w, win.start_h = win.width, win.height
		win.start_x, win.start_y = win.x, win.y

	end

	function resize_draw(self, event) 
		-- debug: view the widget // don't need to clip() because .clip_to_parent == false
		-- rect(0, 0, self.width-1, self.height-1, 5)
	end

	-- resize bottom right
	if (win.resizeable) then

		win:attach({
			width = 8, height = 8,
			clip_to_parent = false,
			cursor  = 8,

			update = function(self)
				self.x = win.width - 4
				self.y = win.height - 4
			end,
			draw  = resize_draw,
			click = resize_click,
			drag = function(self, event)
				if (win.resizeable and (event.dx ~= 0 or event.dy ~= 0)) then
					-- use window manager mx, my because using relative event.mx,event.my will jump around as window resizes
				
					local new_width  = max(win.min_width, win.start_w + (mx - win.start_mx))
					local new_height = max(win.min_height, win.start_h + (my - win.start_my))
					send_message(win.proc_id, {event="resize", width = new_width, height = new_height})
			
				end
			end
		})

		-- resize bottom left
		win:attach({
			width = 8, height = 8,
			clip_to_parent = false,
			cursor  = 9,

			update = function(self)
				self.x = -4
				self.y = win.height - 4
			end,
			draw  = resize_draw,
			click = resize_click,

			drag = function(self, event) 
				if (win.resizeable and (event.dx ~= 0 or event.dy ~= 0)) then
					-- set x in same message so that visible change is simultaneously (otherwise jitters)
					local new_width  = max(64, win.start_w\1 - (mx - win.start_mx))
					local new_height = max(32, win.start_h + (my - win.start_my))
					send_message(win.proc_id, {event="resize", width = new_width, height = new_height, x = win.start_x + (mx - win.start_mx)
				})

				end
			end
		})
	end
--[[
	-- commented; maybe nice to have just bottom left, bottom right widgets.

	-- resize bottom
	win:attach({
		x = 4, 
		y = win.height - 4,
		width = win.width - 8,
		height = 8,
		clip_to_parent = false,
		update = function(self)
			self.y = win.height - 4
			self.width = win.width - 8
		end,
		draw  = resize_draw,
		click = resize_click,
		drag = function(self, event) 
			if (event.dx ~= 0 or event.dy ~= 0) then
				send_message(win.proc_id, {event="resize", height = win.start_h + (my - win.start_my)})
			end
		end
	})

	-- resize left
	win:attach({
		x = -4, y = 0, 
		width = 8, height = win.height  - 4,
		clip_to_parent = false,
		update = function(self)
			self.height = win.height  - 4
		end,
		draw  = resize_draw,
		click = resize_click,
		drag = function(self, event) 
			if (event.dx ~= 0 or event.dy ~= 0) then
				send_message(win.proc_id, {event="resize", 
					width = win.start_w\1 - (mx - win.start_mx)\1, 
					x = win.start_x + (mx - win.start_mx)
				})
			end
		end
	})

	-- resize right
	win:attach({
		x = win.width-4, y = 0, 
		width = 8, height = win.height  - 4,
		clip_to_parent = false,
		update = function(self)
			self.height = win.height  - 4
			self.x = win.width-4
		end,
		draw  = resize_draw,
		click = resize_click,
		drag = function(self, event) 
			if (event.dx ~= 0 or event.dy ~= 0) then
				send_message(win.proc_id, {event="resize", 
					width = win.start_w\1 + (mx - win.start_mx)\1, 
				})
			end
		end
	})
]]



end

-- wm bundles gui attributes together as "squashable"
-- --> means display is squashable and squash/confine_to_* attributes are set accordingly
-- to do: could use *_to_crop for tabs
function update_squashable_attributes(win)

	local was_squashy = win.squash_to_parent or win.confine_to_parent or win.squash_to_clip or win.confine_to_clip

	win.squash_to_parent  = nil
	win.confine_to_parent = nil
	win.squash_to_clip    = nil
	win.confine_to_clip   = nil

	if (win.squashable and win.has_frame) then
		-- use *_to_parent -- to_clip is too messy
		win.squash_to_parent  = true
		win.confine_to_parent = true
		if not was_squashy then
			-- going from not squishy -> squishy: set base size (safety)
			win.width0 = win.width
			win.height0 = win.height
		end
	elseif was_squashy then
		-- going from squishy -> regular; set window position and size to match evaluated region
		win.x = win.sx - win.parent.sx
		win.y = win.sy - win.parent.sy
		win.width0 = win.width
		win.height0 = win.height
	end

end


-- new version
function create_window(target_ws, attribs)

	local win = nil

--	printh("creating window: "..pod{attribs})

	add(boot_messages, attribs.prog)

	attribs = attribs or {}

	if (not attribs.width or not attribs.height or attribs.fullscreen) then
		attribs.width = 480
		attribs.height = 270
		attribs.x = 0
		attribs.y = 0
		attribs.fullscreen = true
	end

	attribs.x = attribs.x or (attribs.tabbed and 0  or rnd(480 - attribs.width)\1)
	attribs.y = attribs.y or (attribs.tabbed and 11 or (30 + rnd(230 - attribs.height)\1))


	-- default attributes

	if (attribs.has_frame  == nil)   attribs.has_frame  = false
	if (attribs.moveable   == nil)   attribs.moveable   = true
	if (attribs.resizeable == nil)   attribs.resizeable = true
	if (attribs.fullscreen       )   attribs.width, attribs.height, attribs.x, attribs.y = 480, 270, 0, 0
	if (attribs.maximised        )   attribs.width, attribs.height, attribs.x, attribs.y = 480, 248, 0, 11

	if (attribs.pauseable == nil) attribs.pauseable = attribs.fullscreen and not attribs.desktop_filenav and not attribs.wallpaper

	if (attribs.min_width == nil) attribs.min_width = 40
	if (attribs.min_height == nil) attribs.min_height = 20

	-- squashable
	update_squashable_attributes(attribs)

	win = target_ws:attach(attribs)

	-- finished recovering output terminal by creating this window
	target_ws.recovering = false
	
	
	-- position at top of same-z stack
	win:push_to_back()    -- bottom of same-z stack (push behind any foreground layers)
	win:bring_to_front()  -- bring back up to front of same-z stack

	win.send_mouse_update = true -- send mouse message on first frame
	win.created_t = time()

	win.test_point = function(self, x, y)
		-- process is using transparency on display bitmap?
		local alphabits = _ppeek(win.proc_id, 0x547e) -- INTERACT_ALPHABITS_ADDR
		if (not alphabits or alphabits == 0) return true

		if (win.interactive == false) return false -- e.g. cursor charms should never block mouse click

		-- look up the pixel
		local disp_width = _ppeek(win.proc_id, 0x5478) + (_ppeek(win.proc_id, 0x5479) << 8)
		local val = _ppeek(win.proc_id, 0x10000 + (y * disp_width) + x)

		-- considered solid when at least one of the alpha bits is set in this pixel
		return (val & alphabits ~= 0)
	end

	
	function win:draw()

		-- not visible or about to close --> skip
		if (not win.visible or win.closing) return true -- don't draw children

		--if (win.closing) return

		-- don't render on first visible frame as process :draw has likely not been called
		-- without this, get flickering when switching tabs
		-- update: this mechanism seems redundant if entire wm skipping a frame when chaning window focus (see last_draw_window)
			-- but actually prevents a different type of flicker -- e.g. switching from gfx to map editor at start.
			-- to do: investigate why; just a result of 2 frames instead of 1? need to formalise wm guarantees

		-- commented: should be doing this at the workspace level anyway; 
		-- consider stacked tabs that are drawn except for the top one on the first frame after changing workspace

		--[[
		if (not win.process_had_a_chance_to_draw) then
			win.process_had_a_chance_to_draw = true
			return
		end
		]]

		local blit_result = false
		
		if sdat.squishy_windows and win.has_frame and get_active_window() == win then

			local border_col = theme(get_active_window() == win and "window_border" or "dormant_border")

			clip()
			if (not win.sxa) win.sxa = {}
			if (not win.sya) win.sya = {}
			win.sxa[0] = win.sx + 0.5
			win.sya[0] = win.sy + 0.5

			while (#win.sxa < win.height) add(win.sxa, win.sxa[#win.sxa])
			while (#win.sya < win.height) add(win.sya, win.sya[#win.sya] + 1)
			
			for yy = 1, #win.sxa do
				win.sxa[yy] = win.sxa[yy] * 0.03 + win.sxa[yy-1] * 0.97
				win.sya[yy] = win.sya[yy] * 0.03 + (win.sya[yy-1] + 1) * 0.97
				if (abs(win.sya[yy] - (win.sya[yy-1] + 1)) < 0.05) win.sya[yy] = win.sya[yy-1] + 1.0
			end

			camera()
			local yy1 = win.sya[0]
			for yy = 0, win.height-2 do
				local ht = (win.sya[yy+1] - win.sya[yy])\1 -- draw > 1px high when stretched out

				while (yy1 <= win.sya[yy]) do
					blit_result = _blit_process_video(win.proc_id, 0, yy, nil, max(1,ht), win.sxa[yy], yy1)

					if (blit_result) then
						blit(prev_frame, nil, win.sxa[yy], yy1, win.sxa[yy], yy1, win.width, max(1,ht))
					end

					pset(win.sxa[yy] - 1, yy1, border_col)
					pset(win.sxa[yy] + win.width, yy1, border_col)
					yy1 += 1
				end
			end

			-- dupe on last line for efficiency -- sides are one pixel in
			local ht = 1
			local yy = win.height-1
			local ht = (win.sya[yy+1] - win.sya[yy])\1 -- draw > 1px high when stretched out
			while (yy1 <= win.sya[yy]) do
				blit_result = _blit_process_video(win.proc_id, 0, yy, nil, max(1,ht), win.sxa[yy], yy1)
				if (blit_result) then
					blit(prev_frame, nil, win.sxa[yy], yy1, win.sxa[yy], yy1, win.width, max(1,ht))
				end
				pset(win.sxa[yy], yy1, border_col)
				pset(win.sxa[yy] + win.width - 1, yy1, border_col)
				yy1 += 1
			end

			-- bottom line (two pixels in)
			local yy = win.height-1
			line(win.sxa[yy] + 1, yy1, win.sxa[yy] + win.width - 2, yy1, border_col)

		else
			-- regular rectangular blit

			blit_result = _blit_process_video(win.proc_id, 0, 0, nil, nil, win.sx, win.sy)

			-- clear squishy positions

			win.sxa = nil
			win.sya = nil

			-- could not blit (_draw didn't complete?) 
			--> blit from desktop copy instead (when not fullscreen -- fullscreen can just do nothing!)
			-- non-rectangular windows (w/ PROCBLIT_TRANSP_ADDR set) should make sure  [update: ... make sure what?]
			if (blit_result and not win.fullscreen) then
				blit(prev_frame, nil, win.sx, win.sy, win.sx, win.sy, win.width, win.height)
				--clip() circfill(0,0,16,8) circfill(0,0,24,7) -- debug: show that (desktop) window is frame-skipping	
			end

		end
		


		-- debug: show window size
--		local ww,hh = _get_process_display_size(win.proc_id)
--		print(pod{win.width, win.height, ww, hh}, 5,15,8+rnd(16))

		-- always draw frame for now (lazy)  // to do: check visibility
		if (win.has_frame) then
			clip()
			draw_window_frame(win)
		end

		-- paused menu

		if (win.paused) then
			draw_window_paused_menu(win, win.sx, win.sy)
		end

		-- stickers  //  deleteme -- stickers now regular children
		--[[
		if (type(win.stickers) == "table") then
			clip() camera()
			for i=1,#win.stickers do
				local s = win.stickers[i]
				if (type(s) == "table" and type(s.bmp) == "userdata" and s.x and s.y) then
					local ww, hh = s.bmp:attribs()
					if (s.x >= 0 and s.y >= -12 and s.x < win.width and s.y < win.height) then
						spr(s.bmp, win.sx + s.x - ww\2, win.sy + s.y - hh\2)
					else
						-- to do: fall off? sparkle puff?
						del(win.stickers, s)
					end
				end
			end
		end
		]]
		
	end


	function win:update()

		win.is_active = self == get_active_window()

		-- no process --> close 
		-- except when in the middle of resetting cartridge: there might be a few frames where process has no display
		if _process_state(win.proc_id) < 0 and not win.resetting then
			--printh("closing dead process. "..tostring(win.closing))
			close_window(win)
			return
		end

		-- autoclose a non-tabbed window that is covered by a tabbed window
		-- otherwise: need some way to access that window. don't want to tab it! sheesh

		if (win.autoclose or win.empty_workspace_file_chooser) and
			win.parent.child[#win.parent.child].tabbed and
			not win.tabbed and            -- also means that this window isn't the window on top, which is tabbed
			time() > win.created_t + 0.5  -- don't close in the first half a second (give a chance to get focus)
		then
			close_window(win, true)
			return
		end

		-- tabbed: adapt position and size to useable desktop space

		if (win.tabbed) then

			-- slide with toolbar (means change height every frame when transitioning)
			win.y = min(0, toolbar_gui.sy) + toolbar_gui.height
			win.sy = win.y

			if (win.height ~= 270 - win.y) then
				win.height = 270 - win.y
				send_message(win.proc_id, {event="resize", width = win.width, height = 270 - win.y})
			end
		end

		-- 
		update_squashable_attributes(win)

		-- squashable display: keep display size in sync with width, height (instead of width0, height0)
		-- bar:drag handles the common case and ensures elements size matches draw size (drag_squashable_window)
		-- but this is needed for other cases where window is squashed (e.g. app requests position change)
		if (win.squashable) then
			local pwidth, pheight = _get_process_display_size(win.proc_id)
			if (pwidth and pwidth ~= win.width) or (pheight and pheight ~= win.height) then
				-- printh("squash from win:update(): "..pod{pwidth, win.width, win.width, win.height})
				send_message(win.proc_id, {event="squash", 
					width = win.width, 
					height = win.height, 
					x = win.x, y = win.y})
			end
		end

	end

	

	function win:click(msg)

		set_active_window(win)

		-- forward click to window 
		-- to do: review if window be getting gui messages like this? i.e. can use from on_event()
		-- (if so, need to also send tap / doubletap etc. a bit of extra code but not a perf question)
		-- maybe app should always set up a gui; seems nicer to have one consistent way of doing it
		-- BUT -- maybe kinda surprising can't do on_event("click", ...)
		-- send_message(win.proc_id, msg)

		return true -- processed
	end

	function win:tap(msg)

		-- context menu on mb2 (used by filenav -- need to provide nicer mechanism for generating that menu)
		-- inside tap message so that filenav has chance to generate menu based on new selection
		if (win.has_context_menu or win.parent == tooltray_gui) and msg.last_mb == 2
		then
			send_message(3, {event = "toggle_app_menu", 
				_delay = 0.0 , is_context_menu = true, 
				x = win.sx + msg.mx - 70, 
				y = min(win.sy + msg.my - 30, 150), -- keep y above 150 (assume menu is shorter) // to do: maybe need a keep_inside_parent attribute
				proc_id = win.proc_id }
			)
		else
			-- forward tap to window  -- deleteme; apps should set up a gui instead
			-- send_message(win.proc_id, msg)
		end

	end

	-- can move window around by grabbing interior if app sends a "grab" message
	function win:drag(msg)
		if (dragging_window == win) drag_window(win)
	end
	function win:release(msg)
		if (dragging_window == win) then
			drop_window(win)
		end
		dragging_window = nil		
	end


	-- titlebar

	if (win.has_frame) then
		create_window_frame(win)
	end
		

	-- creating a desktop wallpaper --> automatically create a filenav overlay

	if win.wallpaper and target_ws and (win.workspace == "new" or win.workspace == "tooltray") then

		local filenav_workspace = win.workspace == "tooltray" and "tooltray" or target_ws.id

		target_ws.desktop_filenav_proc_id = 
		create_process("/system/apps/filenav.p64",{
			 -- window attribs of the desktop program launching the desktop filenav
			argv = {"-desktop", win.desktop_path or "/desktop"},
			window_attribs = {
				workspace = filenav_workspace, -- same workspace as the wallpaper
				show_in_workspace = false, -- don't become active
				width = win.width, height = win.height,
				x = win.x, y = win.y, z = win.z + 1, -- desktop is -1000 (head.lua)
				has_frame = false,
				moveable = false,
				resizeable = false,
				desktop_filenav = true
			}
		})
	end

	
	return win	
end

function pixel_scale()
	local video_mode = @0x547c
	if (video_mode == 3) return 2
	if (video_mode == 4) return 3
	return 1
end


--[[
	mouse_scaled()
	takes video mode into account
	to do: lower level
]]
function mouse_scaled()

	local x,y,b,dx,dy = mouse()

	x \= pixel_scale()
	y \= pixel_scale()

	return x,y,b,dx,dy
end

local last_draw_t = 0
local smoothed_fps = 0
local show_fps = false
local last_drawn_ws = nil
local ws_gui_frames = 0

local inited_font = false

boot_messages = {}


local xodat = {26,22,19,17,15,14,12,11,10,9,8,7,6,5,5,4,3,3,2,2,1,1,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,2,2,3,3,4,5,5,6,7,8,9,10,11,12,14,15,17,19,22,26}

function polaroid(x0,y0,x1,y1,q0,q1)
	rectfill(x0-4,y0-4,x1+4,y0-1,7)
	rectfill(x0-4,y0,x0-1,y1,7)
	rectfill(x1+1,y0,x1+4,y1,7)
	rectfill(x0-4,y1+1,x1+4,y1+15,7)
	rect(x0-5,y0-5,x1+5,y1+16,1)
	rect(x0-1,y0-1,x1+1,y1+1,1)
	
	rectfill(x0-1,y1+3,x1+1,y1+4,6)
	
	rectfill(x0-1,y1+3,x0+(x1-x0+1)*mid(0,q0/max(1,q1),1),y1+4,13)
	
	if (x1-x0 > 34) then
		print("\014frame "..flr(q0),x0+1,y1+8,13)
	end
	if (x1-x0 > 80) then
		print("\014\^ifin:\^-i ctrl-9",x1-42,y1+8,13)
	end
end

function _draw()



	pal(0) -- reset colourtable but leave rgb display palette alone

	-- don't draw frame when changing window or workspace; allows messages to complete and prevents flicker
	-- (e.g. switch through newly opened tabs, or gfx setting current sprite picked up by map editor)
	if (last_draw_window ~= get_active_window()) then
		last_draw_window = get_active_window()
		return
	end

	-- also skip first frame when changing workspace
	-- to do: unnecessary? prevents gfx->map flicker, but maybe just because skipping 2 frames instead of 1
	-- also: causes no visible refresh when holding alt-right/left (only see where workspace index ended up on release) -> why?
	if (last_drawn_ws ~= ws_gui) then last_drawn_ws = ws_gui return end


	-- sanity
	if (ws_gui) then
		if (ws_gui.width < 480) printh("*** ws_gui.width: "..ws_gui.width)
		if (ws_gui.height < 240) printh("*** ws_gui.height: "..ws_gui.height)
	end

	--[[
		wm should never hold frames (or need to)
		if becomes relevant, then is a bug and is extremely hard to see what's going on with wm holding frames
		e.g. if 30fps app is showing frames every second frame, the ones wm is holding --> appears frozen
		better to just let the wm interface start flickering
		0.1.0h: commented. too many moments that genuinely need to be hidden for a frame! 
		e.g. click between channels in pattern editor -> causes cpu debt that wm can't easily avoid being starved from 	
		--> uncomment while debugging wm refresh issues
	]]
	-- poke(0x547f, peek(0x547f) & ~0x2) -- unset hold_frame bit

	
	-- workspace doesn't have a fullscreen window covering it
	-- e.g. launch filenav when there is no desktop workspace, or running web cart player
	-- ** important not to clear each frame for fullscreen apps -- otherwise get flashing when < 60fps
	-- ** note: can be fullscreen but still width < 480 (because videomode) 
	if (ws_gui and (ws_gui.clear_each_frame or (ws_gui.child[1] and ws_gui.child[1].width < 480 and not ws_gui.child[1].fullscreen))) then
		rectfill(0,0,479, 269, 0x10)
		-- rectfill(0,0,479,10,7) -- toolbar-ish shape for cart player (deleteme -- no longer needed)
--		print("\128 empty workspace // \f6please choose a file", 40, 40 + ws_gui.sy, 7) -- deleteme; just use new tab button
	end

	-- cls(10) -- debug

	local awin = get_active_window()


	if (not ws_gui or #workspace == 0) then
		cls()
		if (time() > 3) print("[no workspaces found] "..#workspace,20,20,13)
		if (#workspace > 0) set_workspace(1)
		return
	end


	if (screensaver_proc_id) then
		local win = get_window_by_proc_id(screensaver_proc_id)
		if (win) win:draw()
	else
		head_gui:draw_all()
	end

	camera()
	clip()


	-- debug: measure _update cost
--	rectfill(30,240,200,246,1) print(string.format("\014cpu: %02d mem: %04dk", stat(1)\0.01, stat(0)\1024), 30,241,7)


	-- keep a copy of window output
	-- cheap, general way to do frame holding. should cost ~2% cpu. just a 128k memcpy!
	-- can optimise later for full-screen programs that don't need cursor (just skip drawing anything)

	if (not awin or not awin.fullscreen) 
	then
		blit(nil, prev_frame)
		--prev_frame:copy(8)
	end


	-- toolbar
	if (do_draw_toolbar) then

		-- toolbar shadow
		-- doesn't work! on top of window. need stencil bit for window frame!
		-- but doesn't work visually anyway
		-- rectfill_shadow(0,ws_gui.y + 11, 480, ws_gui.y + 12) 


--		draw_toolbar()

--		line(0,11,479,11,32) -- too much

--		printh(pod(ws_gui))
--		draw_infobar()
		
	end

	-- sparkles (under mouse cursor)

	if (sdat.sparkles) draw_sparkles()


	-- draw cursor
	-- mouse cursor is visible by default
	-- use hide_cursor() to hide it

	local show_cursor = not screensaver_proc_id

	mx, my, mb = mouse_scaled()
	if (mx >= 479 and my >= 269) show_cursor = false -- can hide cursor at bottom right

	if (show_cursor) then
		
		-- show default cursor when active window doesn't have one, and not holding alt

		local gfx = cursor_gfx[1].bmp or default_cursor_gfx

--		if (head_gui.mouse_cursor_gfx) gfx = head_gui.mouse_cursor_gfx 
		
		if (awin and awin.cursor and not key("alt")) then
			-- 0.2.0e only use window cursor gfx when pointer is inside
			if (mx >= 0 and my >= 0 and mx < awin.width and my < awin.height) then
				gfx = awin.cursor
			end
		end

		if (head_gui.mouse_cursor_gfx) gfx = head_gui.mouse_cursor_gfx -- override with wm cursor (resize window)

		if (gfx == "crosshair") gfx = 2
		if (gfx == "grab") gfx = mb == 0 and 3 or 4
		if (gfx == "pointer") gfx = mb == 0 and 5 or 6
		if (gfx == "dial") gfx = mb == 0 and 7 or 0
		if (gfx == "edit") gfx = 12


		if (type(gfx) == "number") gfx = cursor_gfx[flr(gfx)].bmp
		if (type(gfx) != "userdata") gfx = default_cursor_gfx

		
		

		if (dragging_items) then

			-- dragging: override cursor gfx
			gfx = cursor_gfx[4].bmp

			-- follow: mouse
			local fx = mx - 8
			local fy = my - 8

			for i=1,#dragging_items do
				local item = dragging_items[i]
				if (not item.xo) item.xo = item.x - mx
				if (not item.yo) item.yo = item.y - my
			end

			local hover_win = head_gui:el_at_xy(mx, my)
			local keep_original_positions = not hover_win or hover_win.desktop_filenav
			for i=1,#dragging_items do
				
				local item = dragging_items[i]

				local dx,dy = fx - item.x, fy - item.y
				local aa = atan2(dx, dy)
				local tx,ty

				if (keep_original_positions) then
					tx,ty = mx + item.xo, my + item.yo
				else
					tx,ty = fx - cos(aa)*2, fy - sin(aa)*2
				end

				if (#dragging_items > 10) then
					-- catch up faster
					item.x = (item.x*2 + tx) / 3
					item.y = (item.y*2 + ty) / 3
				else
					item.x = (item.x*3 + tx) / 4
					item.y = (item.y*3 + ty) / 4
				end
	
				if (i==1) item.x, item.y = tx,ty

				-- follow: the item in front
				fx = item.x
				fy = item.y
				
			end

			-- draw with item closest to cursor on top
			for i=#dragging_items,1,-1 do
				local item = dragging_items[i]
				spr(item.icon, item.x, item.y)
			end

		end

		last_mx9, last_my9 = mx, my

		-- 
		local gfx_w, gfx_h = gfx:attribs()
		spr(gfx, mx - (gfx_w+1)\2, my - (gfx_h+1)\2)  -- +1 so exactly at center for odd-sizes bitmaps. ref: paint bucket
	end

	
	-- fps

	if (show_fps) then
		-- has no effect if 0 is transparent! need to be able to turn blending on / off.
		-- gives programmer option of faster code path too
		rectfill(450,259,479,469,32) 
		local fps_target = (1/(time() - last_draw_t))
		smoothed_fps = (smoothed_fps * 31 + fps_target * 1) / 32
		local num_str = (smoothed_fps + 0.5) // 1
		print(tostr(num_str), 452, 261, 7)
		last_draw_t = time()
	end

	-- grab palette and video mode from active window's process (if there is one)

	if (awin) then

		-- 0.1.0c: only update when frame is not held (avoid flashing when running < 60fps)
		local val = _ppeek(awin.proc_id, 0x547f) -- might be nil if process recently ended
		if (val and val & 0x2 == 0)
		then
			--printh("@@ process palette "..time())

			-- grab the rgb display palette and video mode from that process
			-- to do: cross-process memcpy

			if (awin.push_palette ~= false) then -- window can opt to leave palette alone (ref: capture.p64)
				for i=0x5000,0x54ff,4 do
					poke4(i, _ppeek4(awin.proc_id, i))
				end
			end
			if (awin.push_video_mode ~= false) then -- window can opt to leave video mode alone (ditto)
				poke(0x547c, _ppeek(awin.proc_id, 0x547c))
			end
		else
			--printh("-- skipped resetting palette "..time())
		end

		-- copy mouselock state bits

		poke(0x5f28, _ppeek(awin.proc_id, 0x5f28))
		poke(0x5f29, _ppeek(awin.proc_id, 0x5f29))
		poke(0x5f2d, _ppeek(awin.proc_id, 0x5f2d))

	else
		--printh("** default rgb palette "..time())
		pal(2) -- otherwise use default palette
	end

	-- notifications  --  show for 2~3 seconds (to do: customisable)
	-- happens after grabbing palette because modify display palette 3

	local notify_duration = 2
	if (user_notification_message and #user_notification_message > 15) notify_duration = 3
	if (time() < 3) notify_duration = 5 -- startup message; e.g. mended drive.loc

	if (user_notification_message and time() < user_notification_message_t + notify_duration) then
		local y = 270
		if (@0x547c == 3) y = 135
		if (@0x547c == 4) y = 90
		
		--rectfill(0,y-11,479,y-1,32)

		-- tint: wm is allowed to temporarily modify palette 3 per frame for displaying system elements (to do: toolbar)

		for yy = y-11, min(y-1,269) do
			local addr = 0x5400 + (yy>>2)
			local bits = (yy & 3)
			poke(addr, peek(addr) | (0x3 << ((yy & 3)*2)))
		end

		memcpy(0x5300, 0x5000, 0x100)
		
		for i=0x5300,0x53fb, 4 do
			poke4(i, (peek4(i) >> 1) & 0x7f7f7f)
		end 

		poke4(0x53fc, 0x00fff1e8) -- P8 white
		print(user_notification_message, 4,y-9, 63)

	end


	-- magnify

	if (sdat.rshift_magnify and key("rshift")) then

		local masks = peek4(0x5508); -- backup

		poke(0x5508, 0x3f, 0x3f, 0, 0) -- ignore target value; no transparency

		if (not mag_bmp) mag_bmp = userdata("u8", 64, 64)
		blit(get_display(), mag_bmp, mx-32, my-32)
		palt(0) -- nothing is transparent

		local sx,sy = mx-64, my-64
		for y=0,63 do
			local xo = xodat[y+1]
			sspr(mag_bmp, xo, y, 64-xo*2, 1, sx + xo*2, sy+y*2, 128 - xo*4, 2)
		end

		circ(mx,my,65,7) -- close enough

		circfill(mx+38,my-38,5,7) -- haha
		circfill(mx+46,my-28,3,7)

		poke4(0x5508, masks); -- restore
	end

	-- decide when window manager is presentable
	if (not sent_presentable_signal) then
		if (stat(317) > 0) then
			-- exported cartridge / bbs player: show when a window is open, active (0x1) and not holding frame (0x2)
			-- cart is last run process is the cart (/ram/cart/main.lua -> "main
			-- search through all processes for main -- maybe cart generates another windowed process
				-- if /that/ thing is called main and has drawn and is active, then fine -- present that!
			local p = fetch"/ram/system/processes.pod"
			for j=4,#p do
				-- printh(pod{p[j].name, _ppeek(p[j].id, 0x547f)})
				-- main for exports, bbs id for bbs player
				-- to do: could use awin.player_cart instead
				if ((p[j].name == "main" or p[j].name == stat(101)) and (_ppeek(p[j].id, 0x547f) & 0x3) == 0x1) then
					if (last_fullscreen_workspace) set_workspace(last_fullscreen_workspace)
					_signal(37)
					sent_presentable_signal = true
				end
			end
		else
			-- regular binaries:
			-- don't open on a tabbed tool (wait for desktop or terminal to be ready before displaying)
			if (ws_gui.style ~= "tabbed") then
				if (last_desktop_workspace) set_workspace(last_desktop_workspace)
				_signal(37) 
				sent_presentable_signal = true
			end
		end

		-- in any case, show after 7 seconds (safety)
		if (t() > 7.0) then
			_signal(37)
			sent_presentable_signal = true
			-- if (stat(318) > 0) printh("@@ forced signal 37")
		end

	end

	-- show gif capture (don't draw inside captured area!)
	if (stat(320) > 0) then
		local x,y,width,height,scale = peek2(0x40,5)


		polaroid(x,y,x+width-1,y+height-1, stat(321), max_gif_frames())
--[[

		rect(x-1,y-1,x+width,y+height,7)
		rect(x-2,y-2,x+width+1,y+height+1,7)
		rect(x-3,y-3,x+width+2,y+height+2,1)

		rectfill(x-2,y+height+1, x+width+1,y+height+9, 1)
		local maxf = max_gif_frames()
		local q = stat(321) * 32 / maxf
		local x0 = x + width - 40
		local y0 = y + height + 3

		if (width > 100) then
			print("\014frame "..flr(stat(321)).." / "..maxf, x+4,y+height+3, 7)
		else
			-- tiny mode: center capacity bar
			x0 = x + width/2 - 34/2
		end
		
		rect(x0-2, y0, x0 + 34, y0 +5, 7)
		rectfill(x0, y0+2, x0 + q, y0 +3, 7)
]]
	end


	-- debug: show when battery saver is being applied
	-- if (stat(330) > 0) circfill(20,20,10,8) circfill(20,20,5,1)


	--[[
		-- kinda cute but wrong semantic level!
		-- also: doesn't really make sense in a host window
		-- maybe later, in same category as pixel shaders
		pset(0,0,0)
		pset(479,0,0)
		pset(0,269,0)
		pset(479,269,0)
	]]

	
	-- debug cpu
	-- rectfill(30,250,200,256,stat(7) == 60 and 1 or 8) -- red when skipping
	-- print(string.format("\014cpu: %02d mem: %04dk  syscpu: %02d  awin:%02d", stat(1)\0.01, stat(0)\1024, stat(304)\0.01, awin and awin.proc_id or 0), 30,251,7)

	-- debug audio control
--	rectfill(30,250,200,256,1)
--	print("\014 "..stat(498).." ("..stat(499)..")", 30,251,7) -- 498: active pfx6416 channels  499: which process has audio focus

end


--[[
	-- sync_working_cartridge_files
	before running or saving cart, need to make sure that any changes made to location of current window is auto-saved.
	don't care about which window is active; there might have been changes in background! -> save everything

	problem: cart might implement their own wrangler that doesn't send the "save_file_completed" message back
	         -> maybe have a short (30 frames) timeout that is extended by wrangler that /does/ support it
]]
function save_working_cart_files(notify_proc_id)

--	if (pending_saves > 0) return -- problem: if a pending save is never resolved, gets stuck here; 

	-- 0.2.1e: [safety] don't interrupt if there is a save in progress that was initiated recently
	-- only relevant if user saves twice rapidly, or something goes wrong and pending_saves is never cleared by timeouts
	if (#pending_saves > 0 and time() < save_working_cart_files_t + 5.0) return

	save_working_cart_files_t = time()

	notify_on_complete_save_working_cart_files = notify_proc_id

--	printh("= save_working_cart_files =")

	num_files_to_save = 0
	pending_saves = {}
	pending_save_errors = 0

	for i=1,#workspace do
		for j=1, #workspace[i].child do
			local win = workspace[i].child[j]
			--printh(win.proc_id..": "..(win.location or "no location"))
			if (win.location and string.sub(win.location, 1, 10) == "/ram/cart/" and win.need_autosave) then

				-- don't need to autosave until the window has been active again
				win.need_autosave = false
				--printh("autosaving "..pod{win.proc_id, win.location})

				-- this is the only situation where autosave=true is used; save is skipped when no unsaved changes
				send_message(win.proc_id, {event="save_file", autosave = true, notify_on_complete = 3})
				add(pending_saves, win)
				num_files_to_save += 1
			end
		end
	end

	
	--printh("save_working_cart_files files: "..num_files_to_save)

	-- nothing that needs saving; send message right away
	if (num_files_to_save == 0) then
		_signal(39) -- 0.2.1c for detecting external changes 
		send_message(notify_on_complete_save_working_cart_files, {event="save_working_cart_files_completed", num_files = 0})
	end

end

function run_pwc(argv, do_inject, path)

	clear_infobar()
	hide_infobar()

	if (do_inject and haltable_proc_id) then
		-- inject 
		-- printh("injecting")
		local awin = get_active_window()
		if (awin) then
			send_message(awin.proc_id, {event="save_file"})
			flip()flip() -- hack: time for the editor to save. to do: expand notify_on_complete, or more general message chaining mechanism
			send_message(haltable_proc_id, {event="reload_src", location = awin.location}) -- implemented by terminal

			-- jump back to output
			set_workspace(last_pwc_output_workspace)
		end
	else
		-- launch terminal and request it to corun cproj
		-- terminal will skip creating a window and allow guest program to create it
		-- when haltable_proc_id is set, ESC means halt for that process

		-- solve a very specific problem: when ctrl-r a program that opens a socket on a particular port,
		-- need to close that host socket before creating the new process

		_close_process_host_resources(haltable_proc_id)

		-- create new one; because pwc_output is true, will clobber old one (if there is one)
		haltable_proc_id = create_process("/system/apps/terminal.lua",{
			corun_program = "/ram/cart/main.lua",       -- program to run // terminal.lua observes this and is also used to set pwd
			argv = argv,
			path = path,
			window_attribs = {				
				pwc_output = true,                      -- replace existing pwc_output process
				show_in_workspace = true,               -- immediately show running process
			}
		})

	end
end


-- used by util/run.lua
on_event("run_pwc", function(msg)
	if (msg._flags and msg._flags & 0x1 == 0) return

	-- printh("@@ event run_pwc: "..pod(msg))
	run_pwc(msg.argv, false, msg.path)
end)

function max_gif_frames()
	local _,_,w,h,scale,frames = peek2(0x40,6)
	w = max(w, 32)
	h = max(h, 32)
	if (frames == 0) frames = 30*120 -- max: 2 minutes
	return min(frames, (480*270*30*16) \ (w * h)) -- max: 16 seconds at fullscreen
	--return frames
end

function discard_key(k)
	local awin = get_active_window()
	-- prevent e.g. r from reaching the map editor when ctrl-r as key("r")  
	if (awin) send_message(awin.proc_id, {event="clear_key", scancode = k})
	clear_key(k)
end


function dkeyp(k)
	if keyp(k) then
		discard_key(k)
		return true
	end
end


function _update()

	-- debug cpu // should be ~1!
	--printh("[wm] _update:"..(stat(1)\0.001))

	-- happens while loading
	if (not ws_gui) then
		--printh("no ws_gui!!")
		return
	end


	-- make sure fullscreen terminal process exists

	local found_fullscreen_terminal = false
	local found_fullscreen_terminal_workspace = nil

	for i=1,#workspace do
		if ((workspace[i].style == "fullscreen" or workspace[i].style == "tabbed") and workspace[i].pwc_output) then
			found_fullscreen_terminal = true
			if ( #workspace[i].child == 0 and not workspace[i].recovering) then
				found_fullscreen_terminal_workspace = i
				found_fullscreen_terminal = false
			end
		end 
	end

	if (found_fullscreen_terminal) then
		created_fullscreen_terminal = true
	elseif created_fullscreen_terminal then -- a fullscreen terminal must have previously existed (i.e. false on boot)
		-- create
		create_process("/system/apps/terminal.lua",
		{
			window_attribs = {
				fullscreen = true, pwc_output = true,
				workspace = found_fullscreen_terminal_workspace and workspace[found_fullscreen_terminal_workspace].id,
				show_in_workspace = false,
				-- tabbed = true -- test: start with tabbed terminal? search: hybrid
			}
		})
		if (found_fullscreen_terminal_workspace) workspace[found_fullscreen_terminal_workspace].recovering = true
	end



--[[
	if (#ws_gui.child == 0) then
		close_workspace(workspace_index)
		if (not ws_gui) return
	end
]]
	if (screensaver_proc_id) then

		-- allow test to run for at least half a second before observing new input activity
		if (test_screensaver_t0 and time() < test_screensaver_t0 + 0.5) then
			last_input_activity_t = 0
		end

		-- kill when activity happened in the last second
		if (last_input_activity_t > time() - 1) then				
			_kill_process(screensaver_proc_id) -- window will close by itself when process is dead
			test_screensaver_t0 = nil
			screensaver_proc_id = nil
		end
	else
		
		-- 3 minutes; to do: store in settings.pod
		if (stat(317) & 0x1) == 0 then -- placeholder: no screensaver for exports / bbs player (older exported runtimes can end up running newer screensavers)
			if ((time() > last_input_activity_t + 180 or test_screensaver_t0) and not screensaver_proc_id) 
			then
				-- printh(pod(sdat))
				if (sdat and sdat.screensaver) then
					-- note: program doesn't need to know it is a screensaver; just kill process on activity event
					screensaver_proc_id = create_process(sdat.screensaver, 
						{screensaver = true, window_attribs = {workspace="current", autoclose = true}})
					test_screensaver_t0 = time() -- abuse same mechanism to ignore interrupts for first half second
				else
					last_input_activity_t = time() -- don't check again for another 3 minutes
				end
			end
		end
	end


	last_mx, last_my = mx, my
	mx, my, mb, mdx, mdy = mouse_scaled()

	if (mb > 0 and last_mb == 0) then
		start_mx = mx
		start_my = my
	end


	-- update visibility; send message

	local large_front_window = false
	local awin = get_active_window()

	local num_visible = 0

	for i=1,#workspace do
		local found_covering_window = false
--		for j=1,#workspace[i].child do
		for j=#workspace[i].child,1,-1 do

			local w = workspace[i].child[j]
			local was_visible = w.visible
	
			-- rough visibility test:
			-- same workspace, and either top (active) window, or there isn't a large window on top covering everything

			local visible = false
			if (i == workspace_index and (w == awin or not found_covering_window)) then
				visible = true
			end

			-- notify on change
			if (not was_visible and visible) then
				send_message(w.proc_id, {event="gained_visibility"})
			end
			if (was_visible and not visible) then
				send_message(w.proc_id, {event="lost_visibility"})
				-- don't draw on first frame when becomes visible again, because process needs
				-- a chance to :draw first (prevents flickering; showing a single stale frame)
				w.process_had_a_chance_to_draw = false 
			end

			w.visible = visible
			num_visible = num_visible + (visible and 1 or 0)

			-- (optimisation)
			-- placeholder test for window is covering everything underneath it   // 0x547d: alpha bits
			if (w.width==480 and w.y <= bar_h and w.y + w.height >= 270-bar_h and _ppeek(w.proc_id, 0x547d) == 0) then
				found_covering_window = true
				--printh("found covering window")
			end

		end
	end

	-- printh("num_visible: "..num_visible)

	-- tool tray visibility (DUPE)


	for i=1,#tooltray_gui.child do
		local w = tooltray_gui.child[i]
		local was_visible = w.visible
		local visible = tooltray_is_open()

		-- notify on change
		if (not was_visible and visible) then
			send_message(w.proc_id, {event="gained_visibility"})
		end
		if (was_visible and not visible) then
			send_message(w.proc_id, {event="lost_visibility"})
			w.process_had_a_chance_to_draw = false 
		end

		w.visible = visible
	end

	-- ctrl-q to fastquit // dangerous so needs to be turned on
	if (key("ctrl") and dkeyp("q")) then
		if (sdat.fastquit) _signal(33)
	end

	-- alt-f4 always available (er.. does windows do that anyway?	
	if (key("alt") and dkeyp("f4")) then
		_signal(33)
	end


	-- :: ctrl-r  (is a window manager thing!)

	-- happens early in this _update so that there's time to send lost_focus messages to tools 
	-- (so they can save their files to /ram/cart before the running program picks them up)
	if (key("ctrl") and dkeyp("r")) then

		if stat(317) > 0 then
			-- exported player or bbs player: reset cart if it is active
			if awin and (awin.player_cart) then
				local win = get_active_window()
				send_message(2, {event="restart_process", proc_id = win.proc_id})
				win.paused = false
				win.resetting = true -- don't kill process in win:update() while resetting
			end
			-- otherwise nothing happens
		else
			-- run / reset pwc
			run_pwc("", key("shift"))
		end

	end


	-- :: ctrl-p: toggle picotron menu
	-- doesn't mean much now, but later might want to add keyboard navigation [and search]
	-- so should reserve early, as is system-wide
	
	if (key("ctrl") and keyp("p")) then
		toggle_picotron_menu()
		--toolbar_y_target = tooltray_default_h
	end

	-- :: ctrl-o: open file (update: and other custom shortcuts)
	-- to do: more general rules for specifying shortcuts? e.g. not ctrl-
	if (key("ctrl")) then
		local win = get_active_window()
		if (win and proc_menu[win.proc_id]) then
			local menu = proc_menu[win.proc_id]
			for i=1,#menu do
				local mi = menu[i]
				if (type(mi.shortcut) == "string") then
					local letter = string.sub(mi.shortcut, -1)
					if (ord(letter) >= ord("A") and ord(letter) <= ord("Z")) then
						letter = chr(ord(letter) - ord("A") + ord("a"))
						-- handle s separately; context sensitive
						if (letter ~= "s" and keyp(letter)) then
							send_message(win.proc_id, {event="menu_action", id = mi.id, b = 0})
						end
					end
				end
			end
		end
	end

	-- :: ctrl-s

	if (key("ctrl") and dkeyp("s")) then

		local win = get_active_window()

		if (win and win.location and sub(win.location, 1, 10) ~= "/ram/cart/") then
			-- active window is editing a non-cartridge working file --> save only that file
			send_message(win.proc_id, {event="save_file"})
		elseif #pending_saves == 0 then
			-- otherwise, always save the whole cartridge (if there is not already a save in progress)
			-- note that normally files are saved when they lose focus (and so w:unsaved_changes() == false), so only active window is a new save.
			-- see wrangler.lua "lost_focus"

			-- save current file (get rid of unsaved changes * in window title even when there are no changes)
			send_message(win.proc_id, {event="save_file"})
			--win.need_autosave = false

			if (fetch("/ram/system/pwc.pod")) then
--				notify("\^:7f4141417f616500 saving cartridge: "..fetch("/ram/system/pwc.pod"))
				notify("\^:007f41417f613f00 ...") -- looks nice if followed by "saved" message. but some way to skip logging it?
				create_process("/system/util/save.lua", {show_notifications = true, save_last = win and win.location or nil})
			end

		end
	end

	-- only need to autosave if was active for a moment since last autosave
	if (awin) awin.need_autosave = true	

	-- :: ctrl-1, ctrl-2 to toggle toolbar / infobar

	if (key("ctrl") and dkeyp("1")) then
		ws_gui.show_toolbar = not ws_gui.show_toolbar
		if (not ws_gui.show_toolbar) toolbar_y_target = 0 -- immediately close even when mouse cursor is over it (intention + visual feedback)

		-- should show a message near the toolbar? need a "speech bubble" concept?
--		notify(ws_gui.show_toolbar and "docked toolbar" or "auto-hide toolbar")
	end

	if (key("ctrl") and dkeyp("2")) ws_gui.show_infobar = not ws_gui.show_infobar

	-- paste
	if (key("ctrl") and awin and keyp("v")) then

		-- paste from host:
		-- requires proof of intention (ctrl-v)
		-- don't discard at this point -- want the message to go through to active window (except for file references paste below)

		-- set userland clipboard text here if it is available
		-- otherwise (i.e. for web), platform is expected to proactively push using api.c::set_userland_clipboard_text() from inside browser event
		if (_get_host_clipboard_text) _set_userland_clipboard_text(_get_host_clipboard_text())

		-- paste file references
		local p, m = unpod(get_clipboard())
		if m and m.pod_type == "file_references" then
			readtext(true) -- receiving program won't get the ctrl-v message
			discard_key("v")
			send_message(awin.proc_id, {event="drop_items", 
				items = p,
				from_proc_id = 3,
				dx = 0, dy = 0,
				mx = mx, my = my,
				-- hold ctrl / shift to modify drop action (e.g. in filenav means force overwrite)
				ctrl = key"ctrl", shift = key"shift", 
			})
			--notify("pasting "..#p.." items") -- let app handle notifications
		else
			-- commented; should be handled by app -- let the message pass through
			-- notify("no items found to paste")
		end
	end

	
	--============================================== capture =========================================================

	if key("ctrl") and dkeyp("6") then
		if key("shift") then
			-- select first
			create_process("/system/apps/capture.p64", {
				window_attribs = {workspace="current", autoclose = true}, 
				intention = "capture_screenshot",
				vid_mode = 3 -- deleteme; was this a test? seems unused
			})
		else
			capture_screenshot()
		end
	end

	if key("ctrl") and dkeyp("7") then
		capture_screenshot{as_label=true}
	end

	
	-- capture gif
	if key("ctrl") and dkeyp("8") then
		if key("shift") then
			-- select first
			create_process("/system/apps/capture.p64", {
				window_attribs = {workspace="current", autoclose = true}, 
				intention = "record_video"
			})
		else
			notify() -- hide any message
			capture_video()
		end
	end

	-- finish capturing gif
	if (stat(320) > 0) then
		if (key("ctrl") and dkeyp("9") or stat(321) >= max_gif_frames()) then	
			_signal(19)
		end
	end

	-- audio capture
	if (key("ctrl") and dkeyp("0")) then
		if (not fstat("/desktop/host")) _signal(65)
		_signal(16) -- placeholder mechanism
	end

	--================================================================================================================

	-- window focus messages

	local win = get_active_window()

	if (win and last_active_win ~= win) then
		
		if (last_active_win) then 
			send_message(last_active_win.proc_id, {event="lost_focus"})
			last_active_win.is_active = false
		end

		-- give lost_focus message a chance to be processed before next window gains focus
		flip()

		win.is_active = true
		win.gained_focus_t = time()

		send_message(win.proc_id, {event="gained_focus"})

		-- when a click causes focus to change, that click should register in the window's gui immediately
		-- -> need to send updated mouse state below so that click is generated in that window's events.lua
		win.send_mouse_update = true 

		last_active_win = win
	end


	-- forward (filtered, modified) events to active window
	-- vertatim forwards also happen in _subscribe_to_events
	-- only need to send low-level device data -- click,tap etc is generated from them
	
	-- modified mouse position or mouse button
	if (win and win.proc_id) then
		if (mx ~= last_mx or my ~= last_my or mb ~= last_mb or win.send_mouse_update) and
			not (mb == 2 and win.parent == tooltray_gui) -- mb2 reserved for context menu for widgets 
		then

			last_input_activity_t = time() 

			--printh("mouse event "..pod{proc_id = win.proc_id, mx, my, mb})

			win.send_mouse_update = nil

			-- every window can read the mouse position, but only the active window can read mouse button state.
			-- dorky iterator for ws_gui and tooltray_gui
			local pointer_el = head_gui:get_pointer_element()
			if (@0x547c > 0) pointer_el = win -- video mode set -> assume pointing at active window
			for i=1,#ws_gui.child + #tooltray_gui.child do
				local win2 = i <= #ws_gui.child and ws_gui.child[i] or tooltray_gui.child[i - #ws_gui.child]
					send_message(win2.proc_id, {event="mouse",dx = mdx, dy = mdy, mx_abs = mx, my_abs = my, mx = mx-win2.sx, my=my-win2.sy, 
						-- only active window is allowed to read mouse button (title bar / resizer widget doesn't count)
						mb = (win == win2 and win == pointer_el) and mb or 0
					})
			end

		end
		last_mx, last_my, last_mb = mx, my, mb
	end


	-- reset; so that e.g. alt + left doesn't bring up tooltray menu
	if (keyp("alt")) then
		used_alt_navigation = false
	end


	-- to do: terminal AND desktop filenav(!) should be allowed to capture enter
	-- a little different from capture_escapes ~ window can just have pauseable property (turn off to capture enter)
	-- wallpaper should never be pausible
	-- awin.fullscreen and not awin.pwc_output and not awin.desktop_filenav and not awin.wallpaper) then 

	if (awin and awin.pauseable) then

		update_window_paused_menu(awin)

	end

	if (dkeyp("escape")) then

		-- look for haltable process
		-- (assumes there is only one)
		local width, height = _get_process_display_size(haltable_proc_id)

		if (modal_gui) then
			dismiss_modal()
		elseif (awin and awin.paused) then
			awin.paused = false
			send_message(awin.proc_id, {event = "unpause"})
		elseif toolbar_y_target > 0 then
			-- close tooltray if open
			toolbar_y_target = 0
		elseif infobar_y_target < 270 then
			-- close infobar if open
			hide_infobar()
		elseif (awin and awin.capture_escapes) then
			-- let active window handle it
			send_message(awin.proc_id, {event="keydown",scancode=41}) -- added in 0.2.0c; when did this become necessary?
		elseif (awin and awin.autoclose) then
			-- 0.2.0h: moved under capture_escapes; should be able to capture escapes from an auto-closing window
			if is_fullscreen_export(win) then
				-- 0.2.0h playing the entry point cart in a binary export -> quit to host OS (same as Exit Cartridge menu item)
				if (stat(318) == 0) send_message(2, {event="shutdown"}) -- only on binaries; on web, do nothing
			else
				close_window(get_active_window(), true) -- e.g. about / settings
			end
		elseif (width and width > 0 and awin and awin.proc_id == haltable_proc_id) then 
			-- stop haltable process
			--printh("sending halt message to: "..haltable_proc_id)
			local hwin = get_window_by_proc_id(haltable_proc_id)
			hwin.was_pauseable = hwin.pauseable and true or false -- used by restore_pauseable
			send_message(haltable_proc_id, {event="halt"})
			haltable_proc_id = false
		elseif (awin and awin.pauseable) then
			win.paused = true
			generate_paused_menu(win)
			send_message(win.proc_id, {event = "pause"})
		elseif not is_fullscreen_export(awin) then -- 0.2.0h: export that is not pausible -> esc should do nothing
			-- toggle between output / last workspace
			if (ws_gui.style == "fullscreen") then
				set_workspace(last_non_fullscreen_workspace or last_desktop_workspace)
			elseif (awin and awin.pwc_output) then
				-- back to editor
				set_workspace(last_non_desktop_workspace or last_fullscreen_workspace)
			else
				set_workspace(last_fullscreen_workspace)
			end
		end

	end

	-- keyboard control
	if (key("alt") and not is_locked_in_fullscreen()) then
		if (dkeyp("left")) then set_workspace(workspace_index - 1) used_alt_navigation = true end
		if (dkeyp("right")) then set_workspace(workspace_index + 1) used_alt_navigation = true end
	end

	-- toggle (host) fullscreen

	if (key("alt") and key("enter") and not last_enter_key_state) then		
		sdat.fullscreen = not sdat.fullscreen
		store("/appdata/system/settings.pod", sdat)
		-- clear key buffer (avoid "enter" being sent to text editor)
		readtext(true)
		discard_key("enter") -- for good measure: key("enter") shouldn't be true either until repressed
	end
	last_enter_key_state = key("enter")

	-- toggle mute
	if key("ctrl") and dkeyp("m") then
		send_message(pid(), {event = "toggle_mute", notify=true})
	end

	local dtab_index = 0
	if (key("ctrl") and dkeyp("tab")) then
		dtab_index = key("shift") and -1 or 1
	end

--[[
	-- don't need yet -- no flipping through windows, and ctrl-tab is nicer for tabs.
	if (key("alt") and keyp("up")) dtab_index = -1
	if (key("alt") and keyp("down")) dtab_index = 1
]]

	if (dtab_index != 0) then
		local tab = get_workspace_tabs()

		-- to do: for windows, need to keep a list of windows in order they are visited and use that
		-- perhaps only count windows with z==0 or something? don't want desktop, filenav, birds

		-- if (#tab < 2) tab = ws_gui.child -- cycle through windows instead;  

		for i=1,#tab do
			if (tab[i].is_active) then

				j = i + (#tab + dtab_index)
				while (j > #tab) do j = j - #tab end

				set_active_window(tab[j])

			end
		end

	end

	-- to do: while dragging items, switch between active window
	-- causes gui logic complexity but is nice and should drive gui logic to be cleaner
	-- annoying case: drag files out and back in to a window -> spurious events cause selection to start
		-- maybe just up to wm to manage which events get through while dragging files
	-- update: ah.. maybe switching window focus is not desired behaviour anyway
	-- -> light provisional version: just bring to front for a little visual feedback
	if (dragging_items) then
		local win2 = head_gui:el_at_xy(mx, my)
		if (win2) then
			if (win2.is_window_bar) win2 = win2.parent
			win2:bring_to_front()
		end
	end

--[[
	if (dragging_items) then
		local win2 = head_gui:el_at_xy(mx, my)
		if (win2 and win2.is_window_bar) win2 = win2.parent
		if (win2 ~= get_active_window()) then
			set_active_window(win2)
			send_message(win2.proc_id, {event = "block_mouse_events"})  --  need to block events until mb == 0
		end
	end
]]

	-- drop

	if (mb == 0 and dragging_items) then

		-- send a message to whatever window the cursor is over
		local win2 = head_gui:el_at_xy(mx, my)

		-- titlebar counts! (can drag and drop into titlebar, put sticker on titlebar)
		if (win2 and win2.is_window_bar) win2 = win2.parent

		--printh("dropping into proc: "..tostr(win2.proc_id))
		
		if (win2 and win2.proc_id) then

			-- first, window manager might consume some of the items (stickers)
			
			for i=1,#dragging_items do
				local item = dragging_items[i]
				--printh("item: "..pod(item))
				if (item.pod_type == "sticker") then
					--if (type(win2.stickers) != "table") win2.stickers = {} 

					-- imprint location
					if (not item.location and win2.location) then
						item.location = win2.location
						notify("assign location: "..item.location)
					end
					
					win2:attach{
						x = mx - win2.sx + item.xo,
						y = my - win2.sy + item.yo,
						width=12, height=12,
						item = item,
						cursor = "grab",
						clip_to_parent = false,
						draw = function(self, msg)
							spr(self.item.icon,0,0)
						end,
						drag = function(self, msg)
							local dx = msg.mx - msg.mx0
							local dy = msg.my - msg.my0
							if (dx*dx + dy*dy > 2*2 and not dragging_items) then
								dragging_items = {
									item
								}

								self:detach() -- remove
							end
						end,
						tap = function(self, msg)
							if (self.item and self.item.location) then
								create_process("/system/util/open.lua", { argv = {self.item.location} })
							end
						end
					}
				end
			end

			-- send to window for processing
			-- printh("drop_items send to window with mx,my: "..pod{mx - win2.sx, my - win2.sy})
			send_message(win2.proc_id, {event="drop_items", 
				items = dragging_items,
				from_proc_id = dragging_items_from_proc_id,
				dx = mx - start_mx, dy = my - start_my, 
				mx = mx - win2.sx, 
				my = my - win2.sy,
				-- hold ctrl / shift to modify drop action (e.g. in filenav means force overwrite)
				ctrl = key"ctrl", shift = key"shift"
			})
		end

		dragging_items = nil
	end


	-- update gui
	if (not screensaver_proc_id) then
		head_gui:update_all()
	end

	-- store state of windows data // to do: pm could let wm know if anyone is subscribed to alter frequency
	--[[
	if (not last_windat_t or time() > last_windat_t + 0.125) then
		last_windat_t = time()
		store("/ram/shared/windows.pod", generate_windat())
	end
	]]
	store("/ram/shared/windows.pod", generate_windat()) -- every frame; quite cheap

	if (sdat.sparkles) then
		update_sparkles()
	else
		init_sparkles() -- reset. to do: existing sparkles should be allowed to live out their life? anti-module pattern though!
	end

	-- battery saver shouldn't kick in while running a fullcsreen app (unless it is terminal)
	-- exception: pwc_output should  always run full speed even if windowed
	-- to do: configurable -- user should be able to test the effect of battery saver on pwc_output
	if (ws_gui.style == "fullscreen" and not ws_gui.pwc_output) or 
		(awin and awin.proc_id == haltable_proc_id)
 	then
		if (not screensaver_proc_id) then
			_signal(22) -- stay awake
		end
	end


	------ update pending saves

	if #pending_saves > 0 then
		for i=#pending_saves, 1, -1 do
			local win = pending_saves[i]
			-- short timeout (0.2) for non-standard wranglers; usually enough, and not a big deal if proceed too early
			-- (non-standard means can't rely on save_file_completed message being received to resolve the pending save)
			local timeout = min(5.0, win.save_timeout or 0.2) -- never wait more than 5 seconds for an autosave
			--printh("timeout: i,proc_id,timeout  "..pod{i, win.proc_id, timeout})
			if  time() > save_working_cart_files_t + timeout -- taking too long; something went wrong?
				or _process_state(win.proc_id) < 0           -- process died while trying to save?
			then
				pending_saves[i] = nil
			end
		end
		-- let requester (info / save) know they can give up on waiting
		if (#pending_saves == 0 and notify_on_complete_save_working_cart_files) then
			send_message(notify_on_complete_save_working_cart_files, {event="save_working_cart_files_completed", num_files = num_files_to_save})
		end
	end

	------

	-- debug: changing focus
	--[[
		awin = get_active_window()
		if (awin and awin ~= last_awin) then
			printh("active: "..awin.proc_id)
		end
		last_awin = awin
	--]]

	

end


-- to do: could maintain a lookup
-- to do: tooltray_gui windows
--local 
function get_window_by_proc_id(proc_id)

	for i=1,#workspace do
		for j=1,#workspace[i].child do
			if workspace[i].child[j].proc_id == proc_id then
				return workspace[i].child[j], i
			end 
		end
	end

	if (tooltray_gui) then
		for i=1,#tooltray_gui.child do
			if (tooltray_gui.child[i].proc_id == proc_id) return tooltray_gui.child[i], -1
		end
	end

	return nil -- none
end

function remove_workspace(index)
	for i=index, #workspace do
		workspace[i] = workspace[i+1]
	end
	set_workspace(ws_gui)
end



-- close window here so that don't invalidate window iterator
-- 0.2.0i also used by misc/confirm.p64 
on_event("close_window", 
	function(msg)
		if (not msg._flags or msg._flags & 0x1 == 0) return -- only used by system processes

		--printh("received close_window: "..pod{msg})

		for i=1,#workspace do
			local pos = 1
			local num = #workspace[i].child
			
			for j=1,num do
				if workspace[i].child[j].proc_id == msg.proc_id then
					-- remove from list of tabs
					del(workspace[i].tabs, workspace[i].child[j])
					if (workspace[i].child[j].location) then
						workspace[i].last_ext = workspace[i].child[j].location:ext()
						workspace[i].last_dir = workspace[i].child[j].location:dirname()
					end
				else
					-- shunt -- keep only processes that don't match those to be removed
					workspace[i].child[pos] = workspace[i].child[j]					
					pos = pos + 1
				end
			end

			-- clear end
			while (pos <= num) do
				workspace[i].child[pos] = nil
				pos = pos + 1
			end
		end

		generate_head_gui()

		-- finally, kill the process (if not already dead)
		_kill_process(msg.proc_id)
	end
)



function choose_workspace(attribs)

	if (attribs.workspace == "current") return ws_gui

	if (attribs.workspace == "tooltray") return tooltray_gui
	
	-- explicitly requested a new workspace (e.g. New Desktop from toolbar right click menu)
	if (attribs.workspace == "new") return nil

	-- by workspace id
	if (type(attribs.workspace) == "number") then
		for i=1,#workspace do
			if (workspace[i].id == attribs.workspace) return workspace[i]
		end
	end

	---- no particular workspace requested --> choose based on attributes

	-- wallpaper should open in same workspace (when new workspace was not requested)
	if (attribs.wallpaper) return ws_gui

	-- tabbed window get workspace running same program (to do)
	if (attribs.tabbed) then

		for i=1,#workspace do
			if (workspace[i].style == "tabbed" and workspace[i].prog == attribs.prog) then
				return workspace[i]
			end
		end

		return nil
	end

	-- fullscreen window gets new workspace
	if (attribs.fullscreen) return nil

	-- otherwise: desktop app
	return last_desktop_workspace

end

on_event("app_menu_item", function(msg)

	--printh("app_menu_item from "..pod{msg._from})
	
	proc_menu[msg._from] = proc_menu[msg._from] or {}
	local menu = proc_menu[msg._from]

	-- clear
	if (msg.clear) then
		proc_menu[msg._from] = {}
		return
	end

	-- add a divider
	if (msg.attribs.divider) then
		if (menu[#menu] and menu[#menu].divider) return -- skip adding duplicate divider
		add(menu, {id="divider_"..#menu, label="[divider]", divider=true})
		return
	end
	
	-- look for existing item by id
	local pos = #menu + 1 -- default: add new
	for i=1,#menu do
		if (menu[i].id == msg.attribs.id) then

			pos = i -- overwite this slot

			-- update label (might have changed due to callback)
			if (msg.attribs.label) then
				menu[i].label = msg.attribs.label
				local win = get_window_by_proc_id(msg._from)
				if (win and win.pmenu) then
					for i=1,#win.pmenu do
						if (win.pmenu[i].id == msg.attribs.id) then
							win.pmenu[i].label = msg.attribs.label
						end
					end
				end
			end

		end
	end
	
	menu[pos] = msg.attribs

	if (get_active_window() and get_active_window().proc_id == msg._from) then
		-- update live item when this is the active window
		update_app_menu_item(menu[pos])
	end
end)


-- allow dragging a frame late for windows with squashable used when squashing so that display size matches 
-- evaluated element size on draw, by delaying window movement by a frame. stoopid solutions for stoopid problems
on_event("drag_squashable_window", function(msg)
	if (msg._from ~= 3) return
	--printh("drag_squashable_window "..pod{msg})
	local win = get_window_by_proc_id(msg.proc_id)
	win.x = msg.x
	win.y = msg.y
	win.sx = win.parent.sx + win.x
	win.sy = win.parent.sy + win.y
end)

on_event("set_window", function(msg)

--	printh("set_window: "..pod(msg))

	if (msg._from <= 3) return -- safety: don't create window for window manager

	local win = get_window_by_proc_id(msg._from)
	local attribs = msg.attribs or {}
	local target_ws = nil
	local old_win = nil
	local old_location = win and win.location or nil
	

	-- creating cart output window:  replace any existing output window

	if not win and msg.attribs.pwc_output then
		for i=1,#workspace do
			for j=1,#workspace[i].child do
				if (workspace[i].child[j].pwc_output) then
					-- match: replace fullscreen output when running fullscreen program / window when running windowed
					if (attribs.fullscreen == workspace[i].child[j].fullscreen or
						not attribs.fullscreen and not workspace[i].child[j].fullscreen) then 
						old_win = workspace[i].child[j]
						close_window(old_win, true)
						target_ws = workspace[i]
					end
				end
			end
		end
	end

	

	-- if no existing window, create it
	if not win then

		--printh("creating window "..pod(attribs))

		-- 1. find workspace for it
		if (not target_ws) target_ws = choose_workspace(attribs)

		-- 2. if no existing workspace, create it
		if (not target_ws) then
			target_ws = create_workspace_1(msg._from, attribs)
		end

		-- 3. create the window

		-- if tooltray, force fixed position and frameless
		if (target_ws == tooltray_gui) then
			attribs.has_frame  = false
			attribs.moveable   = false
			attribs.resizeable = false
		end

		-- use a copy of attribs -- create_window() adds gui stuff, and want to iterate over original below
		local attribs_1 = unpod(pod(attribs))
		win = create_window(target_ws, attribs_1)

		

		-- if position is specified and has frame, should stay inside
		if (attribs.has_frame) then
			if (attribs.x) attribs.x = mid(0, attribs.x, 480 - attribs.width)
			if (attribs.y) attribs.y = mid(24, attribs.y, 270 - attribs.height)
		end

		-- 4. set starting window attributes. guess a title
		win.proc_id = msg._from

		local segs1 = split(attribs.prog,"/",false) or {}
		win.title = attribs.title or segs1[#segs1] or "proc_"..msg._from

		-- 4.a: when present working cart output, replace existing window at same position
		if (old_win) then
			win.x = old_win.x
			win.y = old_win.y
		end

		-- 5. add to tabs
		if (msg.attribs.tabbed) then
			-- 0.2.0h: sort by process id so that load.lua / open.lua produces tabs in the same order they were stored
			local insert_pos = 1
			for i=1, #target_ws.tabs do
				if (msg._from > target_ws.tabs[i].proc_id) insert_pos = i+1
			end
			-- printh("@@ insert_pos for "..msg._from..": "..insert_pos.."   "..tostring(target_ws))
			add(target_ws.tabs, win, insert_pos)
		end

		-- 6. show in workspace if requested 
		-- 0.1.1b: when show_in_workspace not specified, wm is allowed to decide
		if (msg.attribs.show_in_workspace or
			(msg.attribs.show_in_workspace == nil and msg.attribs.workspace ~= "tooltray")
		) then
			previous_workspace = ws_gui
			set_workspace(target_ws)
			target_ws.active_window = win -- give focus immediately
		end

		-- 7. give focus immediately when requested (autoclose implies should start with focus)
		if (msg.attribs.give_focus or msg.attribs.autoclose) then
			target_ws.active_window = win -- give focus immediately
		end

		-- 8. do some validation 
		-- was removed for 0.1.0f but caused [no workspaces] bug which seems to happen frequently but couldn't reproduce yet. race condition?
		-- to do: what is actually responsible for ensuring a valid workspace? should it really happen here?
		local workspace_index1 = mid(1, workspace_index, #workspace)
		if (workspace_index ~= workspace_index1 or ws_gui ~= workspace[workspace_index1]) then
			set_workspace(workspace_index1)
		end

		-- 8.a: make sure window never goes above toolbar; hard to close it and is rendered overlapping in tooltray area
		win.y = max(24, win.y)

		-- 9. let window know where it is to start with
		-- (e.g. might want to preserve original window position)
		send_message(win.proc_id, {event="move", x = win.x, y = win.y, dx = 0, dy = 0})

		-- 10. let the parent know that their child created a window

		send_message(win.parent_pid, {event="child_created_window", proc_id = win.proc_id})


		generate_head_gui()

		

	end

	
	-- modify / set attributes
	-- these are requested by program itself, so allowed to disregard restrictions in x,y (.moveable), width,height (.resizeable)

	for k,v in pairs(attribs) do
		win[k] = v
	end

	if (attribs.icon) then
		proc_icon[msg._from] = attribs.icon

		-- to do: update workspace button icon
		if (ws_gui and ws_gui.head_proc_id == msg._from) then
			ws_gui.icon = win.icon
			--printh("updating icon "..pod(win.icon))
		end
	end


	-- for squash_to_clip / squash_to_parent
	if (not attribs.squash_event) then -- don't want to do this during a squash event though
		if (attribs.width)  win.width0  = win.width
		if (attribs.height) win.height0 = win.height
		attribs.squash_event = false -- temporary directive sent by squash event in events.lua
	end

	--[[
		look for an existing window with matching tool and working file 
		if jump_to_matching_window is jump to that instead (code errors)
		otherwise, warn user that multiple windows are open editing the same file
	]]

	if (old_location ~= win.location) then

		-- printh("set_window change of location: "..pod{old_location, win.location})

		-- kill self if another window open with same location ** using same program **
		for i=1,#workspace do
--			for j=1, #workspace[i].child do
			for j=#workspace[i].child,1,-1 do -- prefer front window (otherwise end up cycling through when multiple windows open with same file)
				local win2 = workspace[i].child[j]
				if (win2 ~= win and not win2.closing and
					type(win.location) == "string" and type(win2.location) == "string" and
					win.location:path() == win2.location:path()      -- same location (disregarding the hloc part after the #)
					--and win.prog and win.prog == win2.prog           -- editing using same program; commented now that multiple windows is the default. deleteme
				) then

					-- 0.2.0h: observe jump_to_matching_window -- could be set by the client (unusual) /or/ the process calling create_process
					if win.jump_to_matching_window then
					
						-- kill self!  -- to do: don't create the window in the first place
						_kill_process(win.proc_id)
						win.hidden = true

						-- kill newly created workspace if created one for this
						if (target_ws and #target_ws.child == 0) then
							del(ws_gui, target_ws)
						end

						-- go to other window
						-- 0.1.1b: when show_in_workspace not specified, wm is allowed to decide
						if (msg.attribs.show_in_workspace or
							(msg.attribs.show_in_workspace == nil and msg.attribs.workspace ~= "tooltray")
						) then
							set_workspace(i)
							win2:bring_to_front()
						end

						-- tell win2 about the hash location

						send_message(win2.proc_id, {
							event = "jump_to_hloc",
							hloc = win.location:hloc(),
							extra = {highlight = true} -- highlight the line being jumped to (used by code editor)
						})
						
						-- commented; doesn't really need an explanation -- mostly used for opening from error messages
						-- notify("editing "..win.location.." in existing process")
					else
						-- this might be confusing if didn't realise is already open --> should warn gently
						if (not old_location) or old_location:path() ~= win.location:path() -- changing files, not just hash location
						then
							notify("\^:07071717505c4070 "..win.location:path().." is open in multiple "..((win.tabbed and win2.tabbed) and "tabs" or "windows"))
						end
					end
					
					break -- don't need to search for more matching processes
				end
			end
		end
	end

	-- create wallpaper

	if (msg.attribs.wallpaper) then
		-- kill old wallpaper
		for i=1,#target_ws.child do
			if (target_ws.child[i].wallpaper and target_ws.child[i] != win) then
				-- send_message(pid(), {event="close_window",proc_id = target_ws.child[i].proc_id}) -- kill next frame
				_kill_process(target_ws.child[i].proc_id)
				--send_message(2, {event="kill_process", proc_id=target_ws.child[i].proc_id})
			end
		end

	end

	-- sign of life from process -- proof that finished resetting
	if (win.resetting) then
		-- give back focus
		last_active_window = nil
		send_message(win.proc_id, {event="gained_focus"}) -- otherwise can e.g. lose controller input (see events, which keeps track of focus)
		win.resetting = nil
	end

	
	-- not here -- messes up dragging
	--generate_head_gui()

end)

-- program can ask window manager to move self by dx, dy
-- useful for implementing alternative title bar (drag self)
-- to set absolute x,y: use set_window
on_event("move_window", function(msg)
	local win = get_window_by_proc_id(msg._from)

	if (msg.dx) win.x += msg.dx
	if (msg.dy) win.y += msg.dy

end)


on_event("set_haltable_proc_id",
	function(msg)
		haltable_proc_id = msg.haltable_proc_id
	end
)

-- to do: nicer name for this; "log_message"?
on_event("user_notification",
	function(msg)

		if (msg.content == nil) then
			-- 0.2.1c: can hide message
			user_notification_message = nil
		else
			-- printh("##################### "..pod(msg))
			user_notification_message = tostring(msg.content) -- 0.2.0h -- should always be a string
			user_notification_message_t = time()

			-- to do: log it in infobar
			-- send_message(3, {event="log", content = msg.content})
		end		

	end
)

-- used by util/save.lua and lib/resources.lua to autosave everything open to /ram/cart

on_event("save_file_completed", 
	function(msg)
		del(pending_saves, get_window_by_proc_id(msg._from))
		if (msg.err) pending_save_errors += 1
		-- printh("WM MESSAGE save_file_completed: "..msg.filename.." --> pending_saves: "..#pending_saves)
		if (#pending_saves == 0 and notify_on_complete_save_working_cart_files) then
			_signal(39) -- 0.2.1c for detecting external changes on host
			send_message(notify_on_complete_save_working_cart_files, {event="save_working_cart_files_completed", num_files = num_files_to_save})
			-- too noisey; to do: maybe log somewhere later when have log channels?
			--if (not msg.autosave) notify("\^:0f19392121213f00 saved file: "..fetch("/ram/system/pwc.pod"))
		end
	end
)
on_event("save_working_cart_files", 
	function(msg)
		save_working_cart_files(msg.notify_on_complete)
	end
)
on_event("save_open_locations_metadata",
	function(msg)
		save_open_locations_metadata()
	end
)



--[[
	-- used by util/load.lua
	-- close any programs that are editing carts
]]
on_event("clear_project_workspaces",
	function(msg)
		for i=1,#workspace do
			local num = #workspace[i].child
			-- close / kill all windows under that workspace
			for j=1, #workspace[i].child do
				local win = workspace[i].child[j]
				if (win.location and string.sub(fullpath(win.location), 1, 10) == "/ram/cart/") then
					close_window(workspace[i].child[j], true)
					num -= 1
				end
			end
		end
		generate_head_gui()
	end
)


on_event("dock_toolbar",
	function(msg)
		-- to do: should modify the workspace that the window belongs to
		ws_gui.show_toolbar = msg.state
	end
)


on_event("drag_items",
	function(msg)
		-- to do: should modify the workspace that the window belongs to
		dragging_items = msg.items
		if (dragging_items) then
			dragging_items_from_proc_id = msg._from
			local win = get_window_by_proc_id(msg._from)
			for i=1,#dragging_items do
				local item = dragging_items[i]
				item.x = (item.x or 0) + win.sx
				item.y = (item.y or 0) + win.sy
			end
		end
	end
)


on_event("set_wallpaper",
	function (msg)
		-- 0.2.0i: sandboxed process can not set wallpaper // to do: allow but carry over sandbox? meh
		if (msg._flags and msg._flags & 0x2 > 0) then
			notify("can not set wallpaper from sandboxed process") -- to do: separate error log 
			-- printh("can not set wallpaper from: "..msg._from)
			return
		end
		create_process(msg.wallpaper, {window_attribs = { wallpaper = true, workspace = "current"}})
	end
)

on_event("test_screensaver",
	function(msg) 
		test_screensaver_t0 = time()
	end
)

on_event("toggle_app_menu",
	function(msg)
		toggle_app_menu(msg.x, msg.y, get_window_by_proc_id(msg.proc_id), msg.is_context_menu)
	end
)

-- toggle system-wide mute
on_event("toggle_mute",
	function(msg)
		sdat.mute_audio = not sdat.mute_audio
		store("/appdata/system/settings.pod", sdat)

		if (msg.notify) then
			notify("Sound: "..(sdat.mute_audio and "Off" or "On"))		
		end
	end
)


function poke_capture_name(name)
	if not name then
		-- use program name of active window
		local awin = get_active_window()

		if (awin and awin.prog == "/system/apps/capture.p64" and not awin.has_frame) then
			-- using the capture tool -- name should be for the next window down
			awin = ws_gui.child[#ws_gui.child-1]
		end

		if (awin and awin.prog) then
			if (awin.prog == "/ram/cart/main.lua") then
				name = fetch("/ram/system/pwc.pod")
				if (name) name = name:basename():split(".",false)[1]
			else
				name = awin.prog:basename():split(".",false)[1]
			end
		end
	end
	name = name or "picotron" -- safety

	local sdat = fetch"/appdata/system/settings.pod" or {}
	if (sdat.capture_timestamps) then
		-- append a timestamp so that filenames don't collide e.g. when adding files to
		-- a collection of previous captures with the same name
		local d = date()
		name ..= "_"..d:sub(3,4)..d:sub(6,7)..d:sub(9,10)
	end

	-- up to 64 chars
	memset(0x60,0,64)
	if (name) poke(0x60,ord(name:sub(1,64),1,64))
end


function capture_video(cdat)

	if (not fstat("/desktop/host")) _signal(65)

	-- local cdat = fetch"/ram/system/capture.pod" or {}
	local cdat = cdat or {}
	poke2(0x40, 
		tonum(cdat.x)      or 0,
		tonum(cdat.y)      or 0,
		tonum(cdat.width)  or 480 / pixel_scale(),
		tonum(cdat.height) or 270 / pixel_scale(),
		tonum(cdat.scale)  or 2,
		tonum(cdat.frames) or 30*120, -- max: 2 minutes (to do: configurable)
		-- delay: +1 because want to start on the display data that is /going to/ be send to video out this frame
		(tonum(cdat.delay) or 0) + 1, -- frames to skip at start.
		cdat.silent and 1 or 0
	)

	-- name: up to 64 chars long
	poke_capture_name(cdat.name)
	
	_signal(18)
end

function capture_screenshot(cdat)

	-- printh("capture_screenshot "..pod(cdat))
	notify() -- hide any message // almost never want it to be visible (could be optional later)

	if (not fstat("/desktop/host")) _signal(65)

	local cdat = cdat or {}
	poke2(0x50,
		tonum(cdat.x)      or 0,
		tonum(cdat.y)      or 0,
		tonum(cdat.width)  or 480 / pixel_scale(),
		tonum(cdat.height) or 270 / pixel_scale(),
		tonum(cdat.scale)  or 2,
		cdat.as_label and 1 or 0,
		-- delay: +1 because want to start on the display data that is /going to/ be send to video out this frame
		(tonum(cdat.delay) or 0) + 1, -- frames to skip at start.
		cdat.silent and 1 or 0
	)

	-- name: up to 64 chars long
	poke_capture_name(cdat.name)
	
	_signal(21)
end

-- security: sandboxed apps can request captures, but can't read them back (/desktop/* is not visible to them)

on_event("capture_video", capture_video)
on_event("capture_screenshot", capture_screenshot)


function save_open_locations_metadata()
	-- store all cart file locations /ram/cart/.info.pod

	local ws_info = {}
	for i=1,#workspace do
		for j=1, #workspace[i].tabs do
			local tt = workspace[i].tabs[j]

			-- add tab if a cart file (store relative to /ram/cart/)

			if sub(fullpath(tt.location), 1, 10) == "/ram/cart/" then

				-- printh("save_open_locations_metadata location: "..pod(tt.location))

				-- is cart file
				add(ws_info,{
					workspace_index = i,                    -- probably can't use but might be handy to group files
					location = sub(tt.location, #"/ram/cart" + 2)   -- store relative to /ram/cart/ (+2 to skip the /)
				})

			end
		end
	end

	-- metadata is normally not very large
--	printh("@@ storing workspace metadata: "..pod(ws_info))
	store_metadata("/ram/cart", {workspaces = ws_info})

end


function dismiss_modal()
	if (modal_gui) modal_gui:detach()
	modal_gui = nil
end


function create_modal_gui()

	modal_gui = head_gui:attach{
		x = 0, y = 0, width = 480, height = 270,
		--draw = function() rectfill(0,0,480,270,8) end, -- debug
		click = dismiss_modal
	}

	return modal_gui
end

-- close by index (not by id)
function close_workspace(ws_index, force)
	local ws = get_workspace(ws_index)

	if (ws) then
		for i=1,#ws.child do
			_kill_process(ws.child[i].proc_id)
		end
	end

	-- fix workspace index; when delete current, hop to left unless already at left-most
	if (ws_index <= workspace_index and workspace_index > 1) workspace_index -= 1

	deli(workspace, ws_index)
	set_workspace(workspace_index)
end




function toggle_workspace_menu(x, y, ws_index)

	local pulldown = create_modal_gui():attach_pulldown{
		is_app_menu = true,
		x = x, y = y,
		width = 100, 
		ws_index = ws_index,
	}

	pulldown.onclose = dismiss_modal


	pulldown:attach_pulldown_item
	{
		label = "\^:1c3e6b776b3e1c00 Close Workspace", 
		cursor="pointer",
		action = function()
			close_workspace(ws_index)

		end
	}

end


-- update the single label of an appmenu item rather than regenerating the interface on change
function update_app_menu_item(ii)
	if (not app_menu_pulldown) return
	for i=#app_menu_pulldown.child,1,-1 do -- end to start for deletion
		if (app_menu_pulldown.child[i].id == ii.id) then
			if (not ii.label) then
				deli(app_menu_pulldown.child, i) -- no label means remove item
			else
				app_menu_pulldown.child[i].label = ii.label
			end
		end
	end
end

function toggle_app_menu(x, y, win, is_context_menu)

	local win = win or get_active_window()

	if (not win) return

	-- app menu is already open
	if (modal_gui and modal_gui.child[2] and modal_gui.child[2].is_app_menu) then
		modal_gui = nil
		return
	end

	-- empty workspace

	if (#ws_gui.child == 0) return


	local mm = {}

	local pulldown = create_modal_gui():attach_pulldown{
		is_app_menu = true,
		confine_to_clip = true, -- all of menu visible; bump inside when needed
		x = x, y = y,
		width = 144 -- to do: be adaptive when drawing
	}

	pulldown.onclose = dismiss_modal

	app_menu_pulldown = pulldown

	-- add about item // to do: get icon & title from .p64 when create window (can be default title too)

	-- to do: generate icon from win.icon

	if (not is_context_menu) then
		-- special case: view about /ram/cart when running /ram/cart/main.lua
		local about_prog = win.prog == "/ram/cart/main.lua" and "/ram/cart" or win.prog 
		add(mm, {icon = win.icon, label = "About "..about_prog:basename(),
		action = function() 
			create_process("/system/apps/about.p64", {
				prog = about_prog, window_attribs={workspace="current", autoclose = true
			}})
		end})
	end

	-- userland items created by menuitem()

	local menu = proc_menu[win.proc_id]

	if (menu and #menu > 0) then

		if (not is_context_menu) add(mm, {divider=true}) -- divider to separate the about program item at top

		local last_group = nil
		for i=1,#menu do

			if (menu[i].label) then
				local item = menu[i]
				local pulldown_item = unpod(pod(item)) -- copy all attributes

				pulldown_item.action = function(b)
					send_message(win.proc_id, {event="menu_action", id=menu[i].id, b=b})
				end

				add(mm,pulldown_item)

				-- 0.2.1c: add extra divider to separate wrangler items
				if (mm.group ~= last_group) add(mm, {divider=true})
			end
		end

	end

	-- window management items at bottom

	if (win.width == 480 and win.height == 270) then
		-- can't close (fullscreen file navigator on desktop)
	elseif (win.width == 480 and win.sy < 12) then
		-- tab (to do: better test!)
		add(mm, {divider=true})
		add(mm, {label="\^:1c3e6b776b3e1c00 Close Tab", action = function() close_window_with_confirmation(win, true) end})
	elseif (win.parent == tooltray_gui) then
		add(mm, {divider=true})

		add(mm, {label="\^:1c3e6b776b3e1c00 Pop Out Widget", action = function()
			set_workspace(last_desktop_workspace)
			pop_out_widget(win, 240-win.width/2, 30)
		end})

		add(mm, {label="\^:1c3e6b776b3e1c00 Remove Widget", action = function() 
			uninstall_widget(win)
			close_window(win, true)			
		end})
	else
		-- regular window
		add(mm, {divider=true})
		add(mm, {label="\^:1c3e6b776b3e1c00 Close Window", action = function() close_window_with_confirmation(win, true) end})
	end


	-- calculate required width; items use this when attached
	local max_width = 140 -- nominal minimum (can fit everything that ships with system)
	for i=1,#mm do
		if (mm[i].label) then
			local ww = print(mm[i].label..(mm[i].shortcut or "") ,0,-1000) + 20
			max_width = max(max_width, ww) -- push out
		end
	end
	pulldown.width = max_width

	-- attach
	local last_item_is_divider = false
	for i=1,#mm do
		mm[i].cursor = "pointer"
		if (not mm[i].divider or not last_item_is_divider) then
			pulldown:attach_pulldown_item(mm[i]) -- avoid double dividers (added by this function; app menu items are also filtered for duplicates
		end
		last_item_is_divider = mm[i].divider
	end


end

function toggle_picotron_menu()

	-- already open
	if (modal_gui and modal_gui.child[2] and modal_gui.child[2].is_pictron_menu) then
		modal_gui = nil
		return
	end

	-- never open in fullscreen exports
	if (is_locked_in_fullscreen()) then
		modal_gui = nil
		return
	end


	
	----------------------------------------
	-- pulldown
	----------------------------------------

	-- to do: populate some of this from a configurable shortcuts list
	-- could just look for shortcuts in /appdata/system/shortcuts

	local item =
	{
		{"\^:3f7f5077057f7e00 About Picotron", function() create_process("/system/apps/about.p64", 
			{prog="/system",window_attribs={workspace="current",  autoclose = true}}) end},

--[[
		{"\^:00093e5c1c141400 Log In", function() create_process("/system/apps/login.p64", 
			{window_attribs={workspace="current",  autoclose = true}}) end},
]]
		"---",
	}


	-- 2. SYSTEM MANAGEMENT

	-- Capture could go in Accessories though. Normally just used to discover keyboard shortcuts
	-- could also embed some settings right in pulldown (mute / volume, fullscreen)

	add(item, {"\^:307f3000067f0600 System Settings",	function() create_process("/system/apps/settings.p64", 
		{prog="/system",window_attribs={workspace="current", autoclose = true}}) end})

	add(item, {"\^:7f77777f777f0301 Show Messages", show_reported_error})

	if (stat(320) > 0) then
		add(item, {"\^:06ff81b5b181ff00 End Recording", function() _signal(19) end})
	else
		add(item, {"\^:06ff81b5b181ff00 Capture", function() create_process("/system/apps/capture.p64", 
			{window_attribs={workspace="current", autoclose = true}}) end})
	end


-- 3. QUICK LINKS (list-based version)

--[[

	Visual test: categorize carts using splore lists (/appdata/system/lists)
	Each list can be be pinned / unpinned from Picotron menu
		// ** hard to reduce to a categorisation, but at least user can refuse that (except that bbs carts should be tagged using essential categories)
		// ** need to be careful here -- making a category more visible is an invitation to make that type of thing (and to not make something else)
	Can tuck some menu items inside default accesories list: Capture, "files" (filenav), "bbs carts" (splore), Terminal
	use splore to manage lists -- can think of that part as a bookmark manager. (don't call them "bookmarks" though -- implies documents, not carts)
		// update: they are bookmarks :) each list is a list of references (including the dynamically generated bbs lists)

	verbs // reference: categorise by user activity
		accessories: explore
		games: play (with goal)
		system: administer
		tools: create
		toys: play (with no goal) -- can include desktop pets here

	demos:watch // don't need fast access, so can keep inside splore

	// snippets is important; perhaps should be separate, and/or a list in splore

	Accessories: cal filenav notebook snippets splore stickers terminal
	Games: [tiny windowed games]
	System: capture controls kbd logs (messages) podtree procmon themed
	Tools: code gui gfx map sfx
	Toys: alife pets sequin xyzine turtlefx

	Other lists show up in settings: Wallpapers, Screensavers, Themes, [Widgets]

]]

if (false) then
	add(item, "---")
	add(item, {"\^:00387f7f7f7f7f00 Accessories  \t  >", function() create_process("/system/apps/filenav.p64", {argv={"/"}}) end})
	add(item, {"\^:00387f7f7f7f7f00 Games        \t  >", function() create_process("/system/apps/filenav.p64", {argv={"/"}}) end})
--	add(item, {"\^:00387f7f7f7f7f00 Office       \t  >", function() create_process("/system/apps/filenav.p64", {argv={"/"}}) end})
--	add(item, {"\^:00387f7f7f7f7f00 System       \t  >", function() create_process("/system/apps/filenav.p64", {argv={"/"}}) end}) -- don't need? are accessories
	add(item, {"\^:00387f7f7f7f7f00 Tools        \t  >", function() create_process("/system/apps/filenav.p64", {argv={"/system/apps"}}) end})
	add(item, {"\^:00387f7f7f7f7f00 Toys         \t  >", function() create_process("/system/apps/filenav.p64", {argv={"/"}}) end})
	-- better to be "system"? and ambiguous with commandline utilities (/appdata/system/util)
--	add(item, {"\^:00387f7f7f7f7f00 Utilities    >", function() create_process("/system/apps/filenav.p64", {argv={"/"}}) end}) 

	-- feels wrong here -- should just be an accessory
--	add(item, {"\^:007f41417f613f00 BBS Carts", function() create_process("/system/apps/filenav.p64", {argv={"bbs://"}}) end})

end


	-- 3. QUICK LINKS

if (true) then
	add(item, "---")

-- tests
--	add(item, {"\^:00367f7f3e1c0800 Splore", function() create_process("/dev/splore/splore3.p64") end})		

--  nope: redundant / competes with quick links themselves. favourites should feel like a place inside splore. usually used for fullscreen things.
--	add(item, {"\^:00367f7f3e1c0800 Favourites        >", function() create_process("/system/apps/filenav.p64", {argv={"bbs://"}}) end})	

--  nope. just up to user if/how they want to store apps locally.
--	add(item, {"\^:00387f7f7f7f7f00 Apps", function() create_process("/system/apps/filenav.p64", {argv={"/apps"}}) end})

	-- not really crucial; usually have drive.loc on desktop, and could use accessories -> filenav.
	add(item, {"\^:00387f7f7f7f7f00 Files", function() create_process("/system/apps/filenav.p64", {argv={"/"}}) end})

	

--		add(item, {"\^:7e9f9dfd7a341800 BBS", function() create_process("/system/apps/filenav.p64", {argv={"bbs://"}}) end})

	-- bbs:// not available for exports (and hide for bbs player)
	if (stat(317) == 0) then
		-- to do: cartridges should launch splore (doubles as Favourites). Naming matches "Files" -- the objects you want to look through
		-- add(item, {"\^:007f41417f613f00 Cartridges", function() create_process("/desktop/splore.p64") end})
		-- can keep bbs://new/0 style browsing, but just a by-product of protocol generality
		-- (nice comment on bsky: feels like looking through shareware catalogue CDs)
		add(item, {"\^:007f41417f613f00 BBS Carts", function() create_process("/system/apps/filenav.p64", {argv={"bbs://"}}) end})
	end

	--[[
		-- test: should at least be able to browse /system (but not alter anything) while sandboxed
		add(item, {"\^:00387f7f7f7f7f00 Files (sandboxed)", function() create_process("/system/apps/filenav.p64", 
			{argv={"/"}, sandbox = "bbs", bbs_id = "_filenav"}) end})
	]]

	-- terminal // to do: {window_attribs={tabbed=key"ctrl"}} -- need to fix New Tab button, and possibly merge with pwc_output workspace (hybrid / tabbed at start?)
	-- add(item, {"\^:7f7d7b7d7f083e00 Terminal", function() create_process("/system/apps/terminal.lua", {window_attribs={tabbed=key"ctrl"}}) end})
	add(item, {"\^:7f7d7b7d7f083e00 Terminal", function() create_process("/system/apps/terminal.lua") end})

	-- later (using filenav intention); use load / save commands for now
	-- update: too much space! and can use context menu + ctrl+s. maybe: accessories > cartman?
	-- or could fold out of a single menu item
	--[[
		add(item, "---")
		add(item, "\^:00ff8181ffc17f00 Load Cartridge")
		add(item, "\^:00ff8181ffc17f00 Save Cartridge")
		add(item, "\^:00ff8181ffc17f00 Save Cartridge As")
		add(item, {"\^:1c367f7777361c00 Cartridge Info", function() create_process("/system/apps/about.p64") end})
	]]

end

	-- 4. REBOOT / SHUTDOWN

	add(item, "---")

	 -- pop up menu: [Shutdown] [Reboot] [Cancel] 
	 -- perhaps show unsaved changes 
	 -- (checkbox: "discard unsaved changes" ~ once checked, buttons clickable)


	add(item, {"\^:1c22494949221c00 Reboot", function()
		create_process("/system/misc/confirm.p64", 
			{prompt = "Discard Unsaved Changes?", title = "Reboot", window_attribs = {workspace="current", autoclose=true}})
	end})

	-- no need to shutdown on web 
	if (stat(318) == 0) then
		add(item, {"\^:082a494141221c00 Shutdown", function() 
			create_process("/system/misc/confirm.p64", 
				{prompt = "Discard Unsaved Changes?", title = "Shutdown", window_attribs = {workspace="current", autoclose=true}})
		end})
	end

	local pulldown = create_modal_gui():attach_pulldown{
		is_pictron_menu = true,
		x = 4, y = toolbar_y + 11,
		width = 122
	}

	pulldown.onclose = dismiss_modal

	for i=1,#item do
		if item[i] == "---" then
			pulldown:attach_pulldown_item{divider=true}
		elseif (type(item[i]) == "table") then
			pulldown:attach_pulldown_item{label=item[i][1], action = item[i][2]}
		else
			pulldown:attach_pulldown_item{label=item[i]}
		end
	end
	
	
end



