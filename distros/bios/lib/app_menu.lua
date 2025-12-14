--[[

	menuitem{
		id = 3,                   -- unique identifier. integer ids are used to sort items (otherwise in order added)
		label = "Foo",            -- user-facing label
		shortcut = "CTRL-O",      -- drawn right justified in menu
		greyed = false,           -- greyed out item (use for ---)
		action = function(b) end  -- callback on select -- b is the button pressed (left / right)
	}

]]

local _menu = {}
local _send_message = _send_message
local _pid = pid
local _signal = _signal

local function eval_menuitem(item)
	local item1 = {}
	for k,v in pairs(item) do
		if (k == "label" and type(v) == "function") v = v() -- label can be a function
		item1[k] = v
	end
	return item1
end

function menuitem(m, a, b)

	_menu = _menu or {}

	-- clear
	if (not m) then
		_menu = {}
		_send_message(3, {event = "app_menu_item", clear = true})
		return
	end

	-- legacy pico-8 calling format
	if (a) then
		m = {
			id = m, -- integer position
			label = a,
			action = b
		}
	end

	-- add divider
	if (m == "---") m = {divider = true}
	if m.divider then
		_send_message(3, {event = "app_menu_item", attribs = m})
		return
	end

	if (not _menu[m.id]) then
		_menu[m.id] = m
	elseif not m.label then
		-- remove
		_menu[m.id] = nil
	else
		-- update items
		for k,v in pairs(m) do
			_menu[m.id][k] = v
		end
	end

	-- resend whole menu item state (wm doesn't need to handle partial changes)
	-- also handles deletion

--	_send_message(3, {event = "app_menu_item", attribs = _menu[m.id] or m})
	_send_message(3, {event = "app_menu_item", attribs = eval_menuitem(_menu[m.id] or m)})

end


-- default hooks
on_event("menu_action", function(msg)
	local item = _menu[msg.id]
	if (item and item.action) then
		local res = item.action(msg.b)
		-- to do: clear keys / buttons here. could be a signal

		-- resend incase label changed
		_send_message(3, {event = "app_menu_item", attribs = eval_menuitem(item)})
		

		if (not res) then
			-- close the menu
			--send_message(_pid(), {event = "unpause"})
			_signal(23) -- block all buttons until released
			send_message(3, {event = "close_pause_menu"}) -- only applies to fullscreen apps
		end
	end
end)

-- wm asks for labels to be updated each time bringing up the pause menu
-- i.e. re-evaluate the ones that are functions
on_event("update_menu_labels", function(msg)
	for i=1,#_menu do
		if _menu[i] and type(_menu[i].label) == "function" then
			_send_message(3, {event = "app_menu_item", attribs = eval_menuitem(_menu[i])})
		end
	end
end)




