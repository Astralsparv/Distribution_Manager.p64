--[[pod_format="raw",created="2024-03-21 06:13:04",modified="2024-03-21 06:13:04",revision=0]]
--[[

	resources.lua

	on program boot, load everything in gfx/[0..9].gfx

	also: 0.map, 0.sfx

]]

local completed = false

local function _autoload_resources()

	-- save all open files to /ram/cart when running pwc (same pattern as util/save.lua)
	-- 0.2.1c: also look for external changes on host ~ PICO-8 style workflow when editing the .p64 file directly
	if (env().corun_program == "/ram/cart/main.lua") then
		on_event("save_working_cart_files_completed",function(msg)
			completed = true
		end)

		-- wait for all save messages to come back via wm, for up to 120 frames
		send_message(3, {event="save_working_cart_files", notify_on_complete=pid()})
		for i=1,120 do if (not completed) then flip() end end
		
		-- look for external changes (dupe from util/info.lua)
		found_external_changes = false
		local pwc = fetch("/ram/system/pwc.pod")
		cp(pwc, "/ram/system/pwcv1") -- ** subtle: doesn't read from the already modifed mount, because save_working_cart_files re-mounts for this purpose **

		function compare_path(path)
			local fn0 = "/ram/system/pwcv0"..path
			local fn1 = "/ram/system/pwcv1"..path
			if fstat(fn0) == "folder" then
				local l = ls(fn1) -- list fn1 so that can manually add files to .p64 in a text editor on host 
				if (l) then
					for i=1,#l do compare_path(path.."/"..l[i]) end
				end
			elseif path == "label.qoi" then
				-- ignore
			else
				local s0 = fetch(fn0, {raw_str=true})
				local s1 = fetch(fn1, {raw_str=true})
				if (s0 and s0 ~= s1) cp(fn1, "/ram/cart/"..path) found_external_changes = true 
			end
		end

		compare_path("")

		if (found_external_changes) then 
			notify("\^:007f41417f613f00 loaded external changes") 
			cp("/ram/system/pwcv1", "/ram/system/pwcv0")
		end

	end
	
	local gfx_files = ls("gfx") or {}

	for i=1,#gfx_files do
		local fn=gfx_files[i]
		local num = tonum(string.sub(fn,1,2)) or tonum(string.sub(fn,1,1))
		fn = "gfx/"..fn
		if (num and num >= 0 and num <= 31) then

			local gfx_dat = fetch(fn)
			if (type(gfx_dat) == "userdata") then

				-- item is a single spritesheet assumed to be 16x16 even tiles
				-- to do: make loading pngs easier? (currently always load as raw i32 userdata)
				
				local w,h = gfx_dat:width(), gfx_dat:height()
				w = w // 16
				h = h // 16

				-- load sprite bank from gfx_dat
				for y=0,15 do
					for x=0,15 do
						local sprite = userdata("u8",w,h)
						blit(gfx_dat, sprite, x*w, y*h, 0, 0, w, h)
						set_spr(x + y * 16 + num * 256, sprite, 0); -- no flags
					end
				end


			elseif (type(gfx_dat) == "table" and gfx_dat[0] and gfx_dat[0].bmp) then

--				printh("autoloading "..fn)

				-- format saved by sprite editor
				-- sprite flags are written to 0xc000 + index

				for i=0,#gfx_dat do
					set_spr(num * 256 + i, gfx_dat[i].bmp, gfx_dat[i].flags or 0)
				end
			end

		end
	end


	-- load default map layer if there is one (for PICO-8 style map())
	-- map0.map for dev legacy -- should use 0.map
	local mm = fetch("map/0.map") or fetch("map/map0.map")

	if (mm) then
		-- dev legacy: layers are stored in a sub-table. to do: can delete this later
		if (mm.layer and mm.layer[0] and mm.layer[0].bmp) memmap(mm.layer[0].bmp, 0x100000)
		
		-- set current working map
		if (mm[1] and mm[1].bmp) memmap(mm[1].bmp, 0x100000)
	end

	-- set starting tile size to size of sprite 0 (has authority; observed by map editor too)
	if (get_spr(0)) then
		local w, h = get_spr():attribs()
		poke(0x550e, w, h)
	else
		poke(0x550e, 16, 16)
	end

	-- load default sound bank (256k at 0x30000)
	local ss = fetch("sfx/0.sfx")
	if (type(ss) == "userdata") ss:poke(0x30000)
	

end


-- always autoload resources (even for a .lua file -- might be running main.lua from commandline)

_autoload_resources()
	

