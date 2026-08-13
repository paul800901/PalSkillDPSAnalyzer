local hud = {}

local SETTINGS_FILE = "user_settings.lua"
local STATE_FILE = "skill_dps_hud_state.txt"
local COMMAND_FILE = "skill_dps_hud_command.txt"
local HEARTBEAT_FILE = "skill_dps_hud_heartbeat.txt"
local OVERLAY_LOG_FILE = "skill_dps_hud_overlay.log"
local OVERLAY_SCRIPT = "skill_dps_overlay.ps1"
local OVERLAY_LAUNCHER = "skill_dps_overlay_launcher.vbs"

local function module_directory()
    local source = debug.getinfo(1, "S").source or ""
    if string.sub(source, 1, 1) == "@" then
        source = string.sub(source, 2)
    end
    return string.match(source, "^(.*[\\/])") or "./"
end

local function decimal(value)
    if value == nil then
        return "—"
    end
    return string.format("%.1f", value)
end

local function integer(value)
    local number = math.floor((tonumber(value) or 0) + 0.5)
    local formatted = tostring(number)
    while true do
        local replaced, count = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
        formatted = replaced
        if count == 0 then
            break
        end
    end
    return formatted
end

local function protocol_field(value)
    local text = tostring(value == nil and "" or value)
    text = string.gsub(text, "%%", "%%25")
    text = string.gsub(text, "\t", "%%09")
    text = string.gsub(text, "\r", "%%0D")
    text = string.gsub(text, "\n", "%%0A")
    return text
end

local function protocol_number(value)
    local number = tonumber(value)
    if number == nil then
        return ""
    end
    return string.format("%.4f", number)
end

local function write_setting(file, key, value)
    if type(value) == "string" then
        file:write("    ", key, " = ", string.format("%q", value), ",\n")
    else
        file:write("    ", key, " = ", tostring(value), ",\n")
    end
end

