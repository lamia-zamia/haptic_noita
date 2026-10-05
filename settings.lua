---@diagnostic disable: undefined-global
dofile_once("data/scripts/lib/mod_settings.lua")

local mod_id = "haptic_noita"
local mod_prefix = mod_id .. "."
local slider_dragging
local slider_width = 42
local slider_image = "data/debug/whitebox.png"
local checkbox_frame = "data/ui_gfx/decorations/9piece0_gray.png"
local checkbox_frame_hover = "data/ui_gfx/decorations/9piece0.png"
local name_column_width = 100
local event_checkbox_offset = 60
local event_slider_offset = 74
local event_name_color = { 0.85, 0.85, 0.82, 1 }
local intensity_range = { 0.0, 1.0 }

---@param setting table
---@return string
local function setting_id(setting)
	return mod_prefix .. setting.id
end

---@param setting table
---@param value any coerced value currently pending
---@param value_new any
local function commit(setting, value, value_new)
	if value ~= value_new then ModSettingSetNextValue(setting_id(setting), value_new, false) end
end

---@param gui any
---@param in_main_menu boolean
---@param setting table
local function show_tooltip(gui, in_main_menu, setting)
	mod_setting_tooltip(mod_id, gui, in_main_menu, setting)
end

---@param gui any
---@param name string
---@param name_color number[]|nil
---@return number x
---@return number y
---@return number name_width
local function begin_row(gui, name, name_color)
	GuiLayoutBeginHorizontal(gui, 0, 0)
	if name_color then GuiColorSetForNextWidget(gui, name_color[1], name_color[2], name_color[3], name_color[4]) end
	GuiText(gui, mod_setting_group_x_offset, 0, name)
	local _, _, _, x, y, name_width = GuiGetPreviousWidgetInfo(gui)
	return x, y, name_width
end

---@param gui any
---@param name_width number
---@param slider_offset number slider position relative to the row name
---@param value number
local function percent_label(gui, name_width, slider_offset, value)
	GuiColorSetForNextWidget(gui, 0.82, 0.82, 0.78, 1)
	GuiText(gui, slider_offset + slider_width + 4 - name_width, 0, string.format("%3.0f%%", value * 100))
end

---Fake 1px
---@param gui gui
---@param id integer
---@param x number
---@param y number
---@param scale_x number
---@param scale_y number
local function gui_image_px(gui, id, x, y, scale_x, scale_y)
	GuiImage(gui, id, x, y, slider_image, 1, scale_x / 20, scale_y / 20)
end

---@param gui any
---@param in_main_menu boolean
---@param im_id number
---@param setting table
---@param x number
---@param y number
---@return number value_new
local function draw_intensity_slider(gui, in_main_menu, im_id, setting, x, y)
	local setting_key = setting_id(setting)
	local value = tonumber(ModSettingGetNextValue(setting_key)) or setting.value_default
	GuiOptionsAddForNextWidget(gui, GUI_OPTION.NonInteractive)
	GuiOptionsAddForNextWidget(gui, GUI_OPTION.Layout_NoLayouting)
	GuiZSetForNextWidget(gui, 2)
	GuiColorSetForNextWidget(gui, 0.31, 0.29, 0.25, 1)
	gui_image_px(gui, im_id * 10 + 1, x, y + 3, slider_width, 5)
	GuiImageNinePiece(gui, im_id * 10, x, y, slider_width + 30, 10, 0) -- tooltip hoverbox, includes label
	show_tooltip(gui, in_main_menu, setting)
	GuiImageNinePiece(gui, im_id * 10 + 5, x, y + 3, slider_width, 5, 0)
	local _, _, hovered = GuiGetPreviousWidgetInfo(gui)

	if hovered and InputIsMouseButtonJustDown(1) then slider_dragging = setting_key end
	if not InputIsMouseButtonDown(1) then slider_dragging = nil end
	local right_clicked = hovered and InputIsMouseButtonJustDown(2)
	local value_new = value
	if right_clicked then
		value_new = setting.value_default
	elseif slider_dragging == setting_key then
		local mouse_x = InputGetMousePosOnScreen()
		local screen_width = GuiGetScreenDimensions(gui)
		local gui_mouse_x = mouse_x * screen_width / 1280
		value_new = math.max(0, math.min(1, (gui_mouse_x - x) / slider_width))
		value_new = math.floor(value_new * 100 + 0.5) / 100
	end
	commit(setting, value, value_new)

	if value_new > 0 then
		GuiOptionsAddForNextWidget(gui, GUI_OPTION.NonInteractive)
		GuiOptionsAddForNextWidget(gui, GUI_OPTION.Layout_NoLayouting)
		GuiZSetForNextWidget(gui, 1)
		GuiColorSetForNextWidget(gui, 0.77, 0.64, 0.42, 1)
		gui_image_px(gui, im_id * 10 + 2, x, y + 3, math.max(1, slider_width * value_new), 5)
	end
	GuiOptionsAddForNextWidget(gui, GUI_OPTION.NonInteractive)
	GuiOptionsAddForNextWidget(gui, GUI_OPTION.Layout_NoLayouting)
	GuiZSetForNextWidget(gui, 0)
	GuiColorSetForNextWidget(gui, (hovered or slider_dragging == setting_key) and 1 or 0.88, 0.85, 0.73, 1)
	gui_image_px(gui, im_id * 10 + 3, x + (slider_width - 2) * value_new, y + 1, 2, 9)
	return value_new
