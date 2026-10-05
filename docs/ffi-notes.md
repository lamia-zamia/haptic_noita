# LuaJIT FFI notes for driving WinSock from Noita

All reproduced on standalone LuaJIT 2.0.4 x86 against a live Intiface server.
Most failures give wrong behavior rather than errors.

## `__stdcall` is mandatory

Without it every WinSock call leaves the stack unbalanced:

```lua
ffi.cdef[[ int __stdcall connect(int, const void*, int); ]]
```

## A raw cdata array is not passed correctly as `void*`

`sockaddr_in` written as `ffi.new("unsigned char[16]")` and passed to `connect`
gives `WSAEAFNOSUPPORT` (10047), and `bind` fails the same way. A **declared
struct** at the same layout works:

```lua
ffi.cdef[[ struct haptic_sockaddr_in {
  unsigned short family; unsigned short port; unsigned char address[4]; char zero[8];
}; ]]
local address = ffi.new("struct haptic_sockaddr_in")
```

A struct passed where `void*` is expected is passed correctly. An array is not.

## `bit.rshift` masks its shift count to five bits

Building a 64-bit frame length with `bit.rshift(length, 56)` silently wraps to
`>> 24`. Any payload over 65535 bytes therefore gets a corrupt length header,
and it is exactly the range that selects the 64-bit encoding. Use plain
arithmetic:

```lua
big_endian_word(math.floor(length / 4294967296)) .. big_endian_word(length % 4294967296)
```

`bit.rshift` with a count of 24 or less is fine.

## `tonumber(_, 16)` goes through a signed int

```lua
tonumber("100000000", 16)  --> 4294967295, not 4294967296
```

Any hex literal above `0x7FFFFFFF` parses as its wrapped value. `bit.tobit` is
the reliable way to get a constant like `FIONBIO` (0x8004667E) into the signed
form `ioctlsocket` wants. Getting this wrong yields `WSAENOTSOCK` (10045).

## Five-argument entry points are unreliable here

`select`, `getsockopt` and `setsockopt` are 5-argument calls. On this build:

- `select` always fails, with `WSAENOTSOCK` (10038) when a descriptor is present
  and `WSAEINVAL` (10022) when the sets are empty. Both the byte-array and the
  declared-struct `fd_set` behave identically, and the returned address was
  confirmed identical to `GetProcAddress("ws2_32.dll", "select")`.
- `getsockopt` returns **success** but writes its result into the wrong buffer.

`WSAEINVAL` from an all-empty `select` is legitimate Winsock behaviour, not part
of the bug: with nothing to wait on and a zero timeout there is nothing to do.

**Required workaround:** connect completion and error reporting use a plain
`send` instead. The handshake request is queued up front, so while the
non-blocking connect is in flight `send` returns `WSAEWOULDBLOCK`; once the
connect completes, `send` either succeeds or reports the connect error. Cost:
`TCP_NODELAY` cannot be set, since that needs `setsockopt`; on loopback with
request/response traffic Nagle has nothing to delay.

### `send` reports `WSAENOTCONN` while connecting

Expected behavior: during a non-blocking connect, `send` on the pending
handshake returns `WSAENOTCONN` (10057) until the TCP handshake finishes.
Treating it as fatal drops the connection during reconnect. It is benign only
while the state machine is in its `connecting` state.

## Cached `ffi.load` pointers die at the next GC step

**Failure mode: crashes the game (access violation).** Verified with LuaJIT
2.0.4 x86, so it applies in Noita:

```lua
local ws2_32 = ffi.load("ws2_32.dll")
local socket = ws2_32.socket        -- cached derived pointer
local function connect() return socket(2, 1, 6) end
return { connect = connect }
```

```lua
local net = dofile_once("net.lua")
net.connect()          -- fine
collectgarbage()
net.connect()          -- access violation, 0xC0000005
```

The derived cdata that `ws2_32.socket` produces is not kept alive by keeping
`ws2_32` alive. Once a GC cycle has run, calling it jumps through freed memory.
`kernel32.GetTickCount` survived this in testing, which is luck, not a rule:
do not rely on any cached pointer.

Two conditions, both required: the pointer must be an **upvalue of a closure in
a chunk loaded by `dofile_once`** (the main chunk does not show it), and a GC cycle
must complete before the call. Because Noita GCs constantly, a mod that caches
these and connects on player spawn is a crash waiting to happen.

**Required workaround:** cache only the namespace and resolve the symbol at each
call site, `ws2_32.socket(...)`. Verified with LuaJIT 2.0.4 x86 over 50
connect/GC cycles with no crash.

The same shape with an `ffi.new("int[2]")` buffer passed as `void*` also faults
after a GC; an `unsigned char[512]` array does not. Prefer a declared struct for
any `void*` buffer, per the section above.

## `ffi.cdef` declarations share one Lua state

On this LuaJIT build, a second function declaration with the same name succeeds
silently, even when its prototype differs. The first prototype remains in use:
declaring one-argument `send` before the mod's four-argument declaration makes
a four-argument call fail with `wrong number of arguments for function call`.
A second definition of an existing struct **does** throw.

The per-signature `pcall` only contains errors that throw; it does not validate
an existing prototype. WinSock functions use mod-private FFI names redirected
with `asm("send")` and the corresponding exported symbol names. This avoids
inheriting another mod's declaration of `send`, `recv`, or other common names.
The `haptic_sockaddr_in` prefix likewise avoids a likely struct collision.

`ffi.load("ws2_32.dll")` only exposes symbols that have been declared, so the
declaration and the load are both required.

## Only 3- and 4-argument calls were verified

`WSAStartup`, `WSAGetLastError`, `socket`, `connect`, `ioctlsocket`, `send`,
`recv` and `closesocket` were exercised against a live server. No other WinSock
entry point was tested.

## Typing FFI structs for LuaLS

`files/net.lua` mirrors `haptic_sockaddr_in` with `---@class` plus three
`---@field`s, because LuaLS does not read the `ffi.cdef` string. Two things
matter:

- The class must extend `ffi.cdata*` (with the asterisk, and only in a
  `---@class X : ffi.cdata*` parent position; bare `ffi.cdata` is an undefined
  doc name) and be applied with a separate `---@cast`, not `---@type`.
  `---@type` is a checked assertion, so `ffi.new()` returning `ffi.cdata*`
  trips `assign-type-mismatch`; `---@class` on the `local` line trips it too.
- `---@class X` on an assignment is a definition, but the assignment is still
  checked against it. Only `---@cast` on the following line is unchecked.

The alternative, adding `"inject-field"` to `Lua.diagnostics.disable`, was
rejected: the fields are real information and the cast documents them.

## Off-by-one trap when tracking a read offset

`rx_offset` counts bytes consumed, so the next unread byte is at
`rx_offset + 1`. Mixing that with a cursor used directly as a 1-based index
silently misparses every frame. The "wait for more data" comparison and the
payload cursor must use the same convention. The symptom is one payload byte
missing from every inbound message.

`local marker = s:find("\r\n\r\n", offset, true)` returns the index of the
**first** byte of the match, so the consumed count after it is `marker + 3`, not
`marker + 4`.
