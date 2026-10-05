local events = {}
events.__index = events

---Setting keys; each has `<key>_enabled` and `<key>_intensity` fields on the collector.
events.TYPES = {
	"damage",
	"fire",
	"low_hp",
	"healing",
	"drowning",
	"shots",
	"death",
	"teleport",
	"polymorph",
	"pickups",
	"kills",
	"kick",
	"biome",
	"screenshake",
}

local CALLBACK_SCRIPT = "mods/haptic_noita/files/damage_received.lua"
local CALLBACK_FIELDS =
	{ "script_damage_received", "script_death", "script_shot", "script_teleported", "script_polymorphing_to", "script_biome_entered" }
local DAMAGE_FRACTION_KEY = "haptic_noita.damage_fraction"
local DAMAGE_MESSAGE_KEY = "haptic_noita.damage_message"
local SHOT_POWER_KEY = "haptic_noita.shot_power"
local SHOT_COUNT_KEY = "haptic_noita.shot_count"
local SHOT_RECOIL_KEY = "haptic_noita.shot_recoil" -- written by gun_hook.lua
local CALLBACK_FRAME_KEYS = {
	damage = "haptic_noita.damage_frame",
	death = "haptic_noita.death_frame",
	shot = "haptic_noita.shot_frame",
	teleport = "haptic_noita.teleport_frame",
	polymorph = "haptic_noita.polymorph_frame",
	biome = "haptic_noita.biome_frame",
}
-- Wand shots: cadence (from the gap between cast frames) OR projectile power
-- makes a shot felt; the level is a refreshed envelope, not a queued pulse.
local SHOT_IDLE_FRAMES = 30 -- longer gap: cadence history is stale
local SHOT_CADENCE_HALF_FRAMES = 6 -- gap that scores 0.5
local SHOT_CADENCE_SMOOTHING = 0.4 -- EMA weight of the newest gap
local SHOT_RAPID_THRESHOLD = 0.35
local SHOT_POWER_THRESHOLD = 0.35
local SHOT_BASE_LEVEL = 0.10
local SHOT_CADENCE_RANGE = 0.32
local SHOT_POWER_RANGE = 0.52
local SHOT_OTHER_RANGE = 0.10
local SHOT_MULTICAST_BONUS = 0.15 -- at 8+ projectiles
local SHOT_RECOIL_FLOOR = 0.6 -- level multiplier when the cast has no recoil
local SHOT_RECOIL_FULL = 500 -- net recoil_knockback that counts as full (log scale; seen 50, 100, 650)
local SHOT_HOLD_SECONDS = 0.14
local SHOT_DECAY_SECONDS = 0.10
local BIOME_COOLDOWN_SECONDS = 3
-- Trauma only ever decays (x0.9 per frame), so any rise is a new shake. Game
-- strengths run 1 (boss ticks) to 150 (temple leaks). Measured: ambient noise is
-- 1..7.5, dynamite is 20, wand nukes 60, so the floor sits just above the noise.
local SHAKE_MIN_TRAUMA = 10
local SHAKE_MAX_TRAUMA = 100
local SHAKE_RISE_EPSILON = 0.01
local SHAKE_BASE_STRENGTH = 0.3
local SHAKE_RETRIGGER_SECONDS = 0.5
local SHAKE_RETRIGGER_GROWTH = 1.25

local screenshake_lib = dofile_once("mods/haptic_noita/files/screenshake.lua") ---@type { new: fun(): screenshake_source }

local function clamp(value)
	return math.max(0, math.min(1, value))
end

---@param name string key of CALLBACK_FRAME_KEYS
---@return number
local function callback_frame(name)
	return tonumber(GlobalsGetValue(CALLBACK_FRAME_KEYS[name], "-1")) or -1
end

---@param player entity_id
---@return integer
local function perk_count(player)
	local perks = EntityGetAllChildren(player, "perk_entity")
	return perks and #perks or 0
end

---@return integer
local function kill_count()
	return tonumber(StatsGetValue("enemies_killed")) or 0
end

---Create a player event collector for the existing mixer.
function events.new(haptics)
	local self = setmetatable({
		haptics = haptics,
		player = nil,
		damage_model = nil,
		controls = nil,
		callback_frames = {},
		last_hp = nil,
		last_max_hp = nil,
		orb_count = 0,
		perk_count = 0,
		kill_count = 0,
		kick_frame = -1,
		next_heartbeat_at = 0,
		next_biome_at = 0,
		shake_source = screenshake_lib.new(),
		last_trauma = 0,
		last_shake_trauma = 0,
		next_shake_at = 0,
	}, events)
	for _, key in ipairs(events.TYPES) do
		self[key .. "_enabled"] = true
		self[key .. "_intensity"] = 1
	end
	self:sync_callback_frames()
	self:reset_shots()
	return self
