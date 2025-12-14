--[[pod_format="raw",created="2025-12-14 16:47:55",modified="2025-12-14 16:50:48",revision=6]]
gui=create_gui{}

local x,y=2,20

local w,h=text(gui,{
	x=x,
	y=y,
	label="\^w\^t\014Manage your distributions",
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
		local meta=fetch_metadata("")
	end
})
y+=h