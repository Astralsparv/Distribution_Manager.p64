-- info.lua: show info about the present working cartridge (/ram/cart)

-- (dupe from save.lua) save all files and metadata
local completed = false
local num_files = 0
on_event("save_working_cart_files_completed",function(msg)
	completed = true
	num_files = msg.num_files -- num files saved because editors were open, not total files in the cart
end)
-- save all files and metadata (note: normally already saved as happens in wrangler on lost_focus)
-- wait for all save messages to come back via wm, for up to 120 frames
send_message(3, {event="save_working_cart_files", notify_on_complete=pid()})
for i=1,120 do if (not completed) then flip() end end

send_message(3, {event="save_open_locations_metadata"}, true)

---

local pwc = fetch("/ram/system/pwc.pod")

mkdir("/ram/temp") -- to do: should be allowed to assume this exists?
cp("/ram/cart", "/ram/temp/cartsize.p64.rom")
kind, size = fstat("/ram/temp/cartsize.p64.rom")


print("\fecurrent cartridge: "..pwc)

-- size jumps around because timestamp in metadata changes
if (size) then
	local p = (size * 1000 / (256*1024))\1 / 10
	print("compressed rom: "..size.." bytes \fd("..p.."%)")
end

-- blocking
local pwc_unsaved_changes = send_message(3, {event="pwc_unsaved_changes"}, true).result

if (pwc_unsaved_changes) then
	print("\128 cartridge has unsaved changes",9)
else
--	exit() -- nothing more to do
end

----------------------------------------------------------------------------------------------------------------------------------------------------------------
-- show external changes (same happens on run in /system/lib/resources.lua)

found_external_changes = false
cp(pwc, "/ram/system/pwcv1") -- ** subtle: doesn't read from the already modifed mount, because save_working_cart_files re-mounts for this purpose using _signal(39)**

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
		if (s0 and s0 ~= s1) print("\f9[external changes]\f6 "..path:sub(2)) found_external_changes = true
	end
end

compare_path("")
----------------------------------------------------------------------------------------------------------------------------------------------------------------


if (found_external_changes) then
	?"\f6external changes means that the cartridge file was modified on disk "
	?"\f6since the last time it was loaded or saved inside picotron."
	?"-> to load external changes, run with ctrl-r"
	?"\fd(or to discard them, use ctrl-s to save over them)"
end