end

---Treat every callback that already fired as seen.
function events:sync_callback_frames()
	for name in pairs(CALLBACK_FRAME_KEYS) do
		self.callback_frames[name] = callback_frame(name)
	end
end

---@param name string key of CALLBACK_FRAME_KEYS
---@return number|nil frame the callback fired on, if it is new
function events:take_callback(name)
	local frame = callback_frame(name)
	if frame == self.callback_frames[name] then return nil end
	self.callback_frames[name] = frame
	return frame
end

---Attach callbacks to the current player and reset polled baselines.
function events:attach_player(player)
	self.player = player
	self.damage_model = EntityGetFirstComponentIncludingDisabled(player, "DamageModelComponent")
	self.controls = EntityGetFirstComponentIncludingDisabled(player, "ControlsComponent")
	self:sync_callback_frames()
	self:reset_shots()
	self.last_hp = self.damage_model and ComponentGetValue2(self.damage_model, "hp") or nil
	self.last_max_hp = self.damage_model and ComponentGetValue2(self.damage_model, "max_hp") or nil
	self.orb_count = GameGetOrbCountThisRun()
	self.perk_count = perk_count(player)
	self.kill_count = kill_count()
	self.kick_frame = self.controls and ComponentGetValue2(self.controls, "mButtonFrameKick") or -1
	self.next_heartbeat_at = 0
	self.haptics:release()
	if not EntityGetFirstComponentIncludingDisabled(player, "BiomeTrackerComponent") then EntityAddComponent2(player, "BiomeTrackerComponent", {}) end
	for _, component in ipairs(EntityGetComponentIncludingDisabled(player, "LuaComponent") or {}) do
		if ComponentGetValue2(component, "script_damage_received") == CALLBACK_SCRIPT then
			for _, field in ipairs(CALLBACK_FIELDS) do
				ComponentSetValue2(component, field, CALLBACK_SCRIPT)
			end
			return
		end
	end
	local values = { execute_every_n_frame = -1 } ---@type {[string]:any}
	for _, field in ipairs(CALLBACK_FIELDS) do
		values[field] = CALLBACK_SCRIPT
	end
	EntityAddComponent2(player, "LuaComponent", values)
end

---Read a delivered damage cluster once and choose its shape.
function events:update_damage()
	local frame = self:take_callback("damage")
	if not frame or not self.damage_enabled then return end
	if self.death_enabled and self.death_intensity > 0 and frame == callback_frame("death") then return end
	local fraction = clamp(tonumber(GlobalsGetValue(DAMAGE_FRACTION_KEY, "0")) or 0)
	if fraction <= 0 then return end
	local strength = fraction ^ 0.7
	local intensity = math.min(1, (0.10 + 0.9 * strength) * self.damage_intensity)
	local message = GlobalsGetValue(DAMAGE_MESSAGE_KEY, "")
	if message == "$damage_explosion" then
		self.haptics:pattern({ { 0.12, intensity }, { 0.16, intensity * 0.45 } })
	elseif message == "$damage_electricity" then
		self.haptics:pattern({ { 0.10, intensity }, { 0.10, 0 }, { 0.10, intensity * 0.7 }, { 0.10, 0 }, { 0.10, intensity * 0.5 } })
	elseif message == "$damage_slice" then
		self.haptics:pulse(intensity, 0.10)
	elseif message == "$damage_poison" or message == "$damage_toxic" then
		self.haptics:pattern({ { 0.18, intensity * 0.6 }, { 0.12, 0 }, { 0.18, intensity * 0.4 } })
	else
		self.haptics:pulse(intensity, 0.16 + 0.12 * strength)
	end
end

function events:reset_shots()
	self.shot_last_frame = nil
	self.shot_cadence = 0
	self.shot_level = 0
	self.shot_until = 0
end

---Fold one logical cast (all projectiles of one frame) into cadence and level.
function events:register_shot(frame, now)
	local power = clamp(tonumber(GlobalsGetValue(SHOT_POWER_KEY, "0")) or 0)
	local count = tonumber(GlobalsGetValue(SHOT_COUNT_KEY, "1")) or 1
	local recoil = math.max(0, tonumber(GlobalsGetValue(SHOT_RECOIL_KEY, "0")) or 0)
	local gap = self.shot_last_frame and frame - self.shot_last_frame
	if gap and gap > 0 and gap <= SHOT_IDLE_FRAMES then
		local instant = 1 / (1 + (gap / SHOT_CADENCE_HALF_FRAMES) ^ 1.5)
		self.shot_cadence = self.shot_cadence * (1 - SHOT_CADENCE_SMOOTHING) + instant * SHOT_CADENCE_SMOOTHING
	else
		self.shot_cadence = 0
	end
	self.shot_last_frame = frame
	local cadence = self.shot_cadence
	if cadence < SHOT_RAPID_THRESHOLD and power < SHOT_POWER_THRESHOLD then return end
	local rapid = clamp((cadence - SHOT_RAPID_THRESHOLD) / (1 - SHOT_RAPID_THRESHOLD))
	local strong = clamp((power - SHOT_POWER_THRESHOLD) / (1 - SHOT_POWER_THRESHOLD))
	local level = SHOT_BASE_LEVEL + math.max(SHOT_CADENCE_RANGE * rapid, SHOT_POWER_RANGE * strong) + SHOT_OTHER_RANGE * math.min(rapid, strong)
	level = level * (1 + SHOT_MULTICAST_BONUS * math.min(1, math.log(math.max(count, 1)) / math.log(8)))
	level = level * (SHOT_RECOIL_FLOOR + (1 - SHOT_RECOIL_FLOOR) * clamp(math.log(1 + recoil) / math.log(1 + SHOT_RECOIL_FULL)))
	self.shot_level = math.min(1, level)
	self.shot_until = now + SHOT_HOLD_SECONDS
end

---Drive the "shots" sustain from the latest cast; it fades once firing stops.
function events:update_shots(now)
	local frame = self:take_callback("shot")
	if not self.haptics:is_ready() then
		self:reset_shots()
	elseif frame then
		self:register_shot(frame, now)
	end
	local fade = clamp((self.shot_until + SHOT_DECAY_SECONDS - now) / SHOT_DECAY_SECONDS)
	local enabled = self.shots_enabled
	self.haptics:set_sustain("shots", enabled and self.shot_level * fade * self.shots_intensity or 0)
end

---Play patterns for one-off player callbacks.
function events:update_callbacks(now)
	if self:take_callback("death") then
		self:reset_shots()
		self.haptics:release()
		if self.death_enabled and self.death_intensity > 0 then
			local strength = self.death_intensity
			self.haptics:pattern({ { 0.22, 0.9 * strength }, { 0.12, 0 }, { 0.2, 0.6 * strength }, { 0.12, 0 }, { 0.4, 0.3 * strength } })
		end
	end
	self:update_shots(now)
	if self:take_callback("teleport") and self.teleport_enabled then
		local strength = self.teleport_intensity
		self.haptics:pattern({
			{ 0.06, 0.2 * strength },
			{ 0.06, 0.4 * strength },
			{ 0.08, 0.6 * strength },
			{ 0.08, 0.35 * strength },
			{ 0.10, 0.15 * strength },
		})
	end
	if self:take_callback("polymorph") and self.polymorph_enabled then
		local strength = self.polymorph_intensity
		self.haptics:pattern({
			{ 0.10, 0.7 * strength },
			{ 0.06, 0.15 * strength },
			{ 0.08, 0.5 * strength },
			{ 0.10, 0.1 * strength },
			{ 0.14, 0.8 * strength },
			{ 0.08, 0.25 * strength },
			{ 0.24, 0.45 * strength },
		})
	end
	if self:take_callback("biome") and self.biome_enabled and now >= self.next_biome_at then
		self.next_biome_at = now + BIOME_COOLDOWN_SECONDS
		self.haptics:pulse(0.12 * self.biome_intensity, 0.3)
	end
end

---Detect orbs, perks, max-HP gains, kills and kicks by polling counters.
function events:update_polled(max_hp)
	local orb_count = GameGetOrbCountThisRun()
	local perks = perk_count(self.player)
	local pickup_strength = 0
	if orb_count > self.orb_count then
		pickup_strength = 1
	elseif perks > self.perk_count or (self.last_max_hp and max_hp > self.last_max_hp) then
		pickup_strength = 0.75
	end
	self.orb_count = orb_count
	self.perk_count = perks
	self.last_max_hp = max_hp
	if pickup_strength > 0 and self.pickups_enabled then
		local strength = pickup_strength * self.pickups_intensity
		self.haptics:pattern({ { 0.08, 0.3 * strength }, { 0.06, 0 }, { 0.16, 0.6 * strength } })
	end

	local kills = kill_count()
	if kills > self.kill_count and self.kills_enabled then self.haptics:pulse(0.14 * self.kills_intensity, 0.06) end
	self.kill_count = kills

	local kick_frame = self.controls and ComponentGetValue2(self.controls, "mButtonFrameKick") or -1
	if kick_frame ~= self.kick_frame and self.kick_enabled then self.haptics:pulse(0.22 * self.kick_intensity, 0.06) end
	self.kick_frame = kick_frame
