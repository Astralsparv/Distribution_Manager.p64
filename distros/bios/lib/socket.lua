--[[

	socket.lua

	sock = socket("tcp://X.Y.Z.W:1234")
	?sock:status() 
	len = sock:write("hey")
	str = sock:read()          -- non-blocking
	sock:close()

]]

local Socket = {}

local _create_tcp_socket = _create_tcp_socket
local _create_udp_socket = _create_udp_socket
local _close_socket = _close_socket
local _read_socket = _read_socket
local _write_socket = _write_socket
local _sock_status = _sock_status
local _accept_socket = _accept_socket

-- to do: should [also] happen when garbage collected 
-- (or just time out; don't usually want long idle connections on backend anyway)
function Socket:close()
	if (not self.id) return
	_close_socket(self.id)
	self.id = 0 -- no longer associated with a PSOCKET
end


function Socket:new(attribs)

	if (type(attribs) == "string") attribs = {addr = attribs}

	-- need an address. "*" for server?
	if (not attribs.addr) return nil, "no address specified"

	-- split protocol from address
	local prot = attribs.addr:prot(true)
	if (prot) then
		attribs.addr = sub(attribs.addr, #prot + 4)
		attribs.prot = prot
	end

	-- convenience: tcp and udp addresses can contain port number
	-- ipv4 tcp://1.2.3.4:80
	-- ipv6 tcp://[1:2:3:4:5:6]:80
	if (attribs.prot == "tcp" or attribs.prot == "udp") then

		-- try ipv4
		local res = split(attribs.addr, ":", true)
		if (#res <= 2) then
			-- ipv4 or *
			if (type(res[2]) == "number") then 
				attribs.addr = res[1] -- could be "*"
				attribs.port = res[2]
			end
			-- test: convert to IPv4-mapped IPv6 address
			--[[
			if (attribs.addr ~= "*") then
				attribs.addr = "::ffff:"..attribs.addr
			end
			]]
		else
			-- ipv6: remove enclosing square brackets (if there are any) to extract port number
			local res1 = split(attribs.addr, "[", false)
			if res1 and res1[2] then
				res1 = split(res1[2], "]", false)
				if res1 then
					attribs.addr = res1[1]
					res1 = split(res1[2],":",true)
					if (res1 and type(res1[2]) == "number") then
						attribs.port = res1[2]
					end
				end
			end
		end

--		printh("new socket: "..pod{attribs})
	end

	local sock = attribs

	setmetatable(sock, self)
	self.__index = self

	-- printh(":new // attribs arg: "..pod(attribs))

	if sock.prot == "tcp" then
		if (not _create_tcp_socket) return nil, "socket implementation not available"
		sock.id, err = _create_tcp_socket(attribs.port, attribs.addr)		
		if (not sock.id) return nil, err or "_create_tcp_socket failed"
		return sock
	end

	if sock.prot == "udp" then
		if (not _create_udp_socket) return nil, "socket implementation not available"
		sock.id, err = _create_udp_socket(attribs.port, attribs.addr)		
		if (not sock.id) return nil, err or "_create_udp_socket failed"
		return sock
	end
	
	return nil, "socket protocol not found"
end

function Socket:read()
	return _read_socket(self.id)
end

function Socket:write(dat)
	return _write_socket(self.id, dat)
end

function Socket:status(dat)
	
	local ret = _sock_status(self.id) 

	if (ret) return ret

	-- socket either called :close() or remote host closed connection (fd no longer valid)
	return  self.id == 0 and "closed" or "disconnected"

end

function Socket:accept()
	local id = _accept_socket(self.id)
	if (id) then
		-- new socket accepted
		local sock = {
			id = id,
			port = self.port,
			addr = "[client_addr]" -- 
		}
		setmetatable(sock, self)
		self.__index = self
		return sock
	end
end


function socket(...)
	return Socket:new(...)
end

-- legacy; deleteme

function create_socket(...)
	printh("** FIXME: create_socket should be socket")
	return Socket:new(...)
end
