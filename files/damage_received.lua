local DAMAGE_FRAME_KEY = "haptic_noita.damage_frame"
local DAMAGE_FRACTION_KEY = "haptic_noita.damage_fraction"
local DAMAGE_MESSAGE_KEY = "haptic_noita.damage_message"
local DEATH_FRAME_KEY = "haptic_noita.death_frame"
local SHOT_FRAME_KEY = "haptic_noita.shot_frame"
local SHOT_POWER_KEY = "haptic_noita.shot_power"
local SHOT_COUNT_KEY = "haptic_noita.shot_count"
local TELEPORT_FRAME_KEY = "haptic_noita.teleport_frame"
local POLYMORPH_FRAME_KEY = "haptic_noita.polymorph_frame"
local BIOME_FRAME_KEY = "haptic_noita.biome_frame"
local DAMAGE_TYPES = { "melee", "explosion", "electricity", "slice", "ice", "curse", "drill", "fire", "radioactive", "holy" }

function damage_received(damage, message)
	if damage <= 0 then return end
	local player = GetUpdatedEntityID()
	local damage_model = EntityGetFirstComponentIncludingDisabled(player, "DamageModelComponent")
	if not damage_model then return end
	local max_hp = ComponentGetValue2(damage_model, "max_hp")
	if not max_hp or max_hp <= 0 then return end
	if message == "$damage_fire" and ComponentGetValue2(damage_model, "is_on_fire") then
		local burn_damage = ComponentGetValue2(damage_model, "fire_damage_amount") or 0
		if damage <= burn_damage * 1.1 then return end
	end

	local fraction = math.min(1, damage / max_hp)
	local frame = GameGetFrameNum()
	if tonumber(GlobalsGetValue(DAMAGE_FRAME_KEY, "-1")) == frame then
		fraction = math.min(1, fraction + (tonumber(GlobalsGetValue(DAMAGE_FRACTION_KEY, "0")) or 0))
	end
	-- Retain the cause token from the latest hit in the cluster for shape selection.
	GlobalsSetValue(DAMAGE_MESSAGE_KEY, tostring(message or ""))
	GlobalsSetValue(DAMAGE_FRACTION_KEY, tostring(fraction))
	GlobalsSetValue(DAMAGE_FRAME_KEY, tostring(frame))
end

function death()
	GlobalsSetValue(DEATH_FRAME_KEY, tostring(GameGetFrameNum()))
end

-- Projectile damage units (1 = 25 shown HP); knockback is scaled to the same range.
local SHOT_POWER_SCALE = 10
local KNOCKBACK_TO_DAMAGE = 0.27
-- camera_shake_when_shot is the game's own "this cast is substantial" tag.
local SHAKE_TO_DAMAGE = 2

---One call per projectile; calls on the same frame merge into one logical cast.
function shot(projectile_entity_id)
	local frame = GameGetFrameNum()
	local projectile = projectile_entity_id and EntityGetFirstComponentIncludingDisabled(projectile_entity_id, "ProjectileComponent")
	local damage = projectile and ComponentGetValue2(projectile, "damage") or 0
	local knockback = projectile and ComponentGetValue2(projectile, "knockback_force") or 0
	local shot_shake = projectile and ComponentGetValue2(projectile, "camera_shake_when_shot") or 0
	if projectile then
		for _, damage_type in ipairs(DAMAGE_TYPES) do
			damage = damage + (ComponentObjectGetValue2(projectile, "damage_by_type", damage_type) or 0)
		end
	end
	local explosion_damage = projectile and ComponentObjectGetValue2(projectile, "config_explosion", "damage") or 0
	local raw = math.max(damage, explosion_damage, knockback * KNOCKBACK_TO_DAMAGE, shot_shake * SHAKE_TO_DAMAGE)
	local power = 1 - math.exp(-raw / SHOT_POWER_SCALE)
	local count = 1
	if tonumber(GlobalsGetValue(SHOT_FRAME_KEY, "-1")) == frame then
		power = math.max(power, tonumber(GlobalsGetValue(SHOT_POWER_KEY, "0")) or 0)
		count = count + (tonumber(GlobalsGetValue(SHOT_COUNT_KEY, "0")) or 0)
	end
	GlobalsSetValue(SHOT_POWER_KEY, tostring(power))
	GlobalsSetValue(SHOT_COUNT_KEY, tostring(count))
	GlobalsSetValue(SHOT_FRAME_KEY, tostring(frame))
end

function teleported()
	GlobalsSetValue(TELEPORT_FRAME_KEY, tostring(GameGetFrameNum()))
end

function polymorphing_to()
	GlobalsSetValue(POLYMORPH_FRAME_KEY, tostring(GameGetFrameNum()))
end

function biome_entered(biome_name, biome_old_name)
	-- The tracker's first report after spawn has no previous biome to leave.
	if not biome_old_name or biome_old_name == "" or biome_name == biome_old_name then return end
	GlobalsSetValue(BIOME_FRAME_KEY, tostring(GameGetFrameNum()))
end
