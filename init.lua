local haptic_noita = dofile_once("mods/haptic_noita/files/haptic_noita.lua") ---@type haptic_noita

ModLuaFileAppend("data/scripts/gun/gun.lua", "mods/haptic_noita/files/gun_hook.lua")

function OnPlayerSpawned(player_entity)
	haptic_noita:on_player_spawned(player_entity)
end

function OnWorldPostUpdate()
	haptic_noita:on_world_post_update()
end

function OnPausePreUpdate()
	haptic_noita:on_pause_pre_update()
end