end

---Rumble on a new screen shake (explosions, nukes, earthquakes), read from the
---engine's trauma value so it ignores the player's screenshake setting.
function events:update_screenshake(now)
	local trauma = self.shake_source:read()
	if not trauma then return end
	local rising = trauma > self.last_trauma + SHAKE_RISE_EPSILON
	self.last_trauma = trauma
	if not rising or not self.screenshake_enabled or trauma < SHAKE_MIN_TRAUMA then return end
	-- A source that re-raises the same trauma every frame (dynamite does, 5 frames) is one shake.
	if now < self.next_shake_at and trauma < self.last_shake_trauma * SHAKE_RETRIGGER_GROWTH then return end
	self.next_shake_at = now + SHAKE_RETRIGGER_SECONDS
	self.last_shake_trauma = trauma
	local scale = math.log(trauma / SHAKE_MIN_TRAUMA) / math.log(SHAKE_MAX_TRAUMA / SHAKE_MIN_TRAUMA)
	local strength = clamp(SHAKE_BASE_STRENGTH + (1 - SHAKE_BASE_STRENGTH) * scale) * self.screenshake_intensity
	self.haptics:pattern({
		{ 0.10, strength },
		{ 0.15, strength * 0.6 },
		{ 0.20, strength * 0.35 },
		{ 0.25, strength * 0.15 },
	})
end

---Apply continuous sources and a periodic low-health heartbeat.
function events:update_state(now)
	local damage_model = self.damage_model
	if not damage_model then
		self.haptics:release()
		return
	end
	local hp = ComponentGetValue2(damage_model, "hp")
	local max_hp = ComponentGetValue2(damage_model, "max_hp")
	if not hp or not max_hp or max_hp <= 0 or hp <= 0 then
		self.haptics:release()
		return
	end
	self:update_polled(max_hp)
	if self.healing_enabled and self.last_hp and hp > self.last_hp then
		self.haptics:pattern({ { 0.10, 0.16 * self.healing_intensity }, { 0.10, 0 }, { 0.14, 0.28 * self.healing_intensity } })
	end
	self.last_hp = hp
	local fire = ComponentGetValue2(damage_model, "is_on_fire")
	local burn = math.floor(now / 0.25) % 2 == 0 and 0.12 or 0.20
	self.haptics:set_sustain("fire", fire and self.fire_enabled and burn * self.fire_intensity or 0)
	local air = ComponentGetValue2(damage_model, "air_in_lungs")
	local air_max = ComponentGetValue2(damage_model, "air_in_lungs_max")
	local air_urgency = air and air_max and air_max > 0 and clamp((0.5 - air / air_max) / 0.5) or 0
	self.haptics:set_sustain("drowning", self.drowning_enabled and 0.30 * air_urgency * self.drowning_intensity or 0)
	local health = hp / max_hp
	if not self.low_hp_enabled or health >= 0.3 then
		self.next_heartbeat_at = 0
		return
	end
	if now < self.next_heartbeat_at then return end
	local urgency = clamp((0.3 - health) / 0.3)
	local strength = self.low_hp_intensity
	self.haptics:pattern({ { 0.10, (0.16 + 0.06 * urgency) * strength }, { 0.10, 0 }, { 0.12, (0.10 + 0.04 * urgency) * strength } })
	self.next_heartbeat_at = now + 1.2 - 0.75 * urgency
end

---Polymorph gives the player a new entity id and new component ids, so cached
---ids go stale; reattach whenever the player or its damage model changes.
---@return boolean present
function events:refresh_player()
	local player = EntityGetWithTag("player_unit")[1]
	if not player then
		self.haptics:release()
		return false
	end
	local damage_model = EntityGetFirstComponentIncludingDisabled(player, "DamageModelComponent")
	if player ~= self.player or damage_model ~= self.damage_model then self:attach_player(player) end
	return true
end

---Collect current player events before the mixer sends output.
function events:update(now)
	if not self.player then return end
	self:update_damage()
	self:update_callbacks(now)
	self:update_screenshake(now)
	if self:refresh_player() then self:update_state(now) end
end

---Silence continuous state while the game is paused.
function events:pause()
	self:sync_callback_frames()
	self:reset_shots()
	self.haptics:release()
end

return events
