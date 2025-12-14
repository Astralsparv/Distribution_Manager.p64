--[[pod_format="raw",author="Astralsparv",created="2025-12-14 16:27:05",modified="2025-12-14 17:07:38",notes="",revision=14,title="OS Bootloader",version="1.1"]]
--load bootloader from /distributions/boot.lua
--let's distro manager update it

local boot=fetch("/distributions/bootloader.lua")
if (type(boot) != "string") then
	_printh("** could not read /distributions/bootloader.lua")
	_printh("** remove /system and /distributions.")
else
	local boot = load(boot)
	if (type(boot) != "function") then
		_printh("** could not load /distributions/bootloader.lua")
		_printh("** remove /system and /distributions.")
	else
		boot()
	end
end