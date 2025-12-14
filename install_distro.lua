--[[pod_format="raw",created="2025-12-14 15:05:33",modified="2025-12-14 17:09:29",revision=133]]
gui=create_gui{}

local x,y=2,20

local w,h=text(gui,{
	x=x,
	y=y,
	label="\^w\^t\014Install the distribution system",
})
y+=h+5

local w,h=text(gui,{
	x=x,
	y=y,
	label="\^w\^t\014Terminal Commands",
	fg=6
})
y+=h+5

local w,h,bios=checkbox(gui,{
	x=x,
	y=y,
	label="bios command"
})
y+=h

local w,h,boot_distro=checkbox(gui,{
	x=x,
	y=y,
	label="boot_distro command"
})
y+=h

local w,h=button(gui,{
	x=x,
	y=y,
	label="Install Distribution System",
	tap=function()
--		notify("Checking connection")
--		flip()
--		if (not internet()) then
--			notify("You need the internet for this.")
--			return
--		end
--		notify("You are connected to the internet!")
--		flip()
		notify("Installing utilities")
		flip()
		if (boot_distro.active) then
			notify("Installing boot_distro util")
			cp("util/boot_distro.lua","/system/util/boot_distro.lua")
			flip()
		end
		if (bios.active) then
			notify("Installing bios util")
			cp("util/bios.lua","/system/util/bios.lua")
			flip()
		end
		notify("Patching your boot.lua")
		mv("/system/boot.lua","/system/custom_boot.lua")
		flip()
		
		notify("Creating distributions folder")
		mkdir("/distributions")
		flip()
		
		notify("Downloading BIOS distribution")
--		need online downloads for distributions!
--		downloadDistribution("https://github.com/Astralsparv/bios-picotron-distribution","bios")
		downloadDistribution("distros/bios","bios")
		
		flip()
		notify("Setting active distribution to your picotron system")
		store("/distributions/active.txt","picotron"..system_version)
		
		flip()
		notify("Setting to boot into BIOS")
		store("/distributions/bootinto.txt","bios")
		
		flip()
		notify("Storing Picotron distribution ("..system_version..")")
		cp("/system","/distributions/picotron"..system_version)
		
		flip()
		notify("Creating the bootloader: Persisting /system")
		cp("/system","/system.")
		
		flip()
		notify("Creating the bootloader: Deleting /system")
		rm("/system")
		
		flip()
		notify("Creating the bootloader: Creating /system")
		mkdir("/system")
		
		flip()
		notify("Creating the bootloader: Writing bootloader's loader")
		cp("bootloader/boot.lua","/system/boot.lua")
		
		flip()
		notify("Creating the bootloader: Writing bootloader")
		cp("bootloader/bootloader.lua","/distributions/bootloader.lua")
		
		flip()
		notify("Restarting your system.")
		for i=1, 20 do flip() end
		
		send_message(2,{event="reboot"})
	end
})
y+=h