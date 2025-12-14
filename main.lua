--[[pod_format="raw",created="2025-12-14 14:52:01",modified="2025-12-14 16:47:49",revision=42]]
--load fonts

include "util.lua"

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
	gui:draw_all()
end