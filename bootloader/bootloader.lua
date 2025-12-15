--[[pod_format="raw",author="Astralsparv",created="2025-12-14 17:06:58",modified="2025-12-15 18:11:24",notes="",revision=11,title="Bootloader",version="1.1b"]]--[[
	Bootloader
	v1.1
	@astralsparv
]]

local distro=fetch("/distributions/active.txt")
local tboot=fetch("/distributions/bootinto.txt") or ""

if (#tboot>0) then
	distro=tboot
	store("/distributions/bootinto.txt","")
end

if (distro==nil) then
	distro="bios"
	store("/distributions/active.txt",distro)
end

distro="/distributions/"..distro

--how do i auto-rename boot.lua to custom_boot.lua??
--[[
mount("/ram/distribution/",distro)
flip()
if (fstat("/ram/distribution".."/boot.lua")) then --rename boot.lua to custom_boot.lua
	_printh("** boot.lua instead of custom_boot.lua, renaming")
	mv("/ram/distribution".."/boot.lua","/ram/distribution".."/custom_boot.lua") --rename
	flip()
	cp("/ram/distribution",distro) --overwrite original
	flip()
end

unmount("/ram/distribution")
flip()
]]--

mount("/system",distro) --replace system, this must not replace boot.lua, instead having custom_boot.lua 

--_printh("** Running Distribution: "..distro)

--run custom boot
local boot=fetch("/system/custom_boot.lua")
if (type(boot) != "string") then
	_printh("** could not read custom_boot.lua")
	_printh("** attempting to boot into bios.")
	store("/distributions/bootinto.txt","bios")
	_signal(34)
else
	local boot = load(boot)
	if (type(boot) != "function") then
		_printh("** could not load custom_boot.lua")
		_printh("** attempting to boot into bios.")
		store("/distributions/bootinto.txt","bios")
		_signal(34)
	else
		local ok, err = pcall(boot)
		if not ok then
			webWarning("custom_boot.lua error: " .. tostring(err))
		end
	end
end