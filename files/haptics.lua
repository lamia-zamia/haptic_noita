-- Game events to device output: timed patterns plus rate limiting.
-- Design rationale lives in docs/README.md.
local haptics = {}

local MAX_INTENSITY = 1.0
local MAX_PULSES = 32
local DEBUG_STEPS = 20

---@return number
local function now()
	return GameGetRealWorldTimeSinceStarted()
end

---@class Haptics
---@field session table
---@field pulses table[]
---@field sustains table<string, number>
---@field master_intensity number
---@field current_step number|nil nil until this connection has been spoken to
---@field last_command_at number|nil
---@field output_generation number|nil
---@field debug boolean print events instead of needing a device
local Haptics = {}
Haptics.__index = Haptics

---@param session table from intiface.new_session
---@return Haptics
function haptics.new(session)
	return setmetatable({
		session = session,
		pulses = {},
		sustains = {},
		master_intensity = 1.0,
		current_step = nil,
		last_command_at = nil,
		output_generation = nil,
		debug = false,
	}, Haptics)
end

---@param text string
function Haptics:debug_log(text)
	if self.debug then print(string.format("[haptic %7.2f] %s", now(), text)) end
end

---With debug on, the mod pretends a device exists and prints instead of sending.
---@return boolean
function Haptics:is_ready()
	return self.debug or self.session:is_ready()
end

---@param intensity number
---@return number|nil step nil when no device is available
function Haptics:step_for(intensity)
	local _, _, low, high = self.session:find_vibrate_feature()
	if not low then
		if not self.debug then return nil end
		low, high = 0, DEBUG_STEPS
	end
	intensity = math.max(0.0, math.min(MAX_INTENSITY, intensity or 0.0))
	local step = math.floor((high - low) * intensity + 0.5)
	if intensity > 0 and step == 0 and high > low then step = 1 end
	return low + step
end

---@param intensity number 0..1
---@param duration_seconds number
---@return boolean queued
function Haptics:pulse(intensity, duration_seconds)
	return self:pattern({ { duration_seconds, intensity } })
end

---@param segments table[] ordered {duration_seconds, intensity} pairs
---@return boolean queued
function Haptics:pattern(segments)
	if not self:is_ready() then return false end
	local gap = self.session:timing_gap_ms() / 1000
	local timeline, duration, peak = {}, 0, 0
	for _, segment in ipairs(segments) do
		local length = segment[1]
		local intensity = math.max(0, math.min(MAX_INTENSITY, segment[2] or 0))
		if length and length > 0 then
			duration = duration + math.max(length, gap)
			timeline[#timeline + 1] = { ends_after = duration, intensity = intensity }
			peak = math.max(peak, intensity)
		end
	end
	if peak <= 0 then return false end
	if #self.pulses >= MAX_PULSES then
		-- Full: evict the weakest, so a weak event cannot displace a strong one.
		local weakest = 1
		for index = 2, #self.pulses do
			if self.pulses[index].peak < self.pulses[weakest].peak then weakest = index end
		end
		if self.pulses[weakest].peak >= peak then return false end
		table.remove(self.pulses, weakest)
	end
	local started = now()
	if self.debug then
		local parts = {}
		for _, segment in ipairs(segments) do
			parts[#parts + 1] = string.format("%.0f%%x%dms", (segment[2] or 0) * 100, (segment[1] or 0) * 1000)
		end
		self:debug_log(string.format("PATTERN peak %.0f%% total %dms: %s", peak * 100, duration * 1000, table.concat(parts, " ")))
	end
	self.pulses[#self.pulses + 1] = {
		peak = peak,
		segments = timeline,
		starts_at = started,
		ends_at = started + duration,
	}
	return true
end

---@param source string
---@param intensity number 0..1
function Haptics:set_sustain(source, intensity)
	intensity = math.max(0.0, math.min(MAX_INTENSITY, intensity or 0.0))
	local active = intensity > 0
	if self.debug and active ~= (self.sustains[source] ~= nil) then
		self:debug_log(string.format("SUSTAIN %s %s%s", source, active and "start " or "stop", active and string.format("%.0f%%", intensity * 100) or ""))
	end
	self.sustains[source] = active and intensity or nil
end

function Haptics:release()
	self.sustains = {}
end

function Haptics:stop_all()
	self.pulses = {}
	self.sustains = {}
	self:debug_log("STOP")
	if not self.session:is_ready() then
		-- Cannot send; forget the level so the next ready moment re-asserts one.
		self.current_step = nil
		return
	end
	local device_index = self.session:find_vibrate_feature()
	if self.session:stop_device(device_index) then
		self.current_step = 0
	else
		self.current_step = nil
	end
end

---Strongest level currently requested, dropping expired pulses.
---@return number
function Haptics:desired_intensity()
	local strongest = 0
	for _, intensity in pairs(self.sustains) do
		strongest = math.max(strongest, intensity)
	end
	local timestamp = now()
	local kept = {}
	for _, pulse in ipairs(self.pulses) do
		if pulse.ends_at > timestamp then
			kept[#kept + 1] = pulse
			local elapsed = timestamp - pulse.starts_at
			for _, segment in ipairs(pulse.segments) do
				if elapsed < segment.ends_after then
					strongest = math.max(strongest, segment.intensity)
					break
				end
			end
		end
	end
	self.pulses = kept
	return strongest * self.master_intensity
end

---Send whatever change is due. Call once per game frame.
---@return string action "sent", "waiting", "idle" or "no-device"
function Haptics:update()
	local ready = self.session:is_ready()
	if self.output_generation ~= self.session.output_generation then
		self.output_generation = self.session.output_generation
		self.current_step = nil
		if not ready then self.last_command_at = nil end
	end
	if not ready and not self.debug then
		self.current_step = nil
		return "no-device"
	end

	local device_index, feature_index = self.session:find_vibrate_feature()
	local step = self:step_for(self:desired_intensity())

	if not device_index and self.debug and step then
		if step == self.current_step then return "idle" end
		self:debug_log(string.format("LEVEL %d/%d (%.0f%%)", step, DEBUG_STEPS, step / DEBUG_STEPS * 100))
		self.current_step = step
		return "sent"
	end

	if not device_index or not step then
		-- Device went away mid-connection: the level is unknown, not zero.
		self.current_step = nil
		return "no-device"
	end

	if self.current_step ~= nil and step == self.current_step then return "idle" end

	local timestamp = now()
	local gap_seconds = self.session:timing_gap_ms() / 1000
	if self.last_command_at and timestamp - self.last_command_at < gap_seconds then return "waiting" end

	if self.session:set_vibrate(device_index, feature_index, step) then
		self:debug_log(string.format("SEND level %d/%d", step, select(4, self.session:find_vibrate_feature())))
		self.current_step = step
		self.last_command_at = timestamp
		return "sent"
	end
	self.current_step = nil
	return "waiting"
end

haptics.now = now
haptics.MAX_INTENSITY = MAX_INTENSITY
haptics.MAX_PULSES = MAX_PULSES

return haptics
