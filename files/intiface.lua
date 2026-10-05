local net = dofile_once("mods/haptic_noita/files/net.lua") ---@type net_ws
local json = dofile_once("mods/haptic_noita/files/json.lua") ---@type intiface_json

local intiface = {}

intiface.PROTOCOL_VERSION_MAJOR = 4
intiface.PROTOCOL_VERSION_MINOR = 0
intiface.parse_ipv4 = net.parse_ipv4

local DEFAULT_HOST = "127.0.0.1"
local DEFAULT_PORT = 12345
local MAX_PENDING_OUTPUTS = 64

---Replies are matched by id, so ids must not reuse an unacknowledged output id.
local next_message_id = 1

---@param pending_outputs table<number,boolean>
---@return number
local function take_message_id(pending_outputs)
	while true do
		local id = next_message_id
		next_message_id = next_message_id + 1
		if next_message_id > 65000 then next_message_id = 1 end
		if not pending_outputs[id] then return id end
	end
end

---Values go in verbatim: a number, a json.quote_string result, or a raw fragment.
---@param name string
---@param body table
---@return string
function intiface.encode(name, body)
	local parts = {}
	for key, value in pairs(body) do
		parts[#parts + 1] = json.quote_string(key) .. ":" .. tostring(value)
	end
	return "[{" .. json.quote_string(name) .. ":{" .. table.concat(parts, ",") .. "}}]"
end

---Flatten one DeviceList entry into the shape the rest of the mod uses.
---@param raw table
---@return table|nil
local function parse_device(raw)
	if type(raw.DeviceFeatures) ~= "table" then return nil end
	local device = {
		name = raw.DeviceName,
		display_name = raw.DeviceDisplayName,
		index = raw.DeviceIndex,
		timing_gap_ms = raw.DeviceMessageTimingGap or 0,
		features = {},
	}
	for key, raw_feature in pairs(raw.DeviceFeatures) do
		local feature = {
			index = raw_feature.FeatureIndex or tonumber(key),
			description = raw_feature.FeatureDescription,
			outputs = {},
			inputs = {},
		}
		for output_type, spec in pairs(raw_feature.Output or {}) do
			feature.outputs[output_type] = { min = spec.Value[1], max = spec.Value[2] }
		end
		for input_type, spec in pairs(raw_feature.Input or {}) do
			feature.inputs[input_type] = { min = spec.Value[1][1], max = spec.Value[1][2] }
		end
		device.features[feature.index] = feature
	end
	return device
end

---@class Session
---@field host string
---@field port number
---@field client_name string
---@field on_log fun(text:string)|nil
---@field client table
---@field ready boolean
---@field error string|nil
---@field closed_by_request boolean
---@field server_name string|nil
---@field max_ping_time_ms number
---@field device_name string
---@field last_ping_at_ms number|nil
---@field output_generation number
---@field devices table<number,table>
---@field pending_outputs table<number,boolean>
---@field pending_output_count number
local Session = {}
Session.__index = Session

---@param options table|nil host, port, client_name, on_log
---@return Session
function intiface.new_session(options)
	options = options or {}
	return setmetatable({
		host = options.host or DEFAULT_HOST,
		port = options.port or DEFAULT_PORT,
		client_name = options.client_name or "Haptic Noita",
		on_log = options.on_log,
		client = net.new_client(),
		ready = false,
		error = nil,
		closed_by_request = false,
		server_name = nil,
		max_ping_time_ms = 0,
		device_name = options.device_name or "",
		last_ping_at_ms = nil,
		output_generation = 0,
		devices = {},
		pending_outputs = {},
		pending_output_count = 0,
	}, Session)
end

---@param format string
---@param ... any
function Session:log(format, ...)
	if not self.on_log then return end
	local ok, text = pcall(string.format, format, ...)
	self.on_log(ok and text or format)
end

---@param name string
---@param body table
---@return boolean sent
function Session:send(name, body)
	return self.client:send_text(intiface.encode(name, body))
end

---Choose the lowest device and feature index with a Vibrate output.
---@return number|nil device_index
---@return number|nil feature_index
---@return number|nil minimum_step
---@return number|nil maximum_step
function Session:find_vibrate_feature()
	local selected_device, selected_feature, selected_vibrate
	local selected_index, selected_name = self.device_name:match("^index:(%d+):(.*)$")
	selected_index = tonumber(selected_index)
	for device_index, device in pairs(self.devices) do
		local matches = selected_index and device_index == selected_index and (device.name == selected_name or device.display_name == selected_name)
		if
			matches
			or (not selected_index and (self.device_name == "" or device.name == self.device_name or device.display_name == self.device_name))
		then
			for feature_index, feature in pairs(device.features) do
				local vibrate = feature.outputs.Vibrate
				if
					vibrate
					and (
						not selected_device
						or device_index < selected_device
						or (device_index == selected_device and feature_index < selected_feature)
					)
				then
					selected_device, selected_feature, selected_vibrate = device_index, feature_index, vibrate
				end
			end
		end
	end
	if selected_device then return selected_device, selected_feature, selected_vibrate.min or 0, selected_vibrate.max or 20 end
	return nil
end

---@return number
function Session:timing_gap_ms()
	local device_index = self:find_vibrate_feature()
	if not device_index then return 0 end
	return self.devices[device_index].timing_gap_ms or 0
end

---@param text string
function Session:on_message(text)
	local decoded, decode_error = json.decode(text)
	if type(decoded) ~= "table" then
		self:log("undecodable frame: %s (%s)", text, tostring(decode_error))
		return
	end

	for _, message in pairs(decoded) do
		for name, body in pairs(message) do
			self:handle_message(name, body)
		end
	end
end

---@param name string
---@param body table
function Session:handle_message(name, body)
	if name == "ServerInfo" then
		self.server_name = body.ServerName
		self.max_ping_time_ms = body.MaxPingTime or 0
		self.last_ping_at_ms = net.tick_ms()
		self:log("connected to %s, ping budget %dms", tostring(self.server_name), self.max_ping_time_ms)
		self:send("RequestDeviceList", { Id = take_message_id(self.pending_outputs) })
		return
	end

	if name == "DeviceList" then
		self.ready = false
		self.output_generation = self.output_generation + 1
		self.pending_outputs = {}
		self.pending_output_count = 0
		self.devices = {}
		for key, raw in pairs(body.Devices or {}) do
			local device = parse_device(raw)
			if device then self.devices[tonumber(key)] = device end
		end
		local device_index, feature_index, low, high = self:find_vibrate_feature()
		if not device_index then
			self:log("no matching device with a Vibrate output")
			return
		end
		self.ready = true
		self:log(
			"device %d (%s) feature %d, vibrate steps %d..%d, gap %dms",
			device_index,
			tostring(self.devices[device_index].name),
			feature_index,
			low,
			high,
			self:timing_gap_ms()
		)
		return
	end

	if name == "Ok" then
		if self.pending_outputs[body.Id] then
			self.pending_outputs[body.Id] = nil
			self.pending_output_count = self.pending_output_count - 1
		end
		return
	end

	if name == "Error" then
		if self.pending_outputs[body.Id] then
			self.pending_outputs[body.Id] = nil
			self.pending_output_count = self.pending_output_count - 1
			self.output_generation = self.output_generation + 1
		end
		self:log("server error %s: %s", tostring(body.ErrorCode), tostring(body.ErrorMessage))
		return
	end

	self:log("ignoring %s", name)
end

---@return boolean ok
---@return string|nil error
function Session:connect()
	self.ready = false
	self.output_generation = self.output_generation + 1
	self.pending_outputs = {}
	self.pending_output_count = 0
	self.error = nil
	self.closed_by_request = false
	self.max_ping_time_ms = 0
	self.last_ping_at_ms = nil
	self.client.on_open = function()
		self.client.on_message = function(text)
			self:on_message(text)
		end
		self:send("RequestServerInfo", {
			Id = take_message_id(self.pending_outputs),
			ClientName = json.quote_string(self.client_name),
			ProtocolVersionMajor = intiface.PROTOCOL_VERSION_MAJOR,
			ProtocolVersionMinor = intiface.PROTOCOL_VERSION_MINOR,
		})
	end
	self.client.on_close = function()
		self.ready = false
		self.output_generation = self.output_generation + 1
		self.pending_outputs = {}
		self.pending_output_count = 0
		self.devices = {}
		self.error = self.client.last_error
	end

	local ok, err = self.client:connect(self.host, self.port, "/")
	if not ok then self.error = err end
	return ok, err
end

---Closes on purpose, so the caller can tell it apart from a drop.
function Session:disconnect()
	self.ready = false
	self.output_generation = self.output_generation + 1
	self.pending_outputs = {}
	self.pending_output_count = 0
	self.closed_by_request = true
	self.client:close(1000)
end

---@return string transport_state
function Session:update()
	self.client:poll()
	if self.client.state == "open" and self.max_ping_time_ms > 0 then
		local timestamp = net.tick_ms()
		if timestamp - self.last_ping_at_ms >= math.max(1, math.floor(self.max_ping_time_ms / 2)) then
			if self:send("Ping", { Id = take_message_id(self.pending_outputs) }) then self.last_ping_at_ms = timestamp end
		end
	end
	if self.client.state == "idle" and not self.error then self.error = self.client.last_error end
	return self.client.state
end

---@return boolean
function Session:is_ready()
	return self.ready and self:find_vibrate_feature() ~= nil
end

---@param name string
---@param body table
---@return boolean sent
function Session:send_output(name, body)
	if self.pending_output_count >= MAX_PENDING_OUTPUTS then
		self.client:close(nil, "too many unacknowledged output commands")
		return false
	end
	local id = take_message_id(self.pending_outputs)
	body.Id = id
	if not self:send(name, body) then return false end
	self.pending_outputs[id] = true
	self.pending_output_count = self.pending_output_count + 1
	return true
end

---@param device_index number
---@param feature_index number
---@param value number integer within the device's advertised range
---@return boolean sent
function Session:set_vibrate(device_index, feature_index, value)
	return self:send_output("OutputCmd", {
		DeviceIndex = device_index,
		FeatureIndex = feature_index,
		Command = '{"Vibrate":{"Value":' .. string.format("%d", math.floor(value)) .. "}}",
	})
end

---@param device_index number
---@return boolean sent
function Session:stop_device(device_index)
	return self:send_output("StopCmd", { DeviceIndex = device_index })
end

return intiface
