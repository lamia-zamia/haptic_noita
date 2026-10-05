See also [protocol.md](protocol.md) and [ffi-notes.md](ffi-notes.md) (read the
latter before touching FFI code).

## Runtime

- Everything runs on the main thread, so all socket calls must be non-blocking.
- Pattern lifetimes use `GameGetRealWorldTimeSinceStarted()`; the connect timeout
  uses `GetTickCount()` and stays inside `files/net.lua`. A hung socket must not
  stall a pattern that is trying to expire.
- `settings.lua` must never load the socket runtime. Button requests, device
  names and connection status cross to the game hooks through mod settings.
- Remote IPs use plaintext, unauthenticated WebSockets.
- Settings sliders: `GuiImage` hit detection is square regardless of scale, so a
  scaled 1px track swallows clicks on rows above it. Input comes from a
  transparent `GuiImageNinePiece` over the track; the images are `NonInteractive`.
  Slider images use `Layout_NoLayouting` and do not advance the layout cursor, so
  `percent_label` uses a layout-relative offset; absolute coordinates move it.

## Mixer

- Output is "desired level now", sent as a difference; overlapping sources mix by
  strongest level. Segments last at least the device's `DeviceMessageTimingGap`.
- `current_step` is `nil` after readiness is lost or a new `DeviceList` arrives,
  so the previous command is never assumed to still apply.
- Command IDs are tracked until Intiface replies; a matching `Error` marks the
  level unknown and it is resent. A server that stops replying is disconnected so
  its device cleanup runs.

## Events

- Damage messages (`$damage_explosion`, ...) are not authoritative damage types;
  shape selection is best effort. Burn ticks go to the fire signal, not pulses.
- Pickups, kills and kicks are polled. `script_item_picked_up`, `script_kick` and
  `script_interacting` are delivered to the item/kicked/interacted entity, not the
  player, so a player-side `LuaComponent` never sees them. Orb count rising is a
  full pickup; perk count (children tagged `perk_entity`) or max HP rising is 75%.
- `script_biome_entered` needs a `BiomeTrackerComponent` on the player; one is
  added when missing. The first report after spawn is ignored.
- Polymorph gives the player new entity and component ids. Ids are re-checked
  every update and everything reattaches on change, resetting polled baselines so
  the rebuild does not read as a pickup.

## Wand shots

`script_shot` fires per projectile; callbacks on one frame merge into one cast.

- Cadence: `1/(1+(gap/6)^1.5)` over frames between casts, EMA 0.6/0.4, reset
  after a 30-frame gap, pause, death, reattach, or no ready device.
- Power: `1-exp(-raw/10)`, `raw` = max of direct plus typed damage, explosion
  damage, `knockback_force*0.27` (target knockback, not player recoil) and
  `camera_shake_when_shot*2` (Spark Bolt 0.1, Laser Beam class 2.4, nuke 15.5).
- Felt if cadence >= 0.35 or power >= 0.35.
- Level: `0.10 + max(0.32r, 0.52s) + 0.10*min(r,s)` with `r`, `s` the cadence and
  power scores rescaled above their thresholds; times a multicast factor
  `1 + 0.15*log(count)/log(8)` (count capped at 8); times a recoil factor
  `0.6 + 0.4*clamp(log(1+recoil)/log(501))`.
- Recoil is the cast's net `shot_effects.recoil_knockback` (spells add 10..200,
  nuke 650, Recoil Damper -200), published by `files/gun_hook.lua` only when the
  wand's root entity is the player (enemy wands run the same script). The
  `script_shot` callback does not identify the wand.
  `AbilityComponent.mItemRecoil` is unusable: it reads 1 on every cast.
- Mana cost is unusable: no cast-local cost, and Add Mana distorts net mana.
- Output is one "shots" sustain refreshed per felt cast: held 0.14 s, fade 0.1 s.

## Screen shake

There is no Lua getter, and the player's `screenshake_intensity` setting scales
the camera effect to zero. `files/screenshake.lua` finds the global game pointer
by scanning the exe's code sections for the inlined lazy accessor
(`mov eax,[G]; test eax,eax; jne; push 0x1A0; call [new]`; two sites must agree)
and reads `*(*(*G + 0x0C) + 0x58)`. Only the struct offsets are constants.

- Every pointer is checked with `VirtualQuery` first, because `pcall` cannot
  catch an access violation. Unreadable pointers, implausible trauma or failed
  discovery permanently disable the event and log once.
- Trauma only rises through a new shake (decay x0.9/frame), so a rise is the
  event. Strength `0.3 + 0.7*log(trauma/10)/log(10)`; below 10 is ignored
  (ambient noise 1..7.5); dynamite 20, wand nukes 60, 100+ is full.
- Dynamite re-raises the same trauma for 5 frames: rises within 0.5 s count only
  if 25% higher.
- Distance attenuation is already in the value, but the source position is not
  stored, so off-screen shakes can only be filtered by raising the floor.

## Debug print

`haptic_noita.debug_print` (Advanced) makes `Haptics:is_ready()` true without a device, with a
virtual 0-20 range; nothing is sent to Intiface unless a real device is present. Use CE to enable or whatever.
