
--------------------------------------------------------------------------------------------------------------------------------
--    Coroutines
--------------------------------------------------------------------------------------------------------------------------------

-- aliases
yield = coroutine.yield
cocreate = coroutine.create
costatus = coroutine.status

local _coresume = coroutine.resume -- used internally
local _costatus = coroutine.status
local _yielded_to_escape_slice = _yielded_to_escape_slice

--[[

	coresume wrapper needed to preserve and restore call stack
	when interrupting program due to cpu / memory limits

]]

function coresume(c,...)
	
	_yielded_to_escape_slice(0)
	local ret = {_coresume(c,...)}
	--printh("coresume() -> _yielded_to_escape_slice():"..tostring(_yielded_to_escape_slice()))
	while (_yielded_to_escape_slice() and _costatus(c) == "suspended") do
		_yielded_to_escape_slice(0)
		ret = {_coresume(c,...)}
	end
	_yielded_to_escape_slice(0)

	return unpack(ret)
end

-- 0.1.1e library version should do the same
coroutine.resume = coresume


