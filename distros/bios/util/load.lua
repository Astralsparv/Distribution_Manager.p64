

if env().print_to_proc_id then -- to do: -i or env().ignore_unsaved_changes
	local pwc_unsaved_changes = send_message(3, {event="pwc_unsaved_changes"}, true).result

	if (pwc_unsaved_changes) then
		local res = input("\fediscard unsaved changes? \f7[y/n] ", 0x2)
		if (res ~= "y" and res ~= "Y") exit()
	end
end


cd(env().path)

local argv = env().argv
if (#argv < 1) then
	print("\f6usage: load filename -- can be file or directory")
	print("-u to load unsandboxed")
	exit(1)
end

local filename = nil
local unsandbox = false

for i=1,#argv do
	if (argv[i][1] == "-") then
		if (argv[i] == "-u") unsandbox = true
	elseif not filename then
		filename = argv[i]
	end
end


-- load an earlier version of cartridge via anywhen
-- when not explicitly using the anywhen protocol
-- 0.2.0i: commented (deleteme); confusing to have 2 different format
-- and can use filenav foo.p64/@ now to browse versions (easier than typing in times)
-- future: anywhen time browser with visual calendar and utf->local conversion
--[[
if (not filename:prot() not filename:find("/@") and filename:find("@")) then

	filename, when = unpack(split(filename, "@", false))
	filename = fullpath(filename)

	-- expand when into full local time string
	
	local padding = "0000-01-01 00:00:00"
	
	if (when:find(":") == 3) -- 0.2.0i: fixed -- was "(when:find(":"))" breaking all loads with time part specified ._.
	then
		-- time at start: prefix with date
		local now_local = date("%Y-%m-%d %H:%M:%S")
		when = now_local:sub(1,11)..when
	end

	-- pad remaining time
	when ..= padding:sub(#when + 1)

	-- convert to UTC
	when = date(nil, when, stat(87))

	--...

	local loc = "anywhen:/"..filename.."@"..when
	print("fetching: "..loc)

	local a = fetch(loc)
	if (type(a) == "string") then
		-- switcheroony
		filename = "/ram/anywhen_temp."..filename:ext()

--		print("opening as "..filename)
		rm(filename) -- deleteme: relic of debugging store() over existing file
		store(filename, a)
	else
		print("could not locate")
		exit(0)
	end

end
]]

if (not filename:prot(true) and not filename:find("/@") and filename:find("@")) then

	print("this format is no longer supported", 14)
	print("try: \f7open "..split(filename,"@")[1].."/@ \f6instead", 6)
	exit()
end


-- bbs cart: "load #foo" is shorthand for "load bbs://foo.p64"

if (filename:sub(1,1) == "#") then
	filename = "bbs://"..filename:sub(2)..".p64"
end


attrib = fstat(filename)
if (attrib ~= "folder") then
	-- doesn't exist or a file --> try with .p64 extension
	filename = filename..".p64"
	if (fstat(filename) ~= "folder") then
		print("could not load")
		exit(1)
	end
end


-- remove currently loaded cartridge
rm("/ram/cart")

-- create new one
local result = cp(filename, "/ram/cart")
if (result) then
	print(result)
	exit(1)
end

-- keep a copy for comparing external changes
cp("/ram/cart", "/ram/system/pwcv0")

-- set current project filename

store("/ram/system/pwc.pod", fullpath(filename))


-- tell window manager to clear out all workspaces
send_message(3, {event="clear_project_workspaces"})
send_message(3, {event="reset_pwc_unsaved_changes"})


meta = fetch_metadata("/ram/cart")

if (meta and type(meta.runtime) == "number" and meta.runtime > stat(5)) then
	print("** warning: this cart was created using a future version of picotron.")
	print("** some functionality might be broken or behave differently.")
	print("** please upgrade to the latest version of picotron.")
end


if (meta) dat = meta.workspaces

--[[ deleteme
	dat = fetch("/ram/cart".."/.workspaces.pod")
	if (not dat) printh("*** could not find\n")
]]

-- legacy location;  to do: deleteme
if (not dat) then
	dat = fetch("/ram/cart/_meta/workspaces.pod")
	if (dat) printh("** fixme: using legacy _meta/workspaces.pod")
end

-- legacy location;  to do: deleteme
if (not dat) then
	dat = fetch("/ram/cart/workspaces.pod")
	if (dat) printh("** fixme: found /workspaces.pod")
end

-- at the very least, open main.lua if it exists
if ((type(dat) ~= "table" or #dat == 0) and fstat("/ram/cart/main.lua")) then
	dat = {{location="main.lua"}} -- relative to /ram/cart/
end

if (type(dat) == "table") then

	-- open in background (don't show in workspace)
	local edit_argv = {"-b"}

	for i=1,#dat do

		local ti = dat[i]
		local location = ti.location or ti.cproj_file -- cproj_file is dev legacy
		if (location) then
			--print("/ram/cart/"..location)
			add(edit_argv, "/ram/cart/"..location)
		end
	end

	-- open all at once
	create_process("/system/util/open.lua",
		{
			argv = edit_argv,
			pwd = "/ram/cart"
		}
	)

end

print("\f6loaded "..filename.." into /ram/cart")

if (filename:prot() == "bbs") then
	local bbs_id = split(filename:basename(),"-.",false)[1]

	if (unsandbox) then
		print("\fe[unsandboxed] \f6cart has R/W access to picotron drive /*")
		store_metadata("/ram/cart", {sandbox = false})
	else
		print("\fcsandboxed to /appdata/bbs/"..bbs_id)
		print("\fd// to load unsandboxed: load #"..split(filename:basename(),".",false)[1].." -u")  -- -u at end so that easy to add
	end
--	print("\fesandboxed to /appdata/bbs/"..split(filename:basename(),"-.",false)[1].." \fd-- to unsandbox, type: about")
end

if (not env().print_to_proc_id) then
	local m = "\^:007f41417f613f00 loaded cartridge: "..filename:basename()
	notify(m)
end