function hud.new(options)
    local self = {
        config = assert(options.config),
        log = options.log or function() end,
        get_player_controller = options.get_player_controller,
        get_world_context = options.get_world_context,
        is_gameplay_available = options.is_gameplay_available,
        get_language = options.get_language,
        get_language_name = options.get_language_name,
        language_options = options.language_options or { "auto", "zh-TW", "en" },
        translate = options.translate,
        get_skill_name = options.get_skill_name,
        on_reset = options.on_reset,
        settings_path = module_directory() .. SETTINGS_FILE,
        state_path = module_directory() .. STATE_FILE,
        command_path = module_directory() .. COMMAND_FILE,
        heartbeat_path = module_directory() .. HEARTBEAT_FILE,
        overlay_log_path = module_directory() .. OVERLAY_LOG_FILE,
        overlay_script_path = module_directory() .. OVERLAY_SCRIPT,
        overlay_launcher_path = module_directory() .. OVERLAY_LAUNCHER,
        settings_open = false,
        selected_setting = 1,
        backend = "pending",
        key_label = "F1",
        reset_key_label = "F2",
        latest_snapshot = nil,
        last_rendered_text = nil,
        logged_create_failure = false,
        overlay_launch_attempted = false,
        overlay_last_launch_at = 0,
        overlay_last_watchdog_at = 0,
        overlay_failure_count = 0,
        overlay_seen_alive = false,
        overlay_relaunch_suppressed = false,
        command_ack = "",
        processed_command_ids = {},
        processed_command_order = {},
        gameplay_available = nil,
        reset_notice = "",
        waiting_reset = false,
        last_reset_at = nil,
        state_sequence = 0,
    }

    self.setting_keys = {
        "reset",
        "Language",
        "MeasurementMode",
        "TargetScope",
        "EnableSkillDPSHUD",
        "IncludePlayerDamage",
        "HUDDetailMode",
        "HUDShowInternalSkillCode",
        "HUDAnchor",
        "HUDScale",
        "HUDFinalResultSeconds",
        "SkillDiagnosticChatMode",
    }

    self.persisted_keys = {
        "HUDSettingsVersion",
        "Language",
        "MeasurementMode",
        "TargetScope",
        "EnableSkillDPSHUD",
        "IncludePlayerDamage",
        "HUDDetailMode",
        "HUDShowInternalSkillCode",
        "HUDAnchor",
        "HUDScale",
        "HUDKeepFinalResults",
        "HUDFinalResultSeconds",
        "SkillDiagnosticChatMode",
    }

    function self:load_settings()
        local chunk, load_error = loadfile(self.settings_path)
        if chunk == nil then
            if load_error ~= nil and string.find(tostring(load_error), "No such file", 1, true) == nil
                and string.find(tostring(load_error), "cannot open", 1, true) == nil then
                self.log("HUD settings load skipped: " .. tostring(load_error))
            end
            return
        end
        local ok, values = pcall(chunk)
        if not ok or type(values) ~= "table" then
            self.log("HUD settings ignored: " .. tostring(values))
            return
        end
        local settings_version = tonumber(values.HUDSettingsVersion) or 1
        for _, key in ipairs(self.persisted_keys) do
            if values[key] ~= nil then
                self.config[key] = values[key]
            end
        end
        if settings_version < 2 then
            -- v0.4.x persisted the former full-detail default. Migrate once to
            -- the compact bar view; users can deliberately re-enable full
            -- diagnostics from F1 after seeing the new layout.
            self.config.HUDSettingsVersion = 2
            self.config.HUDDetailMode = "compact"
            self.log("HUD settings migrated to v2 compact bars")
        end
        if settings_version < 3 then
            -- v0.5.0 placed a full-size meter over Palworld's quest tracker.
            -- Move existing installs to the safer compact left-side layout and
            -- opt into a manually controlled, all-world damage-lab session.
            self.config.HUDSettingsVersion = 3
            self.config.HUDAnchor = "left-center"
            self.config.HUDScale = 0.85
            self.config.HUDFinalResultSeconds = 15
            self.config.MeasurementMode = "manual"
            self.config.TargetScope = "all"
            self.log("HUD settings migrated to v3 damage-lab layout")
        end
        if settings_version < 3 then
            self:save_settings()
        end
    end

    function self:save_settings()
        local file, open_error = io.open(self.settings_path, "w")
        if file == nil then
            self.log("HUD settings save failed: " .. tostring(open_error))
            return false
        end
        file:write("-- Generated by PalSkillDPSAnalyzer's F1 settings panel.\n")
        file:write("return {\n")
        for _, key in ipairs(self.persisted_keys) do
            write_setting(file, key, self.config[key])
        end
        file:write("}\n")
        file:close()
        return true
    end

    function self:write_external_state(text, visible)
        self.state_sequence = self.state_sequence + 1
        if rawget(_G, "__BOSS_DPS_TEST") == true then
            self.last_external_state = {
                text = tostring(text or ""),
                visible = visible == true,
                sequence = self.state_sequence,
            }
            return true
        end
        local temporary_path = self.state_path .. ".tmp"
        local file, open_error = io.open(temporary_path, "wb")
        if file == nil then
            self.log("external HUD state write failed: " .. tostring(open_error))
            return false
        end
        file:write("PAL_SKILL_DPS_HUD_V1\n")
        file:write("sequence=", tostring(self.state_sequence), "\n")
        file:write("visible=", visible == true and "1" or "0", "\n")
        file:write("anchor=", tostring(self.config.HUDAnchor or "left-center"), "\n")
        file:write("scale=", tostring(tonumber(self.config.HUDScale) or 0.85), "\n")
        file:write("settings=", self.settings_open and "1" or "0", "\n")
        file:write("command_ack=", protocol_field(self.command_ack), "\n")
        file:write("---\n")
        file:write(tostring(text or ""))
        file:write("\n")
        file:close()

        os.remove(self.state_path)
        local renamed, rename_error = os.rename(temporary_path, self.state_path)
        if not renamed then
            self.log("external HUD state replace failed: " .. tostring(rename_error))
            return false
        end
        return true
    end

    function self:skill_display_name(skill)
        local internal_code = tostring(skill.internal_code or "")
        local skill_name = tostring(skill.name or internal_code or "UNKNOWN")
        if self.get_skill_name ~= nil then
            local ok, localized = pcall(
                self.get_skill_name,
                internal_code,
                skill.runtime_name or skill.name
            )
            if ok and localized ~= nil and localized ~= "" then
                skill_name = tostring(localized)
            end
        end
        if skill.category == "basic" then
            skill_name = self:text("hud_skill_category_basic") .. "｜" .. skill_name
        elseif skill.category == "other" then
            local category_name = self:text("hud_skill_category_other")
            local opaque = string.find(internal_code, "^UNKNOWN_") ~= nil
                or string.find(internal_code, "^UNRESOLVED_") ~= nil
            if opaque and self.config.HUDShowInternalSkillCode ~= true then
                skill_name = category_name
            else
                skill_name = category_name .. "｜" .. skill_name
            end
        end
        if self.config.HUDShowInternalSkillCode == true
            and internal_code ~= "" and internal_code ~= skill_name then
            skill_name = skill_name .. " (" .. internal_code .. ")"
        end
        return skill_name, internal_code
    end

    function self:build_external_meter_document(snapshot, sequence)
        local final = snapshot.state == "finished"
        local final_seconds = math.floor(tonumber(self.config.HUDFinalResultSeconds) or 15)
        local expires_at = tonumber(snapshot.expires_at)
            or (final and final_seconds > 0 and (os.time() + final_seconds) or 0)
        local maximum = math.max(1, math.floor(tonumber(self.config.HUDMaxSkillRows) or 6))
        local shown = 0
        local source_count = 0
        local primary_source = ""
        local body = {}

        for source_index, source in ipairs(snapshot.sources or {}) do
            if shown >= maximum then break end
            source_count = source_count + 1
            if primary_source == "" then
                primary_source = tostring(source.name or "")
            end
            body[#body + 1] = table.concat({
                "S",
                tostring(source_index),
                protocol_field(source.name),
                protocol_number(source.damage),
                protocol_number(source.dps),
                tostring(math.floor(tonumber(source.hits) or 0)),
            }, "\t")
            for _, skill in ipairs(source.skills or {}) do
                if shown >= maximum then break end
                shown = shown + 1
                local skill_name, internal_code = self:skill_display_name(skill)
                local damage = tonumber(skill.damage) or 0
                local source_damage = tonumber(source.damage) or 0
                local share = source_damage > 0 and (damage / source_damage * 100) or 0
                local unresolved = string.find(internal_code, "UNRESOLVED", 1, true) ~= nil
                local detail_timing = self:text("hud_skill_timing", {
                    per_cast = decimal(skill.damage_per_cast),
                    action = decimal(skill.action_duration),
                    cast_dps = decimal(skill.action_dps),
                    complete = skill.lifecycle_complete,
                    casts = skill.casts,
                })
                local detail_cooldown = self:text("hud_skill_cooldown", {
                    panel = decimal(skill.panel_cd),
                    interval = decimal(skill.actual_interval),
                    gap = decimal(skill.reuse_gap),
                })
                local compact_counts = self:text("hud_skill_compact_counts", {
                    hits = tostring(math.floor(tonumber(skill.hits) or 0)),
                    casts = tostring(math.floor(tonumber(skill.casts) or 0)),
                })
                body[#body + 1] = table.concat({
                    "R",
                    tostring(source_index),
                    tostring(shown),
                    protocol_field(skill_name),
                    protocol_field(internal_code),
                    protocol_number(damage),
                    protocol_number(skill.encounter_dps),
                    protocol_number(share),
                    tostring(math.floor(tonumber(skill.hits) or 0)),
                    tostring(math.floor(tonumber(skill.casts) or 0)),
                    protocol_number(skill.damage_per_cast),
                    protocol_number(skill.action_duration),
                    protocol_number(skill.action_dps),
                    protocol_number(skill.panel_cd),
                    protocol_number(skill.actual_interval),
                    protocol_number(skill.reuse_gap),
                    tostring(math.floor(tonumber(skill.lifecycle_complete) or 0)),
                    unresolved and "1" or "0",
                    protocol_field(detail_timing),
                    protocol_field(detail_cooldown),
                    protocol_field(compact_counts),
                }, "\t")
            end
        end
        if shown == 0 then
            body[#body + 1] = "W\t" .. protocol_field(snapshot.notice or self:text("hud_waiting"))
        end

        local header = {
            "PAL_SKILL_DPS_HUD_V2",
            "sequence=" .. tostring(sequence),
            "visible=1",
            "anchor=" .. tostring(self.config.HUDAnchor or "left-center"),
            "scale=" .. tostring(tonumber(self.config.HUDScale) or 0.85),
            "settings=0",
            "view=meter",
            "detail=" .. tostring(self.config.HUDDetailMode == "full" and "full" or "compact"),
            "state=" .. tostring(final and "finished" or "live"),
            "state_label=" .. protocol_field(self:text(final and "hud_state_finished" or "hud_state_live")),
            "title=" .. protocol_field(self:text("hud_title")),
            "primary_source=" .. protocol_field(primary_source),
            "source_count=" .. tostring(source_count),
            "boss=" .. protocol_field(snapshot.boss),
            "measurement_mode=" .. protocol_field(snapshot.measurement_mode or "target"),
            "target_count=" .. tostring(math.floor(tonumber(snapshot.target_count) or 1)),
            "target_count_label=" .. protocol_field(self:text("hud_target_count", {
                count = math.floor(tonumber(snapshot.target_count) or 1),
            })),
            "duration=" .. protocol_number(snapshot.duration),
            "total_damage=" .. protocol_number(snapshot.total_damage),
            "encounter_dps=" .. protocol_number(snapshot.encounter_dps),
            "expires_at=" .. tostring(expires_at),
            "command_ack=" .. protocol_field(self.command_ack),
        }
        return table.concat(header, "\n") .. "\n---\n" .. table.concat(body, "\n") .. "\n"
    end

    function self:write_external_meter_state(snapshot)
        self.state_sequence = self.state_sequence + 1
        local document = self:build_external_meter_document(snapshot, self.state_sequence)
        if rawget(_G, "__BOSS_DPS_TEST") == true then
            self.last_external_state = {
                text = document,
                visible = true,
                sequence = self.state_sequence,
                protocol = "PAL_SKILL_DPS_HUD_V2",
                view = "meter",
            }
            return true
        end
        local temporary_path = self.state_path .. ".tmp"
        local file, open_error = io.open(temporary_path, "wb")
        if file == nil then
            self.log("external HUD meter state write failed: " .. tostring(open_error))
            return false
        end
        file:write(document)
        file:close()

        os.remove(self.state_path)
        local renamed, rename_error = os.rename(temporary_path, self.state_path)
        if not renamed then
            self.log("external HUD meter state replace failed: " .. tostring(rename_error))
            return false
        end
        return true
    end

    function self:release_input_lock()
        -- Compatibility no-op for an old recovery call site. External windows
        -- are display-only and never mutate Palworld input or cursor state.
        return true
    end

    function self:sync_input_lock(should_lock)
        -- External WPF can never own Palworld's CommonUI input route. The old
        -- implementation disabled controller/pawn input and exposed a cursor,
        -- but left Unreal in GameOnly mode; the visible panel therefore could
        -- not receive clicks while attack/Options input leaked to the game.
        -- Fail closed until the native CommonUI settings page is installed.
        self:release_input_lock()
        return should_lock ~= true
    end

    function self:overlay_heartbeat_epoch()
        local file = io.open(self.heartbeat_path, "rb")
        if file == nil then return nil end
        local raw = file:read("*a") or ""
        file:close()
        return tonumber(string.match(raw, "epoch=(%d+)"))
    end

    function self:start_external_overlay(force)
        if self.overlay_launch_attempted and force ~= true then
            return self.backend == "external-file"
        end
        local now = os.time()
        if force == true and now - self.overlay_last_launch_at < 4 then
            return self.backend == "external-file"
        end
        self.overlay_launch_attempted = true
        self.overlay_last_launch_at = now
        self.backend = "external-file"
        if self.config.ExternalHUDAutoLaunch ~= true then
            self.log("HUD backend=external-file; automatic overlay launch disabled")
            return true
        end
        if rawget(_G, "__BOSS_DPS_TEST") == true then
            return true
        end
        local probe = io.open(self.overlay_script_path, "rb")
        if probe == nil then
            self.log("external HUD script missing: " .. self.overlay_script_path)
            return false
        end
        probe:close()

        local launcher_probe = io.open(self.overlay_launcher_path, "rb")
        if launcher_probe == nil then
            self.log("external HUD launcher missing: " .. self.overlay_launcher_path)
            return false
        end
        launcher_probe:close()

        local system_root = os.getenv("SystemRoot") or "C:\\Windows"
        local wscript = system_root .. "\\System32\\wscript.exe"
        -- Keep the command passed through Lua's C-runtime system() deliberately
        -- tiny. A long, fully quoted command beginning with a quoted executable
        -- is reparsed incorrectly by cmd.exe in the UE4SS host and returns exit
        -- failure. The launcher resolves all sibling paths on its own.
        local command = string.format(
            '%s //B //NoLogo "%s"',
            wscript,
            self.overlay_launcher_path
        )
        local launched, launch_kind, launch_code = os.execute(command)
        if launched == nil or launched == false then
            self.log("external HUD launch failed: " .. tostring(launch_kind or launch_code))
            return false
        end
        self.log("HUD backend=external-file; all Unreal UI calls disabled")
        return true
    end

    function self:watchdog_external_overlay()
        if self.config.EnableExternalHUD ~= true or self.config.ExternalHUDAutoLaunch ~= true
            or rawget(_G, "__BOSS_DPS_TEST") == true then
            return true
        end
        local now = os.time()
        if now - self.overlay_last_watchdog_at < 1 then
            return true
        end
        self.overlay_last_watchdog_at = now
        local heartbeat = self:overlay_heartbeat_epoch()
        if heartbeat ~= nil and math.abs(now - heartbeat) <= 5 then
            if not self.overlay_seen_alive then
                self.log("external HUD heartbeat detected")
            end
            self.overlay_seen_alive = true
            self.overlay_failure_count = 0
            self.overlay_relaunch_suppressed = false
            return true
        end
        if self.overlay_relaunch_suppressed then
            return false
        end
        if now - self.overlay_last_launch_at < 5 then
            return false
        end
        self.overlay_failure_count = self.overlay_failure_count + 1
        if self.overlay_failure_count < 2 then
            return false
        end
        if self.overlay_failure_count > 4 then
            self.overlay_relaunch_suppressed = true
            self.log("external HUD relaunch suppressed after 3 attempts; no further console launches this session")
            if self.settings_open then
                self:close_settings()
            end
            return false
        end
        self.log(string.format(
            "external HUD heartbeat stale; relaunch attempt=%d",
            self.overlay_failure_count - 1
        ))
        self:start_external_overlay(true)
        if self.settings_open and self.overlay_failure_count >= 4 then
            self.log("external HUD recovery failed; closing settings to release game input")
            self:close_settings()
        end
        return false
    end

    function self:initialize_external()
        if self.config.EnableExternalHUD ~= true then
            self.backend = "file-only"
            self.log("HUD backend=file-only; external overlay disabled")
            return false
        end
        self:start_external_overlay()
        return self:write_external_state("", false)
    end

    function self:language_code()
        if self.get_language ~= nil then
            local ok, value = pcall(self.get_language)
            if ok and value ~= nil then
                return value
            end
        end
        if self.latest_snapshot ~= nil and self.latest_snapshot.language ~= nil then
            return self.latest_snapshot.language
        end
        return self.config.Language == "auto" and "en" or self.config.Language
    end

    function self:text(key, values)
        if self.translate ~= nil then
            local ok, value = pcall(self.translate, key, values)
            if ok and value ~= nil then
                return tostring(value)
            end
        end
        return tostring(key)
    end

    function self:language_name(code)
        if code == "auto" then
            return self:text("hud_value_follow_game")
        end
        if self.get_language_name ~= nil then
            local ok, value = pcall(self.get_language_name, code)
            if ok and value ~= nil and value ~= "" then
                return tostring(value)
            end
        end
        return tostring(code or "")
    end

    function self:bool_text(value)
        return self:text(value and "hud_value_on" or "hud_value_off")
    end

    function self:chat_mode_text(value)
        if value == "full" then return self:text("hud_value_full") end
        if value == "summary" then return self:text("hud_value_summary") end
        return self:text("hud_value_off")
    end

    function self:apply_layout()
        -- The external overlay reads anchor and scale from every state update.
    end

    function self:render_text(header, summary, body, footer)
        local combined = table.concat({ header, summary, body, footer }, "\n")
        if self.last_rendered_text == combined and self.backend == "external-file" then
            return
        end
        self.last_rendered_text = combined
        self.backend = self.config.EnableExternalHUD == true and "external-file" or "file-only"
        self:write_external_state(combined, true)
    end

    function self:hide()
        self:write_external_state("", false)
        self.last_rendered_text = nil
    end

    function self:gameplay_is_available()
        if self.is_gameplay_available == nil then return true end
        local ok, available = pcall(self.is_gameplay_available, self.settings_open)
        if not ok then
            self.log("HUD gameplay-state check failed: " .. tostring(available))
            return false
        end
        return available == true
    end

    function self:sync_gameplay_visibility()
        local available = self:gameplay_is_available()
        if self.gameplay_available == available then
            return available
        end
        self.gameplay_available = available
        self.last_rendered_text = nil
        if not available then
            self:hide()
        elseif self.settings_open then
            self:render_settings()
        elseif self.waiting_reset then
            self:publish_waiting()
        elseif self.latest_snapshot ~= nil and self.config.EnableSkillDPSHUD == true then
            self:publish(self.latest_snapshot)
        else
            self:hide()
        end
        return available
    end

    function self:setting_label(key)
        local labels = {
            Language = "hud_setting_language",
            MeasurementMode = "hud_setting_measurement_mode",
            TargetScope = "hud_setting_target_scope",
            EnableSkillDPSHUD = "hud_setting_show",
            IncludePlayerDamage = "hud_setting_player",
            HUDDetailMode = "hud_setting_detail",
            HUDShowInternalSkillCode = "hud_setting_internal",
            HUDAnchor = "hud_setting_anchor",
            HUDScale = "hud_setting_scale",
            HUDFinalResultSeconds = "hud_setting_final_duration",
            SkillDiagnosticChatMode = "hud_setting_chat",
            reset = "hud_setting_reset",
        }
        return self:text(labels[key] or key)
    end

    function self:setting_group(key)
        if key == "Language" then return self:text("hud_group_general") end
        if key == "MeasurementMode" or key == "TargetScope" or key == "IncludePlayerDamage" then
            return self:text("hud_group_measurement")
        end
        if key == "EnableSkillDPSHUD" or key == "HUDDetailMode"
            or key == "HUDShowInternalSkillCode" or key == "HUDAnchor" or key == "HUDScale" then
            return self:text("hud_group_display")
        end
        if key == "reset" then return self:text("hud_group_test") end
        return self:text("hud_group_output")
    end

    function self:setting_value_text(key)
        local value = self.config[key]
        if key == "Language" then
            return self:language_name(tostring(value or "auto"))
        elseif key == "MeasurementMode" then
            return self:text(value == "target" and "hud_value_mode_target" or "hud_value_mode_manual")
        elseif key == "TargetScope" then
            return self:text(value == "boss" and "hud_value_scope_boss" or "hud_value_scope_all")
        elseif key == "EnableSkillDPSHUD" or key == "IncludePlayerDamage"
            or key == "HUDShowInternalSkillCode" then
            return self:bool_text(value == true)
        elseif key == "HUDDetailMode" then
            return self:text(value == "compact" and "hud_value_compact" or "hud_value_full")
        elseif key == "HUDAnchor" then
            local anchor_keys = {
                ["left-center"] = "hud_value_left_center",
                ["right-center"] = "hud_value_right_center",
                ["top-left"] = "hud_value_top_left",
                ["top-right"] = "hud_value_top_right",
            }
            return self:text(anchor_keys[tostring(value)] or "hud_value_left_center")
        elseif key == "HUDScale" then
            return string.format("%d%%", math.floor((tonumber(value) or 1) * 100 + 0.5))
        elseif key == "HUDFinalResultSeconds" then
            local seconds = math.floor(tonumber(value) or 15)
            if seconds < 0 then return self:text("hud_value_keep") end
            if seconds == 0 then return self:text("hud_value_hide") end
            return self:text("hud_value_seconds", { seconds = seconds })
        elseif key == "SkillDiagnosticChatMode" then
            return self:chat_mode_text(value)
        end
        return self:text("hud_value_press_enter")
    end

    function self:settings_lines()
        local lines = {}
        for index, key in ipairs(self.setting_keys) do
            lines[#lines + 1] = string.format(
                "%s %-24s  %s",
                index == self.selected_setting and "▶" or " ",
                self:setting_label(key),
                self:setting_value_text(key)
            )
        end
        return lines
    end

    function self:build_external_settings_document(sequence)
        local snapshot = self.latest_snapshot
        local result_context = ""
        if snapshot ~= nil then
            result_context = self:text("hud_result_context", {
                target = snapshot.boss,
                seconds = decimal(snapshot.duration),
                count = math.floor(tonumber(snapshot.target_count) or 1),
            })
        end
        local header = {
            "PAL_SKILL_DPS_HUD_V2",
            "sequence=" .. tostring(sequence),
            "visible=1",
            "anchor=center",
            "scale=1",
            "settings=1",
            "view=settings",
            "title=" .. protocol_field(self:text("hud_settings_title")),
            "note=" .. protocol_field(self:text("hud_settings_note")),
            "footer=" .. protocol_field(self:text("hud_settings_footer", { key = self.key_label })),
            "close_label=" .. protocol_field(self:text("hud_settings_close")),
            "settings_tab_label=" .. protocol_field(self:text("hud_tab_settings")),
            "results_tab_label=" .. protocol_field(self:text("hud_tab_results")),
            "no_results_label=" .. protocol_field(self:text("hud_no_results")),
            "result_context=" .. protocol_field(result_context),
            "result_damage=" .. protocol_number(snapshot and snapshot.total_damage or 0),
            "result_dps=" .. protocol_number(snapshot and snapshot.encounter_dps or 0),
            "reset_notice=" .. protocol_field(self.reset_notice),
            "command_ack=" .. protocol_field(self.command_ack),
        }
        local body = {}
        for index, key in ipairs(self.setting_keys) do
            body[#body + 1] = table.concat({
                key == "reset" and "B" or "P",
                protocol_field(key),
                protocol_field(self:setting_group(key)),
                protocol_field(self:setting_label(key)),
                protocol_field(self:setting_value_text(key)),
                index == self.selected_setting and "1" or "0",
            }, "\t")
        end
        local shown = 0
        for source_index, source in ipairs(snapshot and snapshot.sources or {}) do
            body[#body + 1] = table.concat({
                "S",
                tostring(source_index),
                protocol_field(source.name),
                protocol_number(source.damage),
                protocol_number(source.dps),
                tostring(math.floor(tonumber(source.hits) or 0)),
            }, "\t")
            for _, skill in ipairs(source.skills or {}) do
                shown = shown + 1
                local skill_name, internal_code = self:skill_display_name(skill)
                local damage = tonumber(skill.damage) or 0
                local source_damage = tonumber(source.damage) or 0
                local share = source_damage > 0 and (damage / source_damage * 100) or 0
                local unresolved = string.find(internal_code, "UNRESOLVED", 1, true) ~= nil
                body[#body + 1] = table.concat({
                    "R", tostring(source_index), tostring(shown),
                    protocol_field(skill_name), protocol_field(internal_code),
                    protocol_number(damage), protocol_number(skill.encounter_dps),
                    protocol_number(share), tostring(math.floor(tonumber(skill.hits) or 0)),
                    tostring(math.floor(tonumber(skill.casts) or 0)),
                    protocol_number(skill.damage_per_cast), protocol_number(skill.action_duration),
                    protocol_number(skill.action_dps), protocol_number(skill.panel_cd),
                    protocol_number(skill.actual_interval), protocol_number(skill.reuse_gap),
                    tostring(math.floor(tonumber(skill.lifecycle_complete) or 0)),
                    unresolved and "1" or "0",
                    protocol_field(self:text("hud_skill_timing", {
                        per_cast = decimal(skill.damage_per_cast), action = decimal(skill.action_duration),
                        cast_dps = decimal(skill.action_dps), complete = skill.lifecycle_complete,
                        casts = skill.casts,
                    })),
                    protocol_field(self:text("hud_skill_cooldown", {
                        panel = decimal(skill.panel_cd), interval = decimal(skill.actual_interval),
                        gap = decimal(skill.reuse_gap),
                    })),
                }, "\t")
            end
        end
        return table.concat(header, "\n") .. "\n---\n" .. table.concat(body, "\n") .. "\n"
    end

    function self:write_external_settings_state()
        self.state_sequence = self.state_sequence + 1
        local document = self:build_external_settings_document(self.state_sequence)
        if rawget(_G, "__BOSS_DPS_TEST") == true then
            self.last_external_state = {
                text = document,
                visible = true,
                sequence = self.state_sequence,
                protocol = "PAL_SKILL_DPS_HUD_V2",
                view = "settings",
            }
            return true
        end
        local temporary_path = self.state_path .. ".tmp"
        local file, open_error = io.open(temporary_path, "wb")
        if file == nil then
            self.log("external HUD settings state write failed: " .. tostring(open_error))
            return false
        end
        file:write(document)
        file:close()
        os.remove(self.state_path)
        local renamed, rename_error = os.rename(temporary_path, self.state_path)
        if not renamed then
            self.log("external HUD settings state replace failed: " .. tostring(rename_error))
            return false
        end
        return true
    end

    function self:render_settings()
        self.last_rendered_text = nil
        self.backend = self.config.EnableExternalHUD == true and "external-file" or "file-only"
        self:write_external_settings_state()
    end

    function self:cycle_setting(key, direction)
        if key == "reset" then
            self:reset_test()
            return
        elseif key == "Language" then
            local current = tostring(self.config.Language or "auto")
            local index = 1
            for candidate_index, value in ipairs(self.language_options) do
                if value == current then index = candidate_index end
            end
            index = ((index - 1 + direction) % #self.language_options) + 1
            self.config.Language = self.language_options[index]
        elseif key == "MeasurementMode" then
            self.config[key] = self.config[key] == "target" and "manual" or "target"
        elseif key == "TargetScope" then
            self.config[key] = self.config[key] == "boss" and "all" or "boss"
        elseif key == "EnableSkillDPSHUD" or key == "IncludePlayerDamage"
            or key == "HUDShowInternalSkillCode"
            or key == "HUDKeepFinalResults" then
            self.config[key] = self.config[key] ~= true
        elseif key == "HUDDetailMode" then
            self.config[key] = self.config[key] == "compact" and "full" or "compact"
        elseif key == "HUDAnchor" then
            local values = { "left-center", "right-center", "top-left", "top-right" }
            local index = 1
            for candidate_index, value in ipairs(values) do
                if value == self.config[key] then index = candidate_index end
            end
            index = ((index - 1 + direction) % #values) + 1
            self.config[key] = values[index]
        elseif key == "HUDScale" then
            local values = { 0.75, 0.85, 1.0, 1.15 }
            local current = tonumber(self.config[key]) or 0.85
            local index = 2
            for candidate_index, value in ipairs(values) do
                if math.abs(value - current) < 0.05 then
                    index = candidate_index
                end
            end
            index = ((index - 1 + direction) % #values) + 1
            self.config[key] = values[index]
        elseif key == "HUDFinalResultSeconds" then
            local values = { 0, 15, 30, 60, -1 }
            local current = math.floor(tonumber(self.config[key]) or 15)
            local index = 2
            for candidate_index, value in ipairs(values) do
                if value == current then index = candidate_index end
            end
            index = ((index - 1 + direction) % #values) + 1
            self.config[key] = values[index]
        elseif key == "SkillDiagnosticChatMode" then
            local values = { "off", "summary", "full" }
            local index = 1
            for candidate_index, value in ipairs(values) do
                if value == self.config[key] then
                    index = candidate_index
                end
            end
            index = ((index - 1 + direction) % #values) + 1
            self.config[key] = values[index]
        end
        self:save_settings()
        self:apply_layout()
        if (key == "MeasurementMode" or key == "TargetScope") and self.on_reset ~= nil then
            self.on_reset()
        end
    end

    function self:show_notice(message, seconds)
        if self.settings_open then
            return
        end
        if self.config.EnableSkillDPSHUD ~= true or not self:gameplay_is_available() then
            self:hide()
            return
        end
        seconds = math.max(1, math.floor(tonumber(seconds) or 3))
        self:write_external_meter_state({
            state = "active",
            reason = "notice",
            boss = self:text("hud_manual_test"),
            duration = 0,
            total_damage = 0,
            encounter_dps = 0,
            include_player = self.config.IncludePlayerDamage == true,
            measurement_mode = tostring(self.config.MeasurementMode or "manual") == "manual"
                and "manual" or "target",
            target_count = 0,
            language = self:language_code(),
            sources = {},
            notice = tostring(message or ""),
            expires_at = os.time() + seconds,
        })
    end

    function self:reset_test()
        self.reset_notice = "✓ " .. self:setting_label("reset") .. " · " .. self:text("hud_waiting")
        self.waiting_reset = true
        if self.on_reset ~= nil then
            self.on_reset()
        end
        -- Show a visible waiting meter instead of hiding. The player must see
        -- that the test was zeroed and that recording waits for the first hit;
        -- a disappearing HUD reads as "nothing happened".
        self:publish_waiting()
        self.log("damage test reset via " .. self.reset_key_label)
        return true
    end

    function self:reset_test_from_key()
        -- F2 key auto-repeat must not create/clear multiple tests from one
        -- press. Only the key path is debounced; command-path resets are
        -- already deduplicated by command id.
        local now = os.clock()
        if self.last_reset_at ~= nil and now - self.last_reset_at < 0.5 then
            return false
        end
        self.last_reset_at = now
        return self:reset_test()
    end

    function self:publish_waiting()
        if self.settings_open then
            -- Offline settings fixtures expect the reset ack inside the
            -- settings document; keep that path while native CommonUI is out.
            self:render_settings()
            return
        end
        if self.config.EnableSkillDPSHUD ~= true or not self:gameplay_is_available() then
            self:hide()
            return
        end
        -- Written directly without replacing latest_snapshot: real damage from
        -- the new test overwrites this on the first accepted hit.
        self:write_external_meter_state({
            state = "active",
            reason = "reset",
            boss = self:text("hud_manual_test"),
            duration = 0,
            total_damage = 0,
            encounter_dps = 0,
            include_player = self.config.IncludePlayerDamage == true,
            measurement_mode = tostring(self.config.MeasurementMode or "manual") == "manual"
                and "manual" or "target",
            target_count = 0,
            language = self:language_code(),
            sources = {},
        })
    end

    function self:cycle_selected(direction)
        self:cycle_setting(self.setting_keys[self.selected_setting], direction)
    end

    function self:close_settings()
        if not self.settings_open then return end
        self.settings_open = false
        self:sync_input_lock(false)
        self.last_rendered_text = nil
        if self.waiting_reset then
            self:publish_waiting()
        elseif self.latest_snapshot ~= nil and self.config.EnableSkillDPSHUD == true then
            self:publish(self.latest_snapshot)
        else
            self:hide()
        end
    end

    function self:refresh_external_state()
        if self.settings_open then
            self:render_settings()
        elseif not self:gameplay_is_available() then
            self.gameplay_available = false
            self:hide()
        elseif self.waiting_reset then
            self:publish_waiting()
        elseif self.latest_snapshot ~= nil and self.config.EnableSkillDPSHUD == true then
            self:publish(self.latest_snapshot)
        else
            self:hide()
        end
    end

    function self:process_external_command_line(line)
        local command_id, payload = string.match(line or "", "^(cmd%-%S+)\t(.*)$")
        if command_id == nil then
            payload = line
        else
            self.command_ack = command_id
            if self.processed_command_ids[command_id] == true then
                self:refresh_external_state()
                return true
            end
            self.processed_command_ids[command_id] = true
            self.processed_command_order[#self.processed_command_order + 1] = command_id
            if #self.processed_command_order > 32 then
                local expired = table.remove(self.processed_command_order, 1)
                self.processed_command_ids[expired] = nil
            end
        end
        local handled = false
        local action, key, direction = string.match(payload or "", "^([^\t]+)\t?([^\t]*)\t?([^\t]*)$")
        if action == "close" then
            self:close_settings()
            handled = true
        elseif action == "cycle" and self.settings_open then
            local allowed = false
            for _, candidate in ipairs(self.setting_keys) do
                if candidate == key then allowed = true break end
            end
            if allowed then
                self:cycle_setting(key, tonumber(direction) == -1 and -1 or 1)
                self:render_settings()
                handled = true
            end
        elseif action == "select" and self.settings_open then
            for index, candidate in ipairs(self.setting_keys) do
                if candidate == key then
                    self.selected_setting = index
                    self:render_settings()
                    handled = true
                    break
                end
            end
        elseif command_id ~= nil then
            self:refresh_external_state()
            handled = true
        end
        return handled
    end

    function self:poll_external_commands()
        self:watchdog_external_overlay()
        self:sync_gameplay_visibility()
        self:sync_input_lock(self.settings_open)
        if rawget(_G, "__BOSS_DPS_TEST") == true then return false end
        local file = io.open(self.command_path, "rb")
        if file == nil then return false end
        local raw = file:read("*a") or ""
        file:close()
        os.remove(self.command_path)
        local handled = false
        for line in string.gmatch(raw, "[^\r\n]+") do
            if self:process_external_command_line(line) then
                handled = true
            end
        end
        return handled
    end

    function self:toggle_settings()
        if self.settings_open then
            self:close_settings()
            return true
        end
        if not self:gameplay_is_available() then
            self.gameplay_available = false
            self:hide()
            return false
        end
        if self.config.EnableExternalHUDSettings ~= true then
            self.log("F1 settings refused: native CommonUI settings page is not ready; external input path disabled")
            self:show_notice(self:text("hud_settings_unavailable"), 3)
            return false
        end
        self.settings_open = true
        self.gameplay_available = true
        self:sync_input_lock(true)
        self.last_rendered_text = nil
        self:render_settings()
        return true
    end

    function self:register_keybinds()
        local register_async = type(RegisterKeyBindAsync) == "function"
        local register_function = register_async and RegisterKeyBindAsync or RegisterKeyBind
        if type(register_function) ~= "function" or type(Key) ~= "table" then
            self.log("HUD keybind unavailable")
            return false
        end
        local modifiers = nil
        local occupied = false
        if type(IsKeyBindRegistered) == "function" then
            local ok, result = pcall(IsKeyBindRegistered, Key.F1, {})
            occupied = ok and result == true
        end
        if occupied and type(ModifierKey) == "table" then
            modifiers = { ModifierKey.CONTROL }
            self.key_label = "Ctrl+F1"
        end
        local function register(key, key_modifiers, callback)
            key_modifiers = key_modifiers or {}
            if register_async or #key_modifiers > 0 then
                register_function(key, key_modifiers, callback)
            else
                register_function(key, callback)
            end
        end
        local function in_game(callback)
            return function()
                if type(ExecuteInGameThread) == "function" then
                    ExecuteInGameThread(callback)
                end
                return self.settings_open
            end
        end
        local ok, register_error = pcall(function()
            register(Key.F1, modifiers, in_game(function() self:toggle_settings() end))
            if Key.F2 ~= nil then
                register(Key.F2, {}, in_game(function()
                    if not self:gameplay_is_available() then return false end
                    return self:reset_test_from_key()
                end))
            end
            register(Key.UP_ARROW, {}, in_game(function()
                if not self.settings_open then return end
                self.selected_setting = ((self.selected_setting - 2) % #self.setting_keys) + 1
                self.last_rendered_text = nil
                self:render_settings()
            end))
            register(Key.DOWN_ARROW, {}, in_game(function()
                if not self.settings_open then return end
                self.selected_setting = (self.selected_setting % #self.setting_keys) + 1
                self.last_rendered_text = nil
                self:render_settings()
            end))
            for _, key in ipairs({ Key.LEFT_ARROW, Key.RIGHT_ARROW, Key.RETURN }) do
                local bound_key = key
                register(bound_key, {}, in_game(function()
                    if not self.settings_open then return end
                    self:cycle_selected(bound_key == Key.LEFT_ARROW and -1 or 1)
                    self.last_rendered_text = nil
                    self:render_settings()
                end))
            end
        end)
        if not ok then
            self.log("HUD keybind registration failed: " .. tostring(register_error))
            return false
        end
        self.log("HUD settings hotkey=" .. self.key_label .. " (disabled until native CommonUI is ready); reset hotkey=" .. self.reset_key_label)
        return true
    end

    function self:format_snapshot(snapshot)
        local final = snapshot.state == "finished"
        local header = self:text("hud_title")
        local state = self:text(final and "hud_state_finished" or "hud_state_live")
        local summary = self:text("hud_summary", {
            state = state,
            boss = snapshot.boss,
            seconds = decimal(snapshot.duration),
            damage = integer(snapshot.total_damage),
            dps = decimal(snapshot.encounter_dps),
        })
        local lines = {}
        local shown = 0
        local maximum = math.max(1, math.floor(tonumber(self.config.HUDMaxSkillRows) or 6))
        for _, source in ipairs(snapshot.sources or {}) do
            if shown >= maximum then break end
            lines[#lines + 1] = self:text("hud_source", {
                source = source.name,
                damage = integer(source.damage),
                dps = decimal(source.dps),
                hits = source.hits,
            })
            for _, skill in ipairs(source.skills or {}) do
                if shown >= maximum then break end
                shown = shown + 1
                local skill_name = self:skill_display_name(skill)
                if self.config.HUDDetailMode == "compact" then
                    lines[#lines + 1] = self:text("hud_skill_compact", {
                        rank = shown,
                        skill = skill_name,
                        damage = integer(skill.damage),
                        dps = decimal(skill.encounter_dps),
                        casts = skill.casts,
                    })
                else
                    lines[#lines + 1] = self:text("hud_skill_primary", {
                        rank = shown,
                        skill = skill_name,
                        damage = integer(skill.damage),
                        dps = decimal(skill.encounter_dps),
                        hits = skill.hits,
                        casts = skill.casts,
                    })
                    lines[#lines + 1] = self:text("hud_skill_timing", {
                        per_cast = decimal(skill.damage_per_cast),
                        action = decimal(skill.action_duration),
                        cast_dps = decimal(skill.action_dps),
                        complete = skill.lifecycle_complete,
                        casts = skill.casts,
                    })
                    lines[#lines + 1] = self:text("hud_skill_cooldown", {
                        panel = decimal(skill.panel_cd),
                        interval = decimal(skill.actual_interval),
                        gap = decimal(skill.reuse_gap),
                    })
                end
            end
        end
        if shown == 0 then
            lines[#lines + 1] = self:text("hud_waiting")
        end
        local footer = self:text("hud_footer", {
            key = self.key_label,
            player = self:bool_text(snapshot.include_player),
            chat = self:chat_mode_text(self.config.SkillDiagnosticChatMode),
        })
        return header, summary, table.concat(lines, "\n"), footer
    end

    function self:publish(snapshot)
        self.latest_snapshot = snapshot
        if tonumber(snapshot.total_damage) ~= nil and tonumber(snapshot.total_damage) > 0 then
            self.reset_notice = ""
            self.waiting_reset = false
        end
        if self.settings_open then
            -- Keep the interactive workspace frozen while it is open. The
            -- collector may publish duration/DPS snapshots several times per
            -- second even with no new hit; rebuilding WPF tabs for each one
            -- caused visible flashing and selection bounce. The newest
            -- snapshot is retained and appears after the next deliberate UI
            -- action or when the workspace is reopened.
            return
        end
        if not self:gameplay_is_available() then
            if self.gameplay_available ~= false then
                self.gameplay_available = false
                self:hide()
            end
            return
        end
        self.gameplay_available = true
        if self.config.EnableSkillDPSHUD ~= true then
            self:hide()
            return
        end
        if snapshot.state == "finished" then
            local seconds = math.floor(tonumber(self.config.HUDFinalResultSeconds) or 15)
            if self.config.HUDKeepFinalResults ~= true or seconds == 0 then
                self:hide()
                return
            end
        end
        self.last_rendered_text = nil
        self.backend = self.config.EnableExternalHUD == true and "external-file" or "file-only"
        self:write_external_meter_state(snapshot)
    end

    function self:clear()
        self.latest_snapshot = nil
        if not self.settings_open then
            self:hide()
        end
    end

    self:load_settings()
    return self
end

return hud
