-- Non-blocking RFC 6455 WebSocket client on WinSock, plus SHA-1 and base64.
-- Every socket call must be non-blocking: one blocking recv would freeze the game.
-- FFI and Winsock traps are written up in docs/ffi-notes.md; read it before
-- touching anything in this file.
local ffi = require("ffi")
local bit = require("bit")

---@class net_ws
local net = {}

---Every mod shares one Lua state. Private aliases avoid inheriting another
---mod's WinSock prototypes; pcall contains struct declaration collisions.
---@param signature string
local function declare(signature)
	local ok, err = pcall(ffi.cdef, signature)
	if not ok then print("haptic_noita: could not declare " .. signature .. ": " .. tostring(err)) end
end

-- WinSock is __stdcall and Noita is x86, where LuaJIT defaults to cdecl: every
-- call would leave the stack unbalanced.
--
-- Only 3- and 4-argument entry points are bound; the 5-argument ones (select,
-- getsockopt, setsockopt) misbehave on this build. Connect completion is
-- detected through send instead. See docs/ffi-notes.md.
--
-- sockaddr_in is declared under a mod-private name because plain
-- "struct sockaddr_in" is the identifier another mod is most likely to own.
declare('int __stdcall haptic_noita_WSAStartup(int, void*) asm("WSAStartup");')
declare('int __stdcall haptic_noita_WSAGetLastError(void) asm("WSAGetLastError");')
declare('int __stdcall haptic_noita_socket(int, int, int) asm("socket");')
declare('int __stdcall haptic_noita_connect(int, const void*, int) asm("connect");')
declare('int __stdcall haptic_noita_send(int, const void*, int, int) asm("send");')
declare('int __stdcall haptic_noita_recv(int, void*, int, int) asm("recv");')
declare('int __stdcall haptic_noita_closesocket(int) asm("closesocket");')
declare('int __stdcall haptic_noita_ioctlsocket(int, long, void*) asm("ioctlsocket");')
declare('unsigned long __stdcall haptic_noita_GetTickCount(void) asm("GetTickCount");')
declare("struct haptic_sockaddr_in { unsigned short family; unsigned short port; unsigned char address[4]; char zero[8]; };")

-- Symbols are resolved from the namespace at each call site, never cached in a
-- local: on this LuaJIT build a cached ffi pointer dies at the next GC step.
-- See docs/ffi-notes.md.
local ws2_32 = ffi.load("ws2_32.dll")
local kernel32 = ffi.load("kernel32.dll")

local AF_INET = 2
local SOCK_STREAM = 1
local IPPROTO_TCP = 6
-- FIONBIO is 0x8004667E. bit.tobit is what reads it as the signed long
-- ioctlsocket expects; tonumber(_, 16) cannot, since Lua 5.1 parses hex through
-- a signed int.
local FIONBIO = bit.tobit(0x8004667E)

local WS_INTERRUPTED = 10004
local WS_WOULD_BLOCK = 10035
local WS_IN_PROGRESS = 10036
local WS_NOTCONN = 10057

local MAX_MESSAGE_BYTES = 2 ^ 20
local RECV_CHUNK_BYTES = 8192
local MAX_HANDSHAKE_HEADER_BYTES = 16384
local CONNECT_TIMEOUT_MS = 5000

local OPCODE_CONTINUATION = 0x0
local OPCODE_TEXT = 0x1
local OPCODE_CLOSE = 0x8
local OPCODE_PING = 0x9
local OPCODE_PONG = 0xa

local HANDSHAKE_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local scratch_wsa_data = ffi.new("unsigned char[512]")
local scratch_int = ffi.new("int[1]")
local scratch_recv = ffi.new("unsigned char[?]", RECV_CHUNK_BYTES)

---Mirrors the haptic_sockaddr_in cdef above, which LuaLS cannot read.
---@class haptic_sockaddr_in : ffi.cdata*
---@field family number big-endian on the wire
---@field port number big-endian on the wire
---@field address number[] already in network byte order