end

local function intensity_slider(_, gui, in_main_menu, im_id, setting)
	local name_x, y, name_width = begin_row(gui, setting.ui_name)
	local value = draw_intensity_slider(gui, in_main_menu, im_id, setting, name_x + name_column_width, y)
	percent_label(gui, name_width, name_column_width, value)
	GuiLayoutEnd(gui)
end

local function event_row(_, gui, in_main_menu, im_id, setting)
	local enabled_setting = setting.enabled_setting
	local enabled = ModSettingGetNextValue(setting_id(enabled_setting))
	if type(enabled) ~= "boolean" then enabled = enabled_setting.value_default end

	local name_x, y, name_width = begin_row(gui, setting.ui_name .. ":", event_name_color)
	show_tooltip(gui, in_main_menu, enabled_setting)
	GuiZSetForNextWidget(gui, 2)
	GuiImageNinePiece(gui, im_id * 10 + 4, name_x + event_checkbox_offset + 1, y + 1.5, 6, 6.5, 1, checkbox_frame, checkbox_frame_hover)
	local clicked, right_clicked = GuiGetPreviousWidgetInfo(gui)
	show_tooltip(gui, in_main_menu, enabled_setting)
	if clicked or right_clicked then
		enabled = right_clicked and enabled_setting.value_default or not enabled
		ModSettingSetNextValue(setting_id(enabled_setting), enabled, false)
	end
	GuiOptionsAddForNextWidget(gui, GUI_OPTION.NonInteractive)
	GuiOptionsAddForNextWidget(gui, GUI_OPTION.Layout_NoLayouting)
	GuiZSetForNextWidget(gui, 0)
	GuiColorSetForNextWidget(gui, enabled and 0.3 or 0.7, enabled and 0.85 or 0.3, 0.3, 1)
	GuiText(gui, name_x + event_checkbox_offset + 2, y, enabled and "V" or "X")
	local value = draw_intensity_slider(gui, in_main_menu, im_id + 1000, setting.intensity_setting, name_x + event_slider_offset, y)
	percent_label(gui, name_width, event_slider_offset, value)
	GuiLayoutEnd(gui)
end

local function aligned_text_input(_, gui, in_main_menu, im_id, setting)
	local value = tostring(ModSettingGetNextValue(setting_id(setting)) or setting.value_default)
	local _, _, name_width = begin_row(gui, setting.ui_name)
	local value_new = GuiTextInput(gui, im_id, name_column_width - name_width - 2, 0, value, setting.field_width or 70, setting.text_max_length)
	show_tooltip(gui, in_main_menu, setting)
	GuiLayoutEnd(gui)
	commit(setting, value, value_new)
