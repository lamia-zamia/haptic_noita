---Minimal JSON decoder for Noita's Lua 5.1, enough for the Intiface protocol.
---Hand-written because the device list is objects nested in objects keyed by index.
---@class intiface_json
local json = {}

local bit = require("bit")

---@class json_null
json.null = setmetatable({}, {
	__tostring = function()
		return "null"
	end,
})

local ESCAPES = {
	['"'] = '"',
	["\\"] = "\\",
	["/"] = "/",
	b = "\b",
	f = "\f",
	n = "\n",
	r = "\r",
	t = "\t",
}

---@param text string
---@param index number 1-based index of the opening quote
---@return string
---@return number index of the byte after the closing quote
local function decode_string(text, index)
	local out = {}
	local length = #text
	index = index + 1
	while index <= length do
		local character = text:sub(index, index)
		if character == '"' then
			return table.concat(out), index + 1
		elseif character == "\\" then
			local escape = text:sub(index + 1, index + 1)
			if escape == "u" then
				local hex = text:sub(index + 2, index + 5)
				local code = tonumber(hex, 16) or 0xfffd
				if code >= 0xd800 and code <= 0xdbff and text:sub(index + 6, index + 7) == "\\u" then
					local low = tonumber(text:sub(index + 8, index + 11), 16)
					if low and low >= 0xdc00 and low <= 0xdfff then
						code = 0x10000 + (code - 0xd800) * 0x400 + (low - 0xdc00)
						index = index + 6
					end
				end
				if code < 0x80 then
					out[#out + 1] = string.char(code)
				elseif code < 0x800 then
					out[#out + 1] = string.char(bit.band(bit.rshift(code, 6), 0x3f) + 0xc0, bit.band(code, 0x3f) + 0x80)
				elseif code < 0x10000 then
					out[#out + 1] = string.char(
						bit.band(bit.rshift(code, 12), 0x0f) + 0xe0,
						bit.band(bit.rshift(code, 6), 0x3f) + 0x80,
						bit.band(code, 0x3f) + 0x80
					)
				else
					out[#out + 1] = string.char(
						bit.band(bit.rshift(code, 18), 0x07) + 0xf0,
						bit.band(bit.rshift(code, 12), 0x3f) + 0x80,
						bit.band(bit.rshift(code, 6), 0x3f) + 0x80,
						bit.band(code, 0x3f) + 0x80
					)
				end
				index = index + 6
			else
				out[#out + 1] = ESCAPES[escape] or escape
				index = index + 2
			end
		else
			-- Copy the ordinary run in one go; a Lua character class cannot
			-- reliably hold a backslash.
			local stop = index
			while stop <= length do
				local next_character = text:sub(stop, stop)
				if next_character == '"' or next_character == "\\" then break end
				stop = stop + 1
			end
			out[#out + 1] = text:sub(index, stop - 1)
			index = stop
		end
	end
	error("unterminated string", 0)
end

---@param text string
---@param index number
---@return number
local function skip_space(text, index)
	local _, stop = text:find("^[ \t\r\n]*", index)
	return stop + 1
end

---@param text string
---@param index number
---@return any value
---@return number index of the first byte after the value
local function decode_value(text, index)
	index = skip_space(text, index)
	local character = text:sub(index, index)

	if character == "{" then
		local object = {}
		index = skip_space(text, index + 1)
		if text:sub(index, index) == "}" then return object, index + 1 end
		while true do
			index = skip_space(text, index)
			if text:sub(index, index) ~= '"' then error("expected a string key at " .. index, 0) end
			local key
			key, index = decode_string(text, index)
			index = skip_space(text, index)
			if text:sub(index, index) ~= ":" then error("expected ':' at " .. index, 0) end
			local value
			value, index = decode_value(text, index + 1)
			object[key] = value
			index = skip_space(text, index)
			local separator = text:sub(index, index)
			if separator == "," then
				index = index + 1
			elseif separator == "}" then
				return object, index + 1
			else
				error("expected ',' or '}' at " .. index, 0)
			end
		end
	end

	if character == "[" then
		local array = {}
		local count = 0
		index = skip_space(text, index + 1)
		if text:sub(index, index) == "]" then return array, index + 1 end
		while true do
			local value
			value, index = decode_value(text, index)
			count = count + 1
			array[count] = value
			index = skip_space(text, index)
			local separator = text:sub(index, index)
			if separator == "," then
				index = index + 1
			elseif separator == "]" then
				return array, index + 1
			else
				error("expected ',' or ']' at " .. index, 0)
			end
		end
	end

	if character == '"' then return decode_string(text, index) end

	if text:sub(index, index + 3) == "true" then return true, index + 4 end
	if text:sub(index, index + 4) == "false" then return false, index + 5 end
	if text:sub(index, index + 3) == "null" then return json.null, index + 4 end

	local number = text:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", index)
	if number and number ~= "" then return tonumber(number), index + #number end

	error("unexpected input at " .. index, 0)
end

---@param text string
---@return any|nil value
---@return string|nil error
function json.decode(text)
	if type(text) ~= "string" then return nil, "expected a string" end
	local ok, value = pcall(function()
		local result, index = decode_value(text, 1)
		index = skip_space(text, index)
		if index <= #text then error("trailing data at " .. index, 0) end
		return result
	end)
	if not ok then return nil, tostring(value) end
	return value
end

---@param text string
---@return string quoted
function json.quote_string(text)
	local escaped = text:gsub('[%c"\\]', function(character)
		if character == '"' then
			return '\\"'
		elseif character == "\\" then
			return "\\\\"
		elseif character == "\n" then
			return "\\n"
		elseif character == "\r" then
			return "\\r"
		elseif character == "\t" then
			return "\\t"
		end
		return string.format("\\u%04x", character:byte())
	end)
	return '"' .. escaped .. '"'
end

return json
