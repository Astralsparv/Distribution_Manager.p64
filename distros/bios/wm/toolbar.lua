--[[

	toolbar.lua

	includeable version -- run in same lua state as window manager
		// implementing as a separate process causes too much complex, fragile interaction between wm <--> toolbar

]]

do -- locals don't conflict with window manager


local toolbar = {}


local picotron_icon = userdata("[gfx]08087777770077777770000070707770777070700000777777700777777000000000[/gfx]")

local minimal = true

local gui = create_gui()

local char_w = peek(0x5600)

local tabs_container

local function has_window_menu_in_toolbar()

--	if (get_workspace().child and #get_workspace().child == 0) return false -- empty workspace
--	return get_workspace().style == "tabbed"

--[[
	-- include app menu on desktop (is always filenav menu)
	-- update: commented for now; feels messy and unclear
	-- and maybe right menu click on files would be nicer? 
	return get_workspace().style ~= "fullscreen"
]]
	-- need app menu iff have one or more tabs
	local tabs = get_workspace_tabs()
	if (tabs and #tabs > 0) return true

end


function make_window_button(parent, label, x, y, width, height, win)
	parent = parent or gui
	local b = {label=label, x=x, y=y, width=width, height=height, cursor = "pointer"}

	b.col = 2

	function b:drag(event)
		return true -- stop parent from being draggable
	end

	function b:draw(event)
		local yy = (event.mb > 0 and event.has_pointer) and 1 or 0

		local col = theme(parent.col_k or "toolbar_item")
		for y=yy+2,yy+6,2 do
			line(2,y,8,y,col)
		end

	end

	function b:update()
		-- make space for tiny window
		if (self.parent.width < 32) self.x = 0
	end

	function b:tap(event)
		-- if deskop, always applies to the filenav overlay
		toggle_app_menu(self.sx, self.sy + self.height, win)
	end

	return parent:attach(b)
end



local function make_picotron_button(parent, label, x, y, width, height)
	parent = parent or gui
	local b = {label=label, x=x, y=y, width=width, height=height, cursor = "pointer"}

	b.col = 2

	function b:drag(event)
		return true -- stop parent from being draggable
	end


	function b:draw(event)
		local yy = (event.mb > 0 and event.has_pointer) and 2 or 1

		pal(7, theme("toolbar_item"))
			spr(picotron_icon, 1, yy)
		pal(7,7)

	end

	function b:tap(event)
		toggle_picotron_menu()
	end

	return parent:attach(b)
end


local function make_new_tab_button(parent, label, x, y, w, h)

	local tt = parent:attach{x=x, y=y, width=w, height=h, label=label, cursor = "pointer"}

	function tt:drag(event)
		return true -- stop parent from being draggable
	end

	function tt:draw(event)

		local bg_col = theme("toolbar_item") 
		local x = 1 -- self.sx 
		local y = 0 -- self.sy
		if (event.has_pointer and event.mb > 0) y+=1

		-- to do: should just draw tab sprites and recolour them
		rectfill(x,y,x+w-2,y+h-1, bg_col)
		pset(x,y,theme"toolbar_back")
		pset(x+w-2,y,theme"toolbar_back")
		line(0,y,0,y+h-1, theme"toolbar_back")

		local str = self.label
		local text_w = print(str, 0, -1000)
		print(str, x + self.width/2 - text_w\2, y+1, theme"toolbar_back")

	end



	function tt:tap(event)

		-- create new file in same folder as [active window location]

		local awin = get_active_window()
		local loc = awin and awin.location

		local start_path = (loc and loc:dirname()) or get_workspace().last_dir or "/ram/cart"

		-- 0.2.1c: make sure the path exists (e.g. add /ram/cart/map)
		if (start_path:sub(1,10) == "/ram/cart/") mkdir(start_path)

		create_process("/system/apps/filenav.p64", 
		{
			intention = "new_tab",
			path = start_path,
			use_ext = (loc and loc:ext()) or get_workspace().last_ext or ".txt",
			window_attribs = {workspace = "current",autoclose=true},
			open_with = get_workspace().prog,
		})

	end


	return tt

end


-- tab is functionally the same as a window frame
-- window holds any attributes of interest to drawing / updating a tab
local function make_tab_button(parent, win, x, y, w, h)

	win = win or {title="tab_error"}

--[[
	local str = win.title or "_"	
	local text_w = print(str, 0, -1000)
	printh("tab title: "..str.."   width:"..text_w)
	-- to do: width function of title (nice, but complicates drag and switch
	w = text_w + 12
]]

	local tt = parent:attach{win = win, x=x, y=y, width=w, height=h, cursor = "pointer"}

--	
--[[
	-- to do: update variable width tabs / regenerate gui when tab title changes
	function tt:update()

		local str = self.win.title or "_"	
		local text_w = print(str, 0, -1000)
--		printh("tab title: "..str.."   width:"..text_w)
		self.width = text_w + 12
	end
]]


	
	function tt:draw(event)

		-- to do: tool can decide what background colour is for active tab
		-- same as selected workspace colour
		local bg_col = self.win.is_active and theme("toolbar_selected") or theme("toolbar_item") -- active tab is bright
--		local bg_col = self.win.is_active and 1 or 14 -- tried to get tab to match code editor background -- confusing.

		local textcol = theme"toolbar_back"

		-- window is editing the same file: draw inverted to make it obvious something is going on
		local win2 = get_active_window()
		local dupe = win2 ~= win and type(win.location) == "string" and type(win2.location) == "string" and win.location:path() == win2.location:path()

		if dupe then
			bg_col = theme"toolbar_back"
			textcol = theme"toolbar_item"
		end

		local x = 1 -- self.sx -- now relative to gui position
		local y = 0 -- self.sy
		
		if (event.has_pointer and event.mb > 0) y+=1

		rrectfill(x,y,w-1,h+1, 1,bg_col)
		line(0,y,0,y+h-1, theme"toolbar_back") -- gap at x=0 to separate from left neighbour

		if dupe then
			rrect(x,y,w-1,h+1, 1,textcol)
			y += 1
		end



		local title1 = win.title or "-"
		if (win.unsaved_changes and title1[1] ~= "*") title1 = "*"..title1

		-- temp debug: show position in gui element list
		--[[	
		local index = -1
		for i=1,#self.parent.child do
			if (self.parent.child[i] == self) index = i
		end
		title1 = index..title1
		]]

		
		local text_w = print(title1, 0, -1000)
		--local text_w = #str * char_w
		--[[
		if (text_w > self.width and str:ext()) then
			title1 = sub(title1,1,-(2+#title1:ext()))
			text_w = print(title1, 0, -1000)
		end
		]]
		print(title1, x + max(3, self.width/2-text_w\2), y+1, textcol)

		

	end

	function tt:tap(event)

		if (event.last_mb == 1) then -- need to use last_mb for tap because mb is always 0 by this stage

			send_message(3, {event="bring_window_to_front", proc_id = self.win.proc_id})		
			self:bring_to_front()
			--update_tab_widths(self)
		else
			-- right mouse click to bring up app menu
			toggle_app_menu(self.sx, self.sy + self.height, self.win)
		end

		-- variable widthed tabs. messy
		--[[
			-- assume bring_window_to_front will succeed. remove 1 glitch frame
			get_active_window().is_active = false
			tt.win.is_active = true 

			generate_toolbar_gui() -- need if window tabs change size according to status
		]]
	end

	function tt:drag(event)

		if (event.mx < 0 or event.mx >= self.width) then

			local tab = get_workspace_tabs()
			local index = nil
			for i=1,#tab do
				if (tab[i] == self.win) index = i
			end

			-- ** unnecessarily complex
			-- ** to do: re-work how tab ordering is stored
			--    perhaps always just operate on x,y and position in list of gui elements is immaterial

			local index0,index1,index2

			for i=1,#self.parent.child do
				if (self.parent.child[i].win == tab[index])   index0 = i
				if (self.parent.child[i].win == tab[index-1]) index1 = i
				if (self.parent.child[i].win == tab[index+1]) index2 = i
			end
			
			if event.mx < 0 and index1 and tab[index-1] and tab[index-1].label ~= "+" then
				-- switch left
				tab[index], tab[index-1] = tab[index-1], tab[index]
				self.parent.child[index0].x,  self.parent.child[index1].x  = self.parent.child[index1].x,  self.parent.child[index0].x  
				self.parent.child[index0].sx, self.parent.child[index1].sx = self.parent.child[index1].sx, self.parent.child[index0].sx
			end

			if event.mx >= self.width and index2 and tab[index+1] and tab[index+1].label ~= "+" then
				-- switch right
				tab[index], tab[index+1] = tab[index+1], tab[index]
				self.parent.child[index0].x,  self.parent.child[index2].x  = self.parent.child[index2].x,  self.parent.child[index0].x  
				self.parent.child[index0].sx, self.parent.child[index2].sx = self.parent.child[index2].sx, self.parent.child[index0].sx
			end

		end

		return true -- can't also drag toolbar when dragging tab

	end

	return tt
end


-- deleteme -- too messy!
local function make_dock_button(parent, x, y, width, height)

	parent = parent or gui
	local b = {index=index, label=label, x=x, y=y, width=width, height=height, cursor = "pointer"}

	b.icon0 = userdata"[gfx]08080000000000000000000700000077700007777700077777000000000000000000[/gfx]"
	b.icon1 = userdata"[gfx]08080000000000000000000000000007700000077000000000000000000000000000[/gfx]"

	function b:draw(event)
		local ws = get_workspace()
		local yy = (event.mb > 0 and event.has_pointer) and 1 or 0
		pal(7, 13)
		spr(ws.show_toolbar and b.icon1 or b.icon0, 0, yy + 1)
		pal(7,7)
		--rectfill(0,0,4,4,8)
	end

	function b:tap()
		local ws = get_workspace()
		ws.show_toolbar = not ws.show_toolbar
	end


	return parent:attach(b)
end


local function make_workspace_button(index, parent, label, x, y, width, height)
	parent = parent or gui
	local b = {index=index, label=label, x=x, y=y, width=width, height=height, cursor = "pointer"}

	b.icon = get_workspace_icon(index)

	function b:drag(event)
		return true -- stop parent from being draggable
	end


	function b:draw(event)
		local xx = 0 -- b.sx
		local yy = 0 -- b.sy
		if (event.mb > 0 and event.has_pointer) then 
			yy = yy + 1
		elseif get_workspace_index() == b.index and key("lalt") and (key("left") or key("right")) then
			-- show button down when used alt+l/r to switch workspace
			yy = yy + 1
		elseif get_workspace_index() == b.index then
			--yy = yy + 1
		end

		pal(7, get_workspace_index() == b.index and theme("toolbar_selected") or theme("toolbar_item"))
		
		-- live update
		local ws = get_workspace()
		if (get_workspace_index() == b.index) b.icon = ws.icon

		spr(b.icon, xx + 4, yy + 1)

		pal(7,7)

	end

	-- later: can drag workspace buttons around; so use :tap for activating
	function b:tap(event)
		if (event.last_mb == 1) then
			set_workspace(b.index)
		else
			-- printh(pod(get_workspace(b.index).attribs))
			toggle_workspace_menu(min(370, self.sx), self.sy + self.height, b.index)
		end
	end
	
	return parent:attach(b)
end



local last_num = nil
local last_tabs = nil

--function update_toolbar()

local function gui_update()

	
	-- safety: make sure don't need to update gui because of changing tabs
	-- (but better to do proactively from wm.lua to avoid being one frame behind)
	if (last_tabs ~= get_workspace_tabs() or last_num ~= #get_workspace_tabs()) then
		generate_toolbar_gui()
		last_tabs = get_workspace_tabs()
		if (last_tabs) then
			last_num  = #get_workspace_tabs()
		end
	end

end

--[[
to do: dynamic tab widths
function update_tab_widths(awin)
	local xx = 0

	local tabs = tabs_container.child

	for i = 1, #tabs do
		local tt = tabs[i]
		tt.x = xx
		tt.sx = tt.parent.sx + tt.x -- update now
		tt.width = tt == awin and 64 or 48
		if (tt.label == "+") tt.width=20
		xx += tt.width
	end
end
]]

function generate_toolbar_gui()

--	printh("-- generating toolbar gui --")
	gui = create_gui{
		x=0,y=0,width=480,height=11,
		cursor="grab",

		draw = function(self)
			rectfill(0, 0, self.width, self.height, theme"toolbar_back")
		end,
		update = gui_update,

		drag = function(self,e)
			-- to do: check if is active element; can remove all the children's dummy :drag() callbacks
			-- is this the right pattern for toolbar style buttons that have a container that does something?
			send_message(3, {event="drag_toolbar", dy=e.dy})
		end
	}

	local workspace_w = min(16, 116 / get_num_workspaces())
	local x = 476 - get_num_workspaces()*workspace_w

	for i=1,get_num_workspaces() do

--		if (i == get_num_workspaces()) then x = x + 3 end -- temp formatting hack for twitter code edits code gif
		make_workspace_button(i, gui, "wbtn"..tostr(i),x,1,16,10)
		x = x + workspace_w

	end

	-- experimental: docking button
--	make_dock_button(gui, 480-12, 1, 10, 10)

	local tab = get_workspace_tabs()
	local tab_width = 50 -- overwritten below
	local tabs_container_x = has_window_menu_in_toolbar() and 35 or 20
	local xx = 0

	if (tab) then

		-- container

		tabs_container = gui:attach{
			x=tabs_container_x, y=0, width=320, height=gui.height,cursor="grab",

			drag = function(self,msg)
				--printh("drag container "..msg.dy)
				gui.y += msg.dy
			end,

			draw = function()
				-- for cursor // to do: shouldn't need draw function
			end

		}

		for i=1,#tab do
			if tab[i] then
				if not tab[i].closing and not tab[i].hidden then

					tab_width   = min(64, 308 \ #tab) -- 0.2.0e: minimum width a little wider (was 56). np if squash up when many

					local tt = make_tab_button(tabs_container, tab[i], xx, 1, tab_width-2, 10)
					tt.index = i
					xx += tt.width
				end
			end
		end

		--update_tab_widths(get_active_window())
		

		-- new tab: default to an untitled document

		if (get_workspace().style == "tabbed") then
			
			make_new_tab_button(tabs_container, "+", xx, 1, 17, 10)

		end

	end

	make_picotron_button(gui,"picotron menu", 4,1, 10,10)


	if has_window_menu_in_toolbar() then
		make_window_button(gui, "app menu", 18, 1, 10,10, get_window_by_proc_id(get_workspace().desktop_filenav_proc_id))
	end
	
	return gui

end

function toolbar_init()
	return generate_toolbar_gui()
end



end