end

---@param request_id string setting the runtime watches
---@param main_menu_name string label used where the button cannot work
---@param draw_after function|nil extra text drawn under the button
---@return function
local function request_button(request_id, main_menu_name, draw_after)
	return function(_, gui, in_main_menu, im_id, setting)
		if in_main_menu then
			GuiText(gui, mod_setting_group_x_offset, 0, main_menu_name)
			return
		end
		if GuiButton(gui, im_id, mod_setting_group_x_offset, 0, setting.ui_name) then ModSettingSet(mod_prefix .. request_id, true) end
		show_tooltip(gui, in_main_menu, setting)
		if draw_after then draw_after(gui) end
	end
end

local connection_status_labels = {
	ready = "Connected - device ready",
	["no-device"] = "Connected - no matching device",
	connecting = "Connecting...",
	disconnected = "Disconnected",
	disabled = "Disabled",
	invalid = "Invalid IP or port",
}

local function draw_connection_status(gui)
	local status = ModSettingGet(mod_prefix .. "connection_status")
	GuiText(gui, mod_setting_group_x_offset, 0, "Status: " .. (connection_status_labels[status] or "Disconnected"))
end

local function device_selector(_, gui, in_main_menu, im_id, setting)
	local values = { { "", "Auto" } }
	local selected = ModSettingGetNextValue(setting_id(setting))
	local selected_found = not selected or selected == ""
	local count = not in_main_menu and tonumber(ModSettingGet(mod_prefix .. "device_count")) or 0
	for position = 1, count or 0 do
		local device_prefix = mod_prefix .. "device_" .. position .. "_"
		local name = ModSettingGet(device_prefix .. "name")
		local display_name = ModSettingGet(device_prefix .. "display")
		local index = tostring(ModSettingGet(device_prefix .. "index"))
		if type(name) == "string" and name ~= "" then
			local value = "index:" .. index .. ":" .. name
			values[#values + 1] = { value, (display_name or name) .. " (#" .. index .. ")" }
			selected_found = selected_found or value == selected
		end
	end
	if not selected_found then values[#values + 1] = { selected, selected .. " (offline)" } end
	setting.values = values
	mod_setting_enum(mod_id, gui, in_main_menu, im_id, setting)
end

---@param id string
---@param ui_name string
---@param ui_description string
---@param value_default boolean|number
---@param value_range number[]|nil min and max, for an intensity
---@return table
local function event_setting(id, ui_name, ui_description, value_default, value_range)
	local setting = {
		id = id,
		ui_name = ui_name,
		ui_description = ui_description,
		value_default = value_default,
		scope = MOD_SETTING_SCOPE_RUNTIME,
		hidden = true,
	}
	if value_range then
		setting.value_min = value_range[1]
		setting.value_max = value_range[2]
	end
	return setting
end

local event_settings = {}
local event_types = {
	{ "damage", "Damage taken", "Impact pattern scaled by total damage received in a frame.", "Damage intensity", "Scales damage pulses." },
	{ "fire", "On fire", "Modulated vibration while burning.", "Fire intensity", "Scales vibration while burning." },
	{ "low_hp", "Low health", "A paired heartbeat below 30% health.", "Low health intensity", "Scales low-health heartbeat pulses." },
	{ "healing", "Healing", "Double pulse when health increases.", "Healing intensity", "Scales healing pulses." },
	{ "drowning", "Low air", "Vibration that grows as air runs low.", "Low air intensity", "Scales low-air vibration." },
	{ "shots", "Wand shots", "Pulse when firing a wand.", "Wand shot intensity", "Scales wand shot pulses." },
	{ "death", "Death", "Ending pattern when the player dies.", "Death intensity", "Scales the death pattern." },
	{ "teleport", "Teleport", "Rising and falling sweep when teleported, including portals.", "Teleport intensity", "Scales the teleport sweep." },
	{ "polymorph", "Polymorph", "Irregular wobble when polymorphed.", "Polymorph intensity", "Scales the polymorph pattern." },
	{ "pickups", "Pickups", "Orbs, perks, and max-health gains such as hearts. Orbs are strongest.", "Pickup intensity", "Scales pickup pulses." },
	{ "kills", "Kills", "Tiny pulse when you kill an enemy.", "Kill intensity", "Scales kill pulses." },
	{ "kick", "Kick", "Short tap when you kick.", "Kick intensity", "Scales kick taps.", false },
	{ "biome", "Biome change", "Soft pulse when entering a new biome, at most every 3 seconds.", "Biome intensity", "Scales biome pulses.", false },
	{ "screenshake", "Screen shake", "Rumble on explosions, collapses and other screen shakes, even with the game's screen shake setting at 0.", "Screen shake intensity", "Scales screen shake rumble." },
}

for _, event_type in ipairs(event_types) do
	local key, name, description, intensity_name, intensity_description, enabled_default = unpack(event_type)
	local enabled_setting = event_setting(key .. "_enabled", name, description, enabled_default ~= false)
	local intensity_setting = event_setting(key .. "_intensity", intensity_name, intensity_description, 1.0, intensity_range)
	event_settings[#event_settings + 1] = {
		id = key .. "_row",
		ui_name = name,
		not_setting = true,
		enabled_setting = enabled_setting,
		intensity_setting = intensity_setting,
		ui_fn = event_row,
	}
	event_settings[#event_settings + 1] = enabled_setting
	event_settings[#event_settings + 1] = intensity_setting
end

event_settings[#event_settings + 1] = {
	id = "debug_print",
	ui_name = "Debug print",
	ui_description = "Simulate a device and log every haptic event to the console. Works without Intiface.",
	value_default = false,
	scope = MOD_SETTING_SCOPE_RUNTIME,
}

mod_settings = {
	{
		id = "enabled",
		ui_name = "Enabled",
		ui_description = "Connect to Intiface and allow vibration output.",
		value_default = true,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "intensity",
		ui_name = "Master intensity",
		ui_description = "Scales all vibration output, including the test pulse.",
		value_default = 1.0,
		value_min = 0.0,
		value_max = 1.0,
		scope = MOD_SETTING_SCOPE_RUNTIME,
		ui_fn = intensity_slider,
	},
	{
		id = "host",
		ui_name = "Intiface IP",
		ui_description = "Remote Intiface uses plaintext, unauthenticated WebSocket traffic. Use only on a trusted network.",
		value_default = "127.0.0.1",
		text_max_length = 15,
		scope = MOD_SETTING_SCOPE_RUNTIME,
		ui_fn = aligned_text_input,
	},
	{
		id = "port",
		ui_name = "Intiface port",
		ui_description = "WebSocket port (1-65535).",
		value_default = "12345",
		text_max_length = 5,
		scope = MOD_SETTING_SCOPE_RUNTIME,
		ui_fn = aligned_text_input,
	},
	{
		id = "connect",
		ui_name = "Connect / reconnect",
		ui_description = "Connect to Intiface and refresh its device list.",
		not_setting = true,
		ui_fn = request_button("connect_request", "Connect (available in game)", draw_connection_status),
	},
	{
		id = "device_name",
		ui_name = "Device",
		ui_description = "Click to cycle through devices reported by Intiface. Connect first to refresh the list.",
		value_default = "",
		scope = MOD_SETTING_SCOPE_RUNTIME,
		ui_fn = device_selector,
	},
	{
		id = "test",
		ui_name = "Test vibration (30% for 0.3s)",
		ui_description = "Uses the selected device and master intensity.",
		not_setting = true,
		ui_fn = request_button("test_request", "Test vibration (available in game)"),
	},
	{
		category_id = "advanced",
		ui_name = "Advanced",
		foldable = true,
		_folded = true,
		settings = event_settings,
	},
}

function ModSettingsUpdate(init_scope)
	mod_settings_update(mod_id, mod_settings, init_scope)
end

function ModSettingsGuiCount()
	return mod_settings_gui_count(mod_id, mod_settings)
end

function ModSettingsGui(gui, in_main_menu)
	mod_settings_gui(mod_id, mod_settings, gui, in_main_menu)
end
