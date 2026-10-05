local draw_actions_for_shot_original = _draw_actions_for_shot

---Publish the finished cast's net recoil (spells add, Recoil Damper subtracts) for the event poll.
---gun.lua also runs for enemy and modded wands, so only a wand held by the player may publish.
_draw_actions_for_shot = function(...)
	local result = draw_actions_for_shot_original(...)
	local owner = EntityGetRootEntity(GetUpdatedEntityID())
	if owner ~= 0 and EntityHasTag(owner, "player_unit") then
		GlobalsSetValue("haptic_noita.shot_recoil", tostring(shot_effects.recoil_knockback or 0))
	end
	return result
end
