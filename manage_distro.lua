--[[pod_format="raw",created="2025-12-14 16:47:55",modified="2025-12-14 17:11:13",revision=22]]
gui=create_gui{}

local x,y=2,20

local w,h=text(gui,{
	x=x,
	y=y,
	label="\^w\^t\014Manage your distributions",
})
y+=h+5

local w,h=text(gui,{
	x=x,
	y=y,
	label="\^w\^t\014Manage your bootloader",
})
y+=h+5

local w,h=button(gui,{
	x=x,
	y=y,
	label="Check bootloader for new versions",
	tap=function()
		notify("Checking connection")
		flip()
		if (not internet()) then
			notify("You need the internet for this.")
			return
		end
		notify("You are connected to the internet!")
		flip()
		
		notify("Fetching bootloader")
		flip()
		store("/ram/boot.lua",fetch("https://raw.githubusercontent.com/Astralsparv/Distribution_Manager.p64/refs/heads/main/bootloader/boot.lua"))
		local meta=fetch_metadata("/ram/boot.lua")
		if (meta.version!=bootloader_version) then
			notify("Bootloader is outdated. Please download the latest bootloader")
		else
			notify("Bootloader is at the latest version.")
		end
	end
})
y+=h+5

local w,h=button(gui,{
	x=x,
	y=y,
	label="Download latest bootloader",
	tap=function()
		notify("Checking connection")
		flip()
		if (not internet()) then
			notify("You need the internet for this.")
			return
		end
		notify("You are connected to the internet!")
		flip()
		
		notify("Installing bootloader")
		flip()
		store("/distributions/bootloader.lua",fetch("https://raw.githubusercontent.com/Astralsparv/Distribution_Manager.p64/refs/heads/main/bootloader/boot.lua"))
		
		notify("Installed bootloader - reboot for effects to take place")
		flip()
	end
})
y+=h