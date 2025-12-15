--[[pod_format="raw",created="2025-12-14 14:52:01",modified="2025-12-14 17:47:45",revision=67]]
window{pauseable=false}

include "util.lua"

if (fstat("/distributions/bootloader.lua")) then
	bootloader_version=fetch_metadata("/distributions/bootloader.lua").version
end

_,system_version=stat(5)

system_version=string.gsub(system_version,"%.","_")
fetch("fonts/minie.font"):poke(0x5600)

include "gui.lua"

--boot.lua does not exist in a custom distribution
distributionSystemInstalled=(fstat("/system/boot.lua")==nil)
--distributionSystemInstalled=false

if (not distributionSystemInstalled) then
	include "install_distro.lua"
else
	include "manage_distro.lua"
end

function _init()
	
end

function _update()
	gui:update_all()
end

function _draw()
	cls(3)
	print("\^w\^tDistribution Manager",2,2,7)
	print("minie font by @thelxinoe5",358,262,7)
	gui:draw_all()
end