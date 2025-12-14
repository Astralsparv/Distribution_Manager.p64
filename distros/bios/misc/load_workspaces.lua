-- create and populate initial workspaces

if stat(317) == 0 then 

	local function open_editor(prog, filename)
		create_process(prog or "/system/apps/code.p64", {
			argv={filename},
			fileview = {{location=filename, mode="RW"}}
		})
	end

	local prog_for_ext = fetch("/appdata/system/default_apps.pod")
	if (type(prog_for_ext) ~= "table") prog_for_ext = {}

	-- 0.2.0h: want these files to exist before autosaved. new_cart.p64 is stripped of metadata
	cp("/system/misc/new_cart.p64", "/ram/cart")

	-- matches .workspaces in /system/misc/net_cart.p64 // to do: could iterate and open.lua -- same as load
	open_editor(prog_for_ext.lua or "/system/apps/code.p64", "/ram/cart/main.lua")
	open_editor(prog_for_ext.gfx or "/system/apps/gfx.p64", "/ram/cart/gfx/0.gfx")
	open_editor(prog_for_ext.map or "/system/apps/map.p64", "/ram/cart/map/0.map")
	open_editor(prog_for_ext.sfx or "/system/apps/sfx.p64", "/ram/cart/sfx/0.sfx")


end

-- desktop, wallpaper, tooltray

local sdat = fetch"/appdata/system/settings.pod"
local wallpaper = (sdat and sdat.wallpaper) or "/system/wallpapers/pattern.p64"
if ((stat(317) & 0x1) ~= 0) wallpaper = nil -- placeholder: exports do not observe wallpaper to avoid exported runtime/cart mismatch in exp/shared
if (not fstat(wallpaper)) wallpaper = "/system/wallpapers/pattern.p64"

-- start in desktop workspace (so show_in_workspace = true)
create_process(wallpaper, {window_attribs = {workspace = "new", desktop_path = "/desktop", wallpaper=true, show_in_workspace=true}})

create_process("/system/misc/tooltray.p64", {window_attribs = {workspace = "tooltray", desktop_path = "/appdata/system/desktop2", wallpaper = true}})


if stat(317) == 0 then -- no fullscreen terminal for exports / bbs player
	create_process("/system/apps/terminal.lua",
		{
			window_attribs = {
				fullscreen = true,
				pwc_output = true,        -- run present working cartridge in this window
			}
		}
	)
end



-- 0.2.0h moved from /systemstartup.lua so that can guarantee desktop workspace exists before running /appdata/system/startup.lua

if stat(317) > 0 then 
	-- player startup
	-- mount /system and anything in /cart using fstat

	function fstat_all(path)
		local l = ls(path)
		if (l) then
			for i=1,#l do
				local k = fstat(path.."/"..l[i])
				if (k == "folder") fstat_all(path.."/"..l[i])
			end
		end
	end
	fstat_all("/system")
	fstat_all("/ram/expcart")

	-- no more cartridge mounting (exports are only allowed to load/run the carts they were exported with)
	
	if ((stat(317) & 0x3) == 0x3) then -- player that has embedded rom 
		-- printh("** sending signal 39: disabling mounting **")
		-- _signal(39) -- used to be sent from boot; ~ see mount_p64_path 
	end

	create_process("/system/misc/load_player.lua")

	-- (don't need custom startup.lua -- the exported / bbs cart itself can play that role)

else

	-- populate tooltray with widgets
	create_process("/system/misc/load_widgets.lua")

	-- userland startup
	
	if fstat("/appdata/system/startup.lua") then
		-- 0.2.0h wait for desktop to exist before running startup so that apps launched there can find their target (desktop) workspace
		-- ref: https://www.lexaloffle.com/bbs/?tid=144387#comments
		-- for now, 30 frames is a safe bet (in fact, currently need 0 frames delay) and makes no visual difference
		-- to do: react to a signal from wm? maybe overkill
		for i=1,30 do flip() end
		create_process("/appdata/system/startup.lua")
	end

end



