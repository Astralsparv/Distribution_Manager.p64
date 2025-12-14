--[[

	jettison kernal runtime functions so that they are not visible from userland
	rule: starts with single underscore followed by a..z

	-> not jettisoned:
		_VERSION
		__process_event_messages
]]

if (pid() > 3) then
	for k,v in pairs(_G) do
		if (sub(k,1,1) == "_" and ord(k,2,2) >= ord("a") and ord(k,2,2) <= ord("z")) then
			_G[k] = nil
		end
	end
end

-- sandboxed programs can not use the Debug library for now
-- (needs security review -- probably can be partially available at least)
if (env().sandbox) then
	Debug = nil
end


--[[
if (pid() > 3) then
	printh("----- candidates for jettison ------")
	local str = ""
	for k,v in pairs(_G) do
		if (sub(k,1,1) == "_" and #k > 3) then
			str..= k.." = nil\n"
		end
	end
	printh(str)
end
]]