local scratch_address = ffi.new("struct haptic_sockaddr_in")
---@cast scratch_address haptic_sockaddr_in

local wsa_started = false

---@return number
function net.tick_ms()
	return kernel32.haptic_noita_GetTickCount()
end

---@return number
function net.last_error()
	return ws2_32.haptic_noita_WSAGetLastError()
end

---WSABASEERR values from the Windows SDK's winerror.h.
local ERROR_NAMES = {
	[10004] = "interrupted",
	[10009] = "bad file descriptor",
	[10013] = "permission denied",
	[10014] = "bad address",
	[10022] = "invalid argument",
	[10024] = "too many open sockets",
	[10035] = "would block",
	[10036] = "connect in progress",
	[10037] = "already connecting",
	[10038] = "not a socket",
	[10040] = "message too long",
	[10047] = "address family not supported",
	[10050] = "network is down",
	[10051] = "network unreachable",
	[10053] = "connection aborted",
	[10054] = "connection reset",
	[10057] = "not connected",
	[10058] = "socket already shut down",
	[10060] = "connection timed out",
	[10061] = "connection refused",
	[10063] = "host name too long",
	[10064] = "host is down",
	[10065] = "host unreachable",
	[10091] = "network subsystem unavailable",
	[10092] = "winsock not initialised",
}

---@param code number
---@return string
function net.describe_error(code)
	return ERROR_NAMES[code] or ("winsock " .. tostring(code))
end

---Idempotent. Noita's own startup count is not observable from Lua, so we always
---add a reference and never WSACleanup.
---@return boolean ok
---@return string|nil error
function net.startup()
	if wsa_started then return true end
	local status = ws2_32.haptic_noita_WSAStartup(bit.bor(bit.lshift(2, 8), 2), scratch_wsa_data)
	if status ~= 0 then return false, "WSAStartup failed: " .. net.describe_error(status) end
	wsa_started = true
	return true
end

---@param bytes string
---@return string
function net.base64_encode(bytes)
	local length = #bytes
	local chunks = {}
	local count = 0
	local index = 1

	local function push(value)
		count = count + 1
		chunks[count] = string.char(BASE64_ALPHABET:byte(value + 1))
	end

	while index + 2 <= length do
		local b1, b2, b3 = bytes:byte(index, index + 2)
		local packed = bit.lshift(b1, 16) + bit.lshift(b2, 8) + b3
		push(bit.rshift(packed, 18))
		push(bit.band(bit.rshift(packed, 12), 63))
		push(bit.band(bit.rshift(packed, 6), 63))
		push(bit.band(packed, 63))
		index = index + 3
	end

	local remaining = length - index + 1
	if remaining == 1 then
		local packed = bit.lshift(bytes:byte(index), 16)
		push(bit.rshift(packed, 18))
		push(bit.band(bit.rshift(packed, 12), 63))
		count = count + 1
		chunks[count] = "=="
	elseif remaining == 2 then
		local b1, b2 = bytes:byte(index, index + 1)
		local packed = bit.lshift(b1, 16) + bit.lshift(b2, 8)
		push(bit.rshift(packed, 18))
		push(bit.band(bit.rshift(packed, 12), 63))
		push(bit.band(bit.rshift(packed, 6), 63))
		count = count + 1
		chunks[count] = "="
	end

	return table.concat(chunks)
end

---@param value number
---@param amount number
---@return number
local function rotate_left(value, amount)
	return bit.bor(bit.lshift(value, amount), bit.rshift(value, 32 - amount))
end

---@param value number
---@return string four bytes, most significant first
local function big_endian_word(value)
	value = bit.band(value, 0xffffffff)
	return string.char(
		bit.band(bit.rshift(value, 24), 0xff),
		bit.band(bit.rshift(value, 16), 0xff),
		bit.band(bit.rshift(value, 8), 0xff),
		bit.band(value, 0xff)
	)
