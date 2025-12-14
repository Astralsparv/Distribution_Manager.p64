--[[

	undo.lua

	my_stack = create_undo_stack(mysave, myload, pod_flags, item)
	
		function mysave()   -- return program state
		function myload(s)  -- load s into program state
		pod_flags           -- pod format for pod() -- (default to 0x81: simple rle has best patch_size/cpu/mem results in almost all cases)
		item                -- extra info that the caller can use (usually to identify which item)

]]


local Undo = {}

local create_delta = create_delta
local apply_delta = apply_delta

function Undo:reset()

	self.head_state_str = ""
	self.undo_stack = {}
	self.redo_stack = {}

	-- store initial state; first item in .undo_stack is treated as a dummy (live_state -> "")
	self:checkpoint()
end

function Undo:undo()

	if (#self.undo_stack < 2) return false -- nothing to undo ~ first item goes back to nil state

	if (#self.redo_stack == 0) self:checkpoint() -- might have made changes after head state

	-- return to checkpoint before head
	local prev_state_str = apply_delta(self.head_state_str, deli(self.undo_stack))
	add(self.redo_stack, create_delta(prev_state_str, self.head_state_str))
	self.load_state(unpod(prev_state_str), self.item)
	self.head_state_str = prev_state_str -- new head

	return true
end


function Undo:redo()

	if (#self.redo_stack < 1) return false -- nothing to redo

	local next_state_str = apply_delta(self.head_state_str, deli(self.redo_stack))
	add(self.undo_stack, create_delta(next_state_str, self.head_state_str))
	self.load_state(unpod(next_state_str), self.item)
	self.head_state_str = next_state_str -- new head

	return true
end



function Undo:checkpoint()

	-- from current to previously recorded checkpoint
	local live_state_str = pod(self.save_state(self.item), self.pod_flags)

	-- printh("live_state_str: "..#live_state_str)

	-- skip when no changes
	--> if save_state() returns two differen strings for the same state, will produce a nop checkpoint
		-- pod() is not deterministic because integer-indexed array length can vary unexpectedly:
		-- consider: a={[2]=2} ?pod(a)   (produces "{[2]=2}")   vs.  a={1,2}a[1]=nil ?pod(a) (produces "{nil,2}")
	if (live_state_str == self.head_state_str and #self.undo_stack > 0) then
		return false -- no change
	end

	local delta = create_delta(live_state_str, self.head_state_str)

	add(self.undo_stack, delta)
	self.head_state_str = live_state_str
	self.redo_stack = {}
	return true
end


function Undo:new(save_state, load_state, pod_flags, item)

	local u = {
		save_state = save_state,
		load_state = load_state,
		pod_flags  = pod_flags or 0x81, -- 0.2.0i: 0x81 is almost always optimal (was 0x0)
		item = item
	}

	setmetatable(u, self)
	self.__index = self

	u:reset()
	
	return u
end

--------------------------------------------------------------------------------------------------------------------------------
--    Undo
--------------------------------------------------------------------------------------------------------------------------------

function create_undo_stack(...)
	return Undo:new(...)
end




