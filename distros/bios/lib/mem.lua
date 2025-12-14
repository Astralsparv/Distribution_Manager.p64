
local _map_ram = _map_ram
local _ppeek = _ppeek
local _ppeek4 = _ppeek4
local _set_spr = _set_spr
local _draw_map = _draw_map
local _unmap_ram = _unmap_ram

local _fetch_metadata_from_file = _fetch_metadata_from_file
local _load = load

--------------------------------------------------------------------------------------------------------------------------------
--   Memory
--------------------------------------------------------------------------------------------------------------------------------

local userdata_ref = {} -- hold mapped userdata references
local _current_map = nil -- defaults to 32x32 at end of this file
local _unmap -- defined below

function memmap(ud, addr, offset, len)
	if (type(addr) == "userdata") addr,ud = ud,addr -- legacy >_<
	if (_map_ram(ud, addr, offset, len)) then
		
		if (addr == 0x100000) then
			_unmap(_current_map, 0x100000) -- kick out old map
			_current_map = ud
		end
		userdata_ref[ud] = ud -- need to include a as a value on rhs to keep it held

		return ud -- 0.1.0h: allows things like pfxdat = fetch("tune.sfx"):memmap(0x30000)
	end
end

-- unmap by userdata
-- ** this is the only way to release mapped userdata for collection **
-- ** e.g. memmapping a userdata over an old one is not sufficient to free it for collection **
function unmap(ud, addr, len)
	if _unmap_ram(ud, addr, len) -- len defaults to full userdata length
	then
		-- nothing left pointing into Lua object -> can release reference and be garbage collected 	
		userdata_ref[ud] = nil
	end
end
_unmap = unmap

--------------------------------------------------------------------------------------------------------------------------------
--    Sprite Registry
--------------------------------------------------------------------------------------------------------------------------------

local _spr = {} 

-- add or remove a sprite at index
-- flags stored at 0xc000 (16k)
function set_spr(index, s, flags_val)
	index &= 0x3fff
	_spr[index] = s    -- reference held by head
	_set_spr(index, s) -- notify process
	if (flags_val) poke(0xc000 + index, flags_val)
end

-- 0.1.1e: only 32 banks (was &0x3fff). bits 0xe000 reserved for orientation (flip x,y,diagonal)
function get_spr(index)
	return _spr[flr(index) & 0x1fff]
end



function map(ud, b, ...)
	
	if (type(ud) == "userdata") then
		-- userdata is first parameter -- use that and set current map
		_draw_map(ud, b, ...)
	else
		-- pico-8 syntax
		_draw_map(_current_map, ud, b, ...)
	end
end