end

---SHA-1 in Lua: the handshake needs it once per connection, and advapi32's
---hashing is a heavier dependency than 40 lines of arithmetic.
---@param message string
---@return string 20 raw bytes
function net.sha1(message)
	local h0, h1, h2, h3, h4 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0

	local length = #message
	local bit_length = length * 8
	-- 0x80, zeros to 56 mod 64, then the 64-bit big-endian bit count.
	local padded = message .. "\128" .. string.rep("\0", (55 - length) % 64)
	padded = padded .. big_endian_word(math.floor(bit_length / 4294967296)) .. big_endian_word(bit_length)

	local w = {}
	for chunk = 1, #padded, 64 do
		for i = 0, 15 do
			local offset = chunk + i * 4
			local b1, b2, b3, b4 = padded:byte(offset, offset + 3)
			w[i] = bit.band(bit.lshift(b1, 24) + bit.lshift(b2, 16) + bit.lshift(b3, 8) + b4, 0xffffffff)
		end
		for i = 16, 79 do
			w[i] = rotate_left(bit.bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
		end

		local a, b, c, d, e = h0, h1, h2, h3, h4
		for i = 0, 79 do
			local f, k
			if i < 20 then
				f = bit.bor(bit.band(b, c), bit.band(bit.bnot(b), d))
				k = 0x5a827999
			elseif i < 40 then
				f = bit.bxor(b, c, d)
				k = 0x6ed9eba1
			elseif i < 60 then
				f = bit.bor(bit.band(b, c), bit.band(b, d), bit.band(c, d))
				k = 0x8f1bbcdc
			else
				f = bit.bxor(b, c, d)
				k = 0xca62c1d6
			end
			local temp = rotate_left(a, 5) + f + e + k + w[i]
			e = d
			d = c
			c = rotate_left(b, 30)
			b = a
			a = temp
		end

		h0 = bit.band(h0 + a, 0xffffffff)
		h1 = bit.band(h1 + b, 0xffffffff)
		h2 = bit.band(h2 + c, 0xffffffff)
		h3 = bit.band(h3 + d, 0xffffffff)
		h4 = bit.band(h4 + e, 0xffffffff)
	end

	return big_endian_word(h0) .. big_endian_word(h1) .. big_endian_word(h2) .. big_endian_word(h3) .. big_endian_word(h4)
end

---RFC 6455 wants an unpredictable mask key. No proxy sits on this loopback
---link, so a xorshift over the tick and CPU clocks is good enough.
local nonce_state = tonumber(tostring({}):byte(2, 2)) * 2654435761

---@return string
local function random_four_bytes()
	local mixed = bit.band(bit.tobit(kernel32.haptic_noita_GetTickCount()) + bit.tobit(os.clock() * 1000000) + nonce_state, 0xffffffff)
	nonce_state = bit.bxor(mixed, bit.lshift(mixed, 13))
	nonce_state = bit.bxor(nonce_state, bit.rshift(nonce_state, 17))
	nonce_state = bit.bxor(nonce_state, bit.lshift(nonce_state, 5))
	nonce_state = bit.band(nonce_state, 0xffffffff)
	local value = bit.band(bit.tobit(nonce_state) + bit.tobit(kernel32.haptic_noita_GetTickCount()), 0xffffffff)
	return string.char(
		bit.band(bit.rshift(value, 24), 0xff),
		bit.band(bit.rshift(value, 16), 0xff),
		bit.band(bit.rshift(value, 8), 0xff),
		bit.band(value, 0xff)
	)
end

---Clients must mask every frame (RFC 6455 s5.3).
---@param opcode number
---@param payload string
---@return string
function net.build_frame(opcode, payload)
	local length = #payload
	local fin_and_opcode = bit.lshift(1, 7) + opcode
	local mask_bit = bit.lshift(1, 7)
	local header

	if length < 126 then
		header = string.char(fin_and_opcode, mask_bit + length)
	elseif length < 65536 then
		header = string.char(fin_and_opcode, mask_bit + 126, math.floor(length / 256) % 256, length % 256)
	else
		-- Two 32-bit halves: bit.rshift masks its shift count to five bits, so
		-- a shift of 32 or more wraps onto the low word and corrupts the length.
		header = string.char(fin_and_opcode, mask_bit + 127)
			.. big_endian_word(math.floor(length / 4294967296))
			.. big_endian_word(length % 4294967296)
	end

	local m1, m2, m3, m4 = random_four_bytes():byte(1, 4)
	local mask_lookup = { m1, m2, m3, m4 }
	local masked = {}
	for index = 1, length do
		masked[index] = string.char(bit.bxor(payload:byte(index), mask_lookup[(index - 1) % 4 + 1]))
	end
	return header .. string.char(m1, m2, m3, m4) .. table.concat(masked)
end

---@param host string dotted-quad literal
---@return string|nil four bytes
function net.parse_ipv4(host)
	local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then return nil end
	a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
	if not a or not b or not c or not d then return nil end
	if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
	return string.char(a, b, c, d)
end

---Servers never mask, but the bit is honoured so a misbehaving peer cannot
---desync the parser.
---@param payload string
---@param mask_key string
---@return string
local function unmask(payload, mask_key)
	local m1, m2, m3, m4 = mask_key:byte(1, 4)
	local mask_lookup = { m1, m2, m3, m4 }
	local out = {}
	for index = 1, #payload do
		out[index] = string.char(bit.bxor(payload:byte(index), mask_lookup[(index - 1) % 4 + 1]))
	end
	return table.concat(out)
end

---Sec-WebSocket-Key is request-only, so the nonce is kept for the response check.
---@param self table
---@return string
local function build_handshake_request(self)
	local nonce = random_four_bytes() .. random_four_bytes() .. random_four_bytes() .. random_four_bytes()
	self.handshake_key = net.base64_encode(nonce)
	return "GET "
		.. self.path
		.. " HTTP/1.1\r\n"
		.. "Host: "
		.. self.host
		.. ":"
		.. self.port
		.. "\r\n"
		.. "Upgrade: websocket\r\n"
		.. "Connection: Upgrade\r\n"
		.. "Sec-WebSocket-Key: "
		.. self.handshake_key
		.. "\r\n"
		.. "Sec-WebSocket-Version: 13\r\n\r\n"
end

---@class Client
---@field handle any opaque SOCKET from ffi.new
---@field state "idle"|"connecting"|"handshaking"|"open"
---@field host string
---@field port number
---@field path string
---@field rx string
---@field rx_offset number bytes consumed, so the next unread byte is rx_offset + 1
---@field tx string
---@field tx_offset number
---@field fragment string|nil
---@field fragment_opcode number|nil
---@field handshake_key string|nil
---@field connection_started_ms number
---@field last_error string|nil
---@field on_open fun()|nil
---@field on_message fun(text:string)|nil
---@field on_close fun(code:number|nil)|nil
local Client = {}
Client.__index = Client

---@return Client
function net.new_client()
	return setmetatable({
		handle = nil,
		state = "idle",
		host = "127.0.0.1",
		port = 12345,
		path = "/",
		rx = "",
		rx_offset = 0,
		tx = "",
		tx_offset = 0,
		fragment = nil,
		fragment_opcode = nil,
		handshake_key = nil,
		connection_started_ms = 0,
		last_error = nil,
		on_open = nil,
		on_message = nil,
		on_close = nil,
	}, Client)
end

---@param self table
---@param reason string
---@return false
---@return string
local function fail(self, reason)
	self.last_error = reason
	self:close(nil, reason)
	return false, reason
end

---Safe in any state.
---@param code number|nil RFC 6455 close code to send first
---@param reason string|nil recorded as last_error
function Client:close(code, reason)
	if self.handle then
		if code and code ~= 1005 and code ~= 1006 then
			local frame = net.build_frame(OPCODE_CLOSE, string.char(bit.band(bit.rshift(code, 8), 0xff), bit.band(code, 0xff)))
			pcall(ws2_32.haptic_noita_send, self.handle, frame, #frame, 0)
		end
		ws2_32.haptic_noita_closesocket(self.handle)
		self.handle = nil
	end
	local was_open = self.state == "open"
	self.state = "idle"
	self.rx = ""
	self.rx_offset = 0
	self.tx = ""
	self.tx_offset = 0
	self.fragment = nil
	self.fragment_opcode = nil
	if reason then self.last_error = reason end
	if was_open and self.on_close then self.on_close(code) end
end

---Non-blocking: progress happens in :update.
---@param host string
---@param port number
---@param path string|nil defaults to "/"
---@return boolean ok
---@return string|nil error
function Client:connect(host, port, path)
	local started, startup_error = net.startup()
	if not started then
		---@cast startup_error string
		return fail(self, startup_error)
	end

	local address_bytes = net.parse_ipv4(host)
	if not address_bytes then return fail(self, "only literal IPv4 hosts are supported, got " .. tostring(host)) end

	self:close(nil)
	self.host = host
	self.port = port
	self.path = path or "/"

	local handle = ws2_32.haptic_noita_socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
	if handle == -1 then return fail(self, "socket: " .. net.describe_error(net.last_error())) end

	scratch_int[0] = 1
	if ws2_32.haptic_noita_ioctlsocket(handle, FIONBIO, scratch_int) == -1 then
		local code = net.last_error()
		ws2_32.haptic_noita_closesocket(handle)
		return fail(self, "ioctlsocket FIONBIO: " .. net.describe_error(code))
	end

	-- family and port are big-endian on the wire; address is already in network
	-- order. Assigning port as an integer would store it little-endian.
	scratch_address.family = AF_INET
	scratch_address.port = bit.bor(bit.lshift(bit.band(port, 0xffff), 8), bit.rshift(port, 8))
	for index = 1, 4 do
		scratch_address.address[index - 1] = address_bytes:byte(index)
	end

	if ws2_32.haptic_noita_connect(handle, scratch_address, ffi.sizeof("struct haptic_sockaddr_in")) == -1 then
		local code = net.last_error()
		if code ~= WS_WOULD_BLOCK and code ~= WS_IN_PROGRESS then
			ws2_32.haptic_noita_closesocket(handle)
			return fail(self, "connect: " .. net.describe_error(code))
		end
	end

	self.handle = handle
	self.state = "connecting"
	self.last_error = nil
	self.connection_started_ms = net.tick_ms()
	-- Queue the handshake now: flush_tx stays blocked on WSAEWOULDBLOCK until the
	-- connect completes, then surfaces any connect error through send. That is
	-- how connect status is detected without select.
	self.tx = self.tx .. build_handshake_request(self)
	return true
end

---@param self table
---@return string outcome "done", "blocked" or "failed"
local function flush_tx(self)
	local handle = self.handle
	if not handle then return "failed" end
	while self.tx_offset < #self.tx do
		local chunk = self.tx:sub(self.tx_offset + 1)
		local sent = ws2_32.haptic_noita_send(handle, chunk, #chunk, 0)
		if sent == -1 then
			local code = net.last_error()
			-- WSAENOTCONN is expected while the non-blocking connect is pending.
			local still_connecting = code == WS_NOTCONN and self.state == "connecting"
			if code == WS_WOULD_BLOCK or code == WS_INTERRUPTED or still_connecting then return "blocked" end
			fail(self, "send: " .. net.describe_error(code))
			return "failed"
		end
		if sent == 0 then return "blocked" end
		self.tx_offset = self.tx_offset + sent
	end
	self.tx = ""
	self.tx_offset = 0
	return "done"
end

---@param text string
---@return boolean queued
function Client:send_text(text)
	if self.state ~= "open" or not self.handle then return false end
	if self.tx ~= "" and flush_tx(self) ~= "done" then return false end
	self.tx = self.tx .. net.build_frame(OPCODE_TEXT, text)
	return flush_tx(self) ~= "failed"
end

---@param payload string
function Client:send_pong(payload)
	if not self.handle then return end
	if self.tx ~= "" and flush_tx(self) ~= "done" then return end
	self.tx = self.tx .. net.build_frame(OPCODE_PONG, payload)
	flush_tx(self)
end

---@param self table
---@return boolean ok
---@return number|nil byte_count 0 means the peer sent FIN
local function fill_rx(self)
	local handle = self.handle
	if not handle then return false end
	while true do
		local got = ws2_32.haptic_noita_recv(handle, scratch_recv, RECV_CHUNK_BYTES, 0)
		if got == -1 then
			local code = net.last_error()
			if code == WS_WOULD_BLOCK or code == WS_INTERRUPTED then return true end
			fail(self, "recv: " .. net.describe_error(code))
			return false
		end
		if got == 0 then return true, 0 end
		self.rx = self.rx .. ffi.string(scratch_recv, got)
		if got < RECV_CHUNK_BYTES then return true end
	end
end

---@param self table
---@param fin boolean
---@param opcode number
---@param payload string
---@return boolean keep_going
local function handle_frame(self, fin, opcode, payload)
	if opcode >= OPCODE_CLOSE then
		if opcode == OPCODE_PING then
			self:send_pong(payload)
		elseif opcode == OPCODE_CLOSE then
			local code = 1005
			if #payload >= 2 then code = bit.lshift(payload:byte(1), 8) + payload:byte(2) end
			self:close(code, "server closed with code " .. code)
			return false
		end
		return true
	end

	if opcode == OPCODE_CONTINUATION then
		if not self.fragment then
			fail(self, "continuation frame with no message in progress")
			return false
		end
		if #self.fragment + #payload > MAX_MESSAGE_BYTES then
			fail(self, "fragmented message exceeds the " .. MAX_MESSAGE_BYTES .. " byte limit")
			return false
		end
		self.fragment = self.fragment .. payload
	else
		if self.fragment then
			fail(self, "new data frame while a fragmented message was open")
			return false
		end
		self.fragment = payload
		self.fragment_opcode = opcode
	end

	if not fin then return true end

	local message = self.fragment
	local message_opcode = self.fragment_opcode
	self.fragment = nil
	self.fragment_opcode = nil

	if #message > MAX_MESSAGE_BYTES then
		fail(self, "message of " .. #message .. " bytes exceeds the " .. MAX_MESSAGE_BYTES .. " byte limit")
		return false
	end
	if message_opcode == OPCODE_TEXT and self.on_message then self.on_message(message) end
	return true
end

---@param self table
---@param index number 1-based
---@return number
local function readable_from(self, index)
	return #self.rx - index + 1
end

---@param self table
---@return boolean ok
local function parse_frames(self)
	while true do
		if readable_from(self, self.rx_offset + 1) < 2 then break end
		local b1, b2 = self.rx:byte(self.rx_offset + 1, self.rx_offset + 2)
		local fin = bit.band(b1, 0x80) ~= 0
		local opcode = bit.band(b1, 0x0f)
		local masked = bit.band(b2, 0x80) ~= 0
		local payload_length = bit.band(b2, 0x7f)
		local cursor = self.rx_offset + 3

		if payload_length == 126 then
			if readable_from(self, cursor) < 2 then break end
			payload_length = bit.lshift(self.rx:byte(cursor), 8) + self.rx:byte(cursor + 1)
			cursor = cursor + 2
		elseif payload_length == 127 then
			if readable_from(self, cursor) < 8 then break end
			-- The cap rejects any nonzero high word before payload buffering.
			payload_length = 0
			for index = 0, 7 do
				payload_length = payload_length * 256 + self.rx:byte(cursor + index)
			end
			cursor = cursor + 8
		end

		local mask_key
		if masked then
			if readable_from(self, cursor) < 4 then break end
			mask_key = self.rx:sub(cursor, cursor + 3)
			cursor = cursor + 4
		end

		if payload_length > MAX_MESSAGE_BYTES then
			fail(self, "frame of " .. payload_length .. " bytes exceeds the " .. MAX_MESSAGE_BYTES .. " byte limit")
			return false
		end
		if readable_from(self, cursor) < payload_length then break end

		local payload = self.rx:sub(cursor, cursor + payload_length - 1)
		self.rx_offset = cursor + payload_length - 1
		if mask_key then payload = unmask(payload, mask_key) end

		if not handle_frame(self, fin, opcode, payload) then return false end
	end

	-- Compact once the consumed prefix dominates, so a long-lived connection does
	-- not keep re-copying an ever-growing string.
	if self.rx_offset > 4096 and self.rx_offset * 2 >= #self.rx then
		self.rx = self.rx:sub(self.rx_offset + 1)
		self.rx_offset = 0
	end
	return true
end

---@param self table
---@return boolean ok
local function parse_handshake(self)
	local marker = self.rx:find("\r\n\r\n", self.rx_offset + 1, true)
	if not marker then
		if readable_from(self, self.rx_offset + 1) > MAX_HANDSHAKE_HEADER_BYTES then
			fail(self, "handshake response headers exceeded " .. MAX_HANDSHAKE_HEADER_BYTES .. " bytes")
			return false
		end
		return true
	end

	-- find gives the first byte of the match, and the CRLFCRLF spans marker ..
	-- marker + 3, so that is where the consumed count ends up.
	local header_block = self.rx:sub(self.rx_offset + 1, marker - 1)
	self.rx_offset = marker + 3

	local status = header_block:match("^HTTP/1%.1 (%d+)")
	if status ~= "101" then
		fail(self, "server refused the upgrade: HTTP " .. (status or "malformed response"))
		return false
	end

	local accept = header_block:match("[Ss]ec%-[Ww]eb[Ss]ocket%-[Aa]ccept:%s*(%S+)")
	if not accept then
		fail(self, "handshake response has no Sec-WebSocket-Accept header")
		return false
	end
	if not self.handshake_key then
		fail(self, "handshake response arrived without a request having been sent")
		return false
	end
	local expected = net.base64_encode(net.sha1(self.handshake_key .. HANDSHAKE_GUID))
	if accept ~= expected then
		fail(self, "bad Sec-WebSocket-Accept, server said " .. accept .. " expected " .. expected)
		return false
	end
	self.handshake_key = nil

	self.state = "open"
	self.last_error = nil
	if self.on_open then self.on_open() end
	return parse_frames(self)
end

---Advance the state machine one step. Call once per frame.
---@return string state
function Client:update()
	if
		(self.state == "connecting" or self.state == "handshaking")
		and (net.tick_ms() - self.connection_started_ms) % 4294967296 > CONNECT_TIMEOUT_MS
	then
		fail(self, "connection timed out after " .. CONNECT_TIMEOUT_MS .. " ms")
		return self.state
	end
	if self.state == "connecting" then
		local outcome = flush_tx(self)
		if outcome == "done" then
			self.state = "handshaking"
		elseif outcome == "failed" then
			return self.state
		end
		return self.state
	end

	if self.state == "handshaking" or self.state == "open" then
		local ok, at_end = fill_rx(self)
		if not ok then return self.state end
		if at_end == 0 then
			self:close(nil, "server closed the connection")
			return self.state
		end
		if self.state == "handshaking" then
			parse_handshake(self)
		else
			parse_frames(self)
		end
		flush_tx(self)
		return self.state
	end

	return self.state
end

---Safe to call every frame; a no-op when idle.
---@return string state
function Client:poll()
	if self.state == "idle" then return self.state end
	return self:update()
end

return net
