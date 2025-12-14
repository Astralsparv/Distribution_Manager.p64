--bios-like thing

--_printh("** startup")

--bare minimum
create_process("/system/pm/pm.lua")
create_process("/system/wm/wm.lua")

for i=1, 50 do flip() end --initialise pm & wm

--bios cart

if (fstat("/system/bios.p64")) then
	--_printh("** BIOS booting")
	create_process("/system/bios.p64", {window_attribs={fullscreen=true}})

else
	_printh("** BIOS runtime not found!")
end