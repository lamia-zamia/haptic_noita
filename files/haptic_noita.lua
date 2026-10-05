local intiface = dofile_once("mods/haptic_noita/files/intiface.lua")
local haptics_lib = dofile_once("mods/haptic_noita/files/haptics.lua")
local events_lib = dofile_once("mods/haptic_noita/files/events.lua")

---Retry backoff bounds in seconds.
local RECONNECT_MIN_SECONDS = 1.0
local RECONNECT_MAX_SECONDS = 15.0
local TEST_WAIT_SECONDS = 4.0

local MOD_PREFIX = "haptic_noita."

---@param id string
---@return boolean
local function get_setting_boolean(id)
	local value = ModSettingGetNextValue(MOD_PREFIX .. id)
	return value == true
end

---@param id string
---@param default number
---@return number
local function get_setting_number(id, default)
	return tonumber(ModSettingGetNextValue(MOD_PREFIX .. id)) or default
end

---@param id string
---@param default string|nil
---@return string
local function get_setting_string(id, default)
	local value = ModSettingGetNextValue(MOD_PREFIX .. id)
	return type(value) == "string" and value:match("^%s*(.-)%s*$") or default or ""
end

---@class haptic_noita
---@field session table|nil
---@field haptics table|nil
---@field events table|nil
---@field started boolean
---@field enabled boolean
---@field master_intensity number
---@field device_name string
---@field host string
---@field port number|nil
---@field pending_test_until number
---@field published_devices table|nil
---@field published_status string|nil
---@field last_reported_state string|nil
---@field retry_delay number
---@field retry_at number
local haptic_noita = {
	session = nil,
	haptics = nil,
	events = nil,
	started = false,
	enabled = true,
	master_intensity = 1.0,
	device_name = "",
	host = "127.0.0.1",
	port = 12345,
	pending_test_until = 0,
	published_devices = nil,
	published_status = nil,
	last_reported_state = nil,
	retry_delay = RECONNECT_MIN_SECONDS,
	retry_at = 0,
}

---Refresh runtime settings from the mod settings store.
function haptic_noita:read_settings()
	self.enabled = get_setting_boolean("enabled")
	self.master_intensity = get_setting_number("intensity", 1.0)
	self.device_name = get_setting_string("device_name")
	self.host = get_setting_string("host", "127.0.0.1")
	local port = tonumber(get_setting_string("port", "12345"))
	self.port = port and port % 1 == 0 and port >= 1 and port <= 65535 and port or nil
	if self.haptics then
		self.haptics.master_intensity = self.master_intensity
		self.haptics.debug = get_setting_boolean("debug_print")
	end
	if self.events then
		for _, key in ipairs(events_lib.TYPES) do
			self.events[key .. "_enabled"] = get_setting_boolean(key .. "_enabled")
			self.events[key .. "_intensity"] = get_setting_number(key .. "_intensity", 1)
		end
	end
end

---@param text string
function haptic_noita:log(text)
	GamePrint("[haptic] " .. text)
end

---@param intensity number 0..1 before the master scale
---@param duration_seconds number
---@return boolean queued
function haptic_noita:pulse(intensity, duration_seconds)
	if not self.started or not self.enabled then return false end
	return self.haptics:pulse(intensity, duration_seconds)
end

---@param source string
---@param intensity number 0..1 before the master scale
function haptic_noita:set_sustain(source, intensity)
	if not self.started or not self.enabled then return end
	self.haptics:set_sustain(source, intensity)
end

function haptic_noita:release()
	if self.started then self.haptics:release() end
end

function haptic_noita:stop()
	if self.started then self.haptics:stop_all() end
end

---@return boolean
function haptic_noita:is_ready()
	return self.started and self.enabled and self.haptics:is_ready()
end

function haptic_noita:connect()
	if not self.port or not intiface.parse_ipv4(self.host) then
		self:log("enter a valid IPv4 address and port (1-65535)")
		return false
	end
	self.session.error = nil
	local ok, err = self.session:connect()
	if not ok then
		self:log("connect failed: " .. tostring(err))
		self:schedule_retry()
	end
	return ok
end

function haptic_noita:schedule_retry()
	self.retry_at = haptics_lib.now() + self.retry_delay
	self.retry_delay = math.min(self.retry_delay * 2, RECONNECT_MAX_SECONDS)
end

---@param state string
function haptic_noita:report_state(state)
	local reported_state = state == "open" and self:is_ready() and "ready" or state
	if reported_state == self.last_reported_state then return end
	self.last_reported_state = reported_state

	if reported_state == "ready" then
		self.retry_delay = RECONNECT_MIN_SECONDS
		self.retry_at = 0
		self:log("connected")
		return
	end

	if state ~= "idle" then return end

	if not self.enabled then
		self.retry_at = 0
		return
	end
	if self.session.closed_by_request then
		self.retry_at = 0
		self:log("disconnected")
		return
	end
	self:log("disconnected: " .. tostring(self.session.error or "unknown reason"))
	self:schedule_retry()
end

---Expose the connected device list to the separate settings Lua environment.
function haptic_noita:publish_devices()
	local indices = {}
	if self.session.client.state == "open" then
		for index in pairs(self.session.devices) do
			indices[#indices + 1] = index
		end
		table.sort(indices)
	end
	local devices = {}
	for _, index in ipairs(indices) do
		local device = self.session.devices[index]
		local name = device.name or device.display_name
		if name then devices[#devices + 1] = { index, name, device.display_name or name } end
	end
	local previous = self.published_devices
	local changed = true
	if previous and #previous == #devices then
		changed = false
		for position, device in ipairs(devices) do
			local old = previous[position]
			if old[1] ~= device[1] or old[2] ~= device[2] or old[3] ~= device[3] then
				changed = true
				break
			end
		end
	end
	if not changed then return end
	for position, device in ipairs(devices) do
		local prefix = MOD_PREFIX .. "device_" .. position
		ModSettingSet(prefix .. "_index", device[1])
		ModSettingSet(prefix .. "_name", device[2])
		ModSettingSet(prefix .. "_display", device[3])
	end
	ModSettingSet(MOD_PREFIX .. "device_count", #devices)
	self.published_devices = devices
end

---Publish a concise connection state for the settings menu.
function haptic_noita:publish_status()
	local status
	if not self.enabled then
		status = "disabled"
	elseif not self.port or not intiface.parse_ipv4(self.host) then
		status = "invalid"
	elseif self.session.client.state == "open" then
		status = self:is_ready() and "ready" or "no-device"
	elseif self.session.client.state == "connecting" or self.session.client.state == "handshaking" then
		status = "connecting"
	else
		status = "disconnected"
	end
	if status ~= self.published_status then
		ModSettingSet(MOD_PREFIX .. "connection_status", status)
		self.published_status = status
	end
end

---Apply menu changes and button requests while the game is paused.
function haptic_noita:update_paused()
	if not self.started then return end
	self:apply_settings()
	if self.events then self.events:pause() end
	if ModSettingGet(MOD_PREFIX .. "connect_request") == true then
		ModSettingSet(MOD_PREFIX .. "connect_request", false)
		self:settings_connect()
	end
	if ModSettingGet(MOD_PREFIX .. "test_request") == true then
		ModSettingSet(MOD_PREFIX .. "test_request", false)
		self:settings_test()
	end
	self:update()
end

---Poll the connection and send gameplay haptics.
function haptic_noita:update()
	if not self.started then return end
	if not self.enabled then
		self:publish_devices()
		self:publish_status()
		return
	end

	local state = self.session:update()
	self:publish_devices()
	self:publish_status()
	self:report_state(state)
	if self.pending_test_until > 0 then
		if state == "idle" or haptics_lib.now() >= self.pending_test_until then
			self.pending_test_until = 0
		elseif self:is_ready() then
			self.pending_test_until = 0
			self:pulse(0.3, 0.3)
		end
	end
	self.haptics:update()

	if state == "idle" then
		if self.retry_at > 0 and haptics_lib.now() >= self.retry_at then
			self.retry_at = 0
			self:connect()
		end
		return
	end
end

---Create the session, optionally connecting immediately.
---@param connect_now boolean
function haptic_noita:start(connect_now)
	if self.started then return end
	self.started = true

	self:read_settings()
	self.session = intiface.new_session({
		host = self.host,
		port = self.port,
		client_name = "Haptic Noita",
		device_name = self.device_name,
		on_log = function(text)
			self:log(text)
		end,
	})
	self.haptics = haptics_lib.new(self.session)
	self.events = events_lib.new(self.haptics)
	self.haptics.master_intensity = self.master_intensity
	self:read_settings()
	self:publish_devices()
	if self.enabled and connect_now then self:connect() end
	self:publish_status()
end

function haptic_noita:on_player_spawned(player_entity)
	self:start(true)
	self.events:attach_player(player_entity)
end

function haptic_noita:on_world_post_update()
	if self.started and self.enabled and self.events then self.events:update(haptics_lib.now()) end
	self:update()
end

---OnWorldPostUpdate never runs while paused, but pulses must keep decaying.
function haptic_noita:on_pause_pre_update()
	self:update_paused()
end

function haptic_noita:apply_settings()
	if not self.started then return end
	local was_enabled = self.enabled
	local old_device_name = self.device_name
	local old_host = self.host
	local old_port = self.port
	self:read_settings()
	if was_enabled == self.enabled and old_device_name == self.device_name and old_host == self.host and old_port == self.port then return end

	if was_enabled then self:stop() end
	if was_enabled == self.enabled and old_host == self.host and old_port == self.port then
		self.session.device_name = self.device_name
		self.session.ready = self.session.client.state == "open" and self.session:find_vibrate_feature() ~= nil
		self.session.output_generation = self.session.output_generation + 1
		self.last_reported_state = nil
		return
	end
	self.session:disconnect()
	self.haptics:update()
	self.session.device_name = self.device_name
	self.session.host = self.host
	self.session.port = self.port
	self.retry_at = 0
	if self.enabled and self.port and intiface.parse_ipv4(self.host) then
		self:connect()
	else
		self.pending_test_until = 0
	end
end

---Connect from the settings menu and request a fresh device list.
function haptic_noita:settings_connect()
	if not self.started then self:start(false) end
	self.pending_test_until = 0
	if not self.enabled then
		self:log("enable the mod before connecting")
		return false
	end
	if not self.port or not intiface.parse_ipv4(self.host) then
		self:log("enter a valid IPv4 address and port (1-65535)")
		return false
	end
	self:stop()
	self.session:disconnect()
	self.retry_at = 0
	return self:connect()
end

---Send a short pulse, connecting first if needed.
function haptic_noita:settings_test()
	if not self.started or not self:is_ready() then
		if self:settings_connect() then self.pending_test_until = haptics_lib.now() + TEST_WAIT_SECONDS end
		return
	end
	self:pulse(0.3, 0.3)
end

return haptic_noita
