-- Read-only view of Noita's screen shake "trauma" value. The game has no Lua
-- getter for it (see docs/README.md, screen shake section). No absolute addresses are hardcoded:
-- the address of the global game pointer is discovered at runtime by scanning the
-- running exe's code, so it survives a game update as long as the accessor's
-- shape and the struct offsets below do not change.
local ffi = require("ffi")
local bit = require("bit")

---@class screenshake_source
---@field pointer_address integer|nil
---@field available boolean
local screenshake = {}
screenshake.__index = screenshake

local ok_declare, declare_error = pcall(ffi.cdef, 'void* __stdcall haptic_noita_GetModuleHandleA(const char*) asm("GetModuleHandleA");')
if not ok_declare then print("haptic_noita: could not declare GetModuleHandleA: " .. tostring(declare_error)) end
pcall(
	ffi.cdef,
	"struct haptic_noita_meminfo { uint32_t base; uint32_t allocation_base; uint32_t allocation_protect; uint32_t region_size; uint32_t state; uint32_t protect; uint32_t type; };"
)
pcall(ffi.cdef, 'uint32_t __stdcall haptic_noita_VirtualQuery(const void*, void*, uint32_t) asm("VirtualQuery");')

-- Struct layout, not addresses: Game -> +0x0C world/camera object -> +0x58 trauma.
local WORLD_OFFSET = 0x0C
local TRAUMA_OFFSET = 0x58
local SECTION_HEADER_BYTES = 40
local SECTION_CODE_FLAG = 0x20
local MIN_AGREEING_SITES = 2
local MEM_COMMIT = 0x1000
local PAGE_UNREADABLE = 0x101 -- PAGE_NOACCESS | PAGE_GUARD
local MAX_PLAUSIBLE_TRAUMA = 100000

-- The game's lazy accessor, which the compiler inlined hundreds of times:
--   mov eax, [GAME_PTR] ; test eax, eax ; jne +x ; push 0x1A0 (sizeof Game) ; call [operator new]
-- nil is a wildcard byte.
local PATTERN = { 0xA1, nil, nil, nil, nil, 0x85, 0xC0, 0x75, nil, 0x68, 0xA0, 0x01, 0x00, 0x00, 0xFF, 0x15 }
local PATTERN_LENGTH = 16

---@param bytes ffi.cdata*
---@param offset integer
---@return boolean
local function pattern_matches(bytes, offset)
	for index = 0, PATTERN_LENGTH - 1 do
		local expected = PATTERN[index + 1]
		if expected and bytes[offset + index] ~= expected then return false end
	end
	return true
end

---@param bytes ffi.cdata*
---@param offset integer
---@return integer address of the game pointer
local function read_address(bytes, offset)
	return bytes[offset + 1] + bytes[offset + 2] * 256 + bytes[offset + 3] * 65536 + bytes[offset + 4] * 16777216
end

---Scan one code section; returns the pointer address once enough sites agree.
---@param section_start integer
---@param section_size integer
---@param image_start integer
---@param image_end integer
---@return integer|nil
local function scan_section(section_start, section_size, image_start, image_end)
	local bytes = ffi.cast("uint8_t*", section_start)
	local found_address, agreeing = nil, 0
	for offset = 0, section_size - PATTERN_LENGTH do
		if bytes[offset] == 0xA1 and pattern_matches(bytes, offset) then
			local address = read_address(bytes, offset)
			if address >= image_start and address < image_end then
				if found_address and address ~= found_address then return nil end
				found_address = address
				agreeing = agreeing + 1
				if agreeing >= MIN_AGREEING_SITES then return found_address end
			end
		end
	end
	return nil
end

---Walk the exe's PE headers and scan its code sections.
---@return integer|nil address of the game pointer variable
local function discover_game_pointer_address()
	local image_start = tonumber(ffi.cast("uint32_t", ffi.load("kernel32.dll").haptic_noita_GetModuleHandleA(nil))) or 0
	local header = ffi.cast("uint8_t*", image_start)
	local pe = ffi.cast("uint32_t*", header + 0x3C)[0]
	local section_count = ffi.cast("uint16_t*", header + pe + 6)[0]
	local optional_header_size = ffi.cast("uint16_t*", header + pe + 20)[0]
	local image_end = image_start + ffi.cast("uint32_t*", header + pe + 24 + 56)[0]
	local sections = header + pe + 24 + optional_header_size
	for index = 0, section_count - 1 do
		local section = sections + index * SECTION_HEADER_BYTES
		local characteristics = ffi.cast("uint32_t*", section + 36)[0]
		if bit.band(characteristics, SECTION_CODE_FLAG) ~= 0 then
			local size = ffi.cast("uint32_t*", section + 8)[0]
			local start = image_start + ffi.cast("uint32_t*", section + 12)[0]
			local address = scan_section(start, size, image_start, image_end)
			if address then return address end
		end
	end
	return nil
end

---Mirrors the haptic_noita_meminfo cdef above, which LuaLS cannot read.
---@class haptic_noita_meminfo : ffi.cdata*
---@field base integer
---@field region_size integer
---@field state integer
---@field protect integer

---A dereference of garbage kills the whole process and pcall cannot catch it,
---so every pointer is checked with VirtualQuery before it is read.
---@param address integer
---@param size integer
---@return boolean
local function is_readable(address, size)
	local info = ffi.new("struct haptic_noita_meminfo")
	---@cast info haptic_noita_meminfo
	if ffi.load("kernel32.dll").haptic_noita_VirtualQuery(ffi.cast("void*", address), info, ffi.sizeof(info)) == 0 then return false end
	if info.state ~= MEM_COMMIT or bit.band(info.protect, PAGE_UNREADABLE) ~= 0 then return false end
	return address + size <= info.base + info.region_size
end

---Create a reader.
---@return screenshake_source `available` is false when discovery failed; it never retries.
function screenshake.new()
	local self = setmetatable({ pointer_address = nil, available = false }, screenshake)
	local ok, address = pcall(discover_game_pointer_address)
	if ok and address then
		self.pointer_address = address
		self.available = true
	else
		print("haptic_noita: screen shake source not found (" .. tostring(address) .. "), screen shake event disabled")
	end
	return self
end

---Current trauma, 0 when idle. Game units: 5 is light rain, 30 a collapse, 150 a temple leak.
---@return number|nil nil while the game object or its world does not exist yet
function screenshake:read()
	local pointer_address = self.pointer_address
	if not self.available or not pointer_address then return nil end
	if not is_readable(pointer_address, 4) then return self:disable("game pointer unreadable") end
	local game = ffi.cast("uint32_t*", pointer_address)[0]
	if game == 0 then return nil end
	if not is_readable(game + WORLD_OFFSET, 4) then return self:disable("game object unreadable") end
	local world = ffi.cast("uint32_t*", game + WORLD_OFFSET)[0]
	if world == 0 then return nil end
	if not is_readable(world + TRAUMA_OFFSET, 4) then return self:disable("world object unreadable") end
	local trauma = ffi.cast("float*", world + TRAUMA_OFFSET)[0]
	if not (trauma >= 0 and trauma < MAX_PLAUSIBLE_TRAUMA) then return self:disable("implausible trauma " .. tostring(trauma)) end
	return trauma
end

---Permanently stop reading after the layout stopped matching expectations.
---@param reason string
---@return nil
function screenshake:disable(reason)
	self.available = false
	print("haptic_noita: screen shake event disabled (" .. reason .. ")")
	return nil
end

return screenshake
