local hud = {}

local SETTINGS_FILE = "user_settings.lua"
local STATE_FILE = "skill_dps_hud_state.txt"
local COMMAND_FILE = "skill_dps_hud_command.txt"
local HEARTBEAT_FILE = "skill_dps_hud_heartbeat.txt"
local OVERLAY_LOG_FILE = "skill_dps_hud_overlay.log"
local OVERLAY_SCRIPT = "skill_dps_overlay.ps1"
local OVERLAY_LAUNCHER = "skill_dps_overlay_launcher.vbs"
local NATIVE_SETTINGS_PACKAGE = "/Game/Mods/PalSkillDPSAnalyzerSP/WBP_PalSkillDPSSettings"
local NATIVE_SETTINGS_ASSET = NATIVE_SETTINGS_PACKAGE .. ".WBP_PalSkillDPSSettings"
local NATIVE_SETTINGS_CLASS = "/Game/Mods/PalSkillDPSAnalyzerSP/WBP_PalSkillDPSSettings.WBP_PalSkillDPSSettings_C"
local WIDGET_LIBRARY_PATH = "/Script/UMG.Default__WidgetBlueprintLibrary"

local unpack_values = table.unpack or unpack

local function call_method(object, method_name, ...)
    if object == nil then return false, nil end
    local arguments = { ... }
    return pcall(function()
        return object[method_name](object, unpack_values(arguments))
    end)
end

local function object_is_valid(object)
    if object == nil then return false end
    local ok, valid = call_method(object, "IsValid")
    if ok then return valid == true end
    return true
end

local function set_object_property(object, property_name, value)
    if object == nil then return false end
    return pcall(function()
        object[property_name] = value
    end)
end

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
        load_asset = options.load_asset or rawget(_G, "LoadAsset"),
        static_find_object = options.static_find_object or rawget(_G, "StaticFindObject"),
        make_fname = options.make_fname or rawget(_G, "FName"),
        make_ftext = options.make_ftext or rawget(_G, "FText"),
        register_console_command_handler = options.register_console_command_handler
            or rawget(_G, "RegisterConsoleCommandHandler"),
        settings_path = module_directory() .. SETTINGS_FILE,
        state_path = module_directory() .. STATE_FILE,
        command_path = module_directory() .. COMMAND_FILE,
        heartbeat_path = module_directory() .. HEARTBEAT_FILE,
        overlay_log_path = module_directory() .. OVERLAY_LOG_FILE,
        overlay_script_path = module_directory() .. OVERLAY_SCRIPT,
        overlay_launcher_path = module_directory() .. OVERLAY_LAUNCHER,
        settings_open = false,
        settings_page = 0,
        selected_setting = 1,
        backend = "pending",
        key_label = "F3",
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
        native_settings_widget = nil,
        native_settings_widget_class = nil,
        native_widget_library = nil,
        native_settings_added = false,
        native_settings_creations = 0,
        native_console_registered = false,
        native_widget_lookup_logged = false,
        native_widget_failure_logged = {},
        native_text_bridge_logged = false,
        native_text_failure_logged = {},
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

    self.native_setting_keys = {
        "Language",
        "MeasurementMode",
        "TargetScope",
        "IncludePlayerDamage",
        "EnableSkillDPSHUD",
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
            -- diagnostics from F3 after seeing the new layout.
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
        file:write("-- Generated by PalSkillDPSAnalyzer's F3 settings panel.\n")
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

    -- Build the player-facing cast/Hit explanation once. Native CommonUI and
    -- the optional external workspace both consume this model, so terminology
    -- and uncertainty markers cannot drift between renderers.
    function self:detail_skill(skill)
        local unavailable = self:text("hud_value_unavailable")
        local casts = math.floor(tonumber(skill.casts) or 0)
        local hit_casts = math.floor(tonumber(skill.hit_casts) or 0)
        local zero_casts = math.floor(tonumber(skill.zero_damage_casts) or 0)
        local pending_casts = math.floor(tonumber(skill.pending_casts) or 0)
        local total_hits = math.floor(tonumber(skill.hits) or 0)
        local unassigned_hits = math.floor(tonumber(skill.unassigned_hits) or 0)
        local per_cast_hits = tostring(skill.per_cast_hits or "")
        local shown_samples = math.floor(tonumber(skill.per_cast_sample_count) or 0)
        local total_samples = math.floor(tonumber(skill.per_cast_total_samples) or 0)
        local truncated = skill.per_cast_samples_truncated == true
        local approximate = skill.per_cast_grouping_approximate == true
        local estimate = approximate and self:text("hud_value_estimated") or ""
        local samples = per_cast_hits ~= ""
            and string.gsub(per_cast_hits, "/", ", ") or unavailable
        local per_cast_text
        if truncated then
            per_cast_text = self:text("hud_detail_sample_recent", {
                shown = tostring(shown_samples),
                total = tostring(total_samples),
                estimate = estimate,
                samples = samples,
            })
        else
            per_cast_text = self:text("hud_detail_sample_all", {
                estimate = estimate,
                samples = samples,
            })
        end
        local pending_suffix = pending_casts > 0
            and self:text("hud_detail_pending_suffix", { pending = tostring(pending_casts) }) or ""
        local unassigned_suffix = unassigned_hits > 0
            and self:text("hud_detail_unassigned_suffix", { hits = tostring(unassigned_hits) }) or ""
        local minimum_hits = tonumber(skill.minimum_hits)
        local average_hits = tonumber(skill.average_hits)
        local maximum_hits = tonumber(skill.maximum_hits)
        local historical_max_hits = tonumber(skill.historical_max_hits)
        local full_hit_cap = tonumber(skill.full_hit_cap)
        return {
            hit_casts = hit_casts,
            zero_casts = zero_casts,
            pending_casts = pending_casts,
            per_cast_hits = per_cast_hits,
            minimum_hits = minimum_hits,
            average_hits = average_hits,
            maximum_hits = maximum_hits,
            historical_max_hits = historical_max_hits,
            full_hit_cap = full_hit_cap,
            approximate = approximate,
            unassigned_hits = unassigned_hits,
            casts_text = self:text("hud_detail_casts", {
                casts = tostring(casts),
                effective = tostring(hit_casts),
                zero = tostring(zero_casts),
                pending = pending_suffix,
            }),
            hits_text = self:text("hud_detail_hits", {
                hits = tostring(total_hits),
                per_cast = per_cast_text,
                unassigned = unassigned_suffix,
            }),
            range_text = self:text("hud_detail_range", {
                minimum = minimum_hits ~= nil and decimal(minimum_hits) or unavailable,
                average = average_hits ~= nil and decimal(average_hits) or unavailable,
                maximum = maximum_hits ~= nil and decimal(maximum_hits) or unavailable,
            }),
            limits_text = self:text("hud_detail_limits", {
                history = historical_max_hits ~= nil and decimal(historical_max_hits) or unavailable,
                asset = full_hit_cap ~= nil and decimal(full_hit_cap) or unavailable,
            }),
        }
    end

    function self:build_external_meter_document(snapshot, sequence)
        local final = snapshot.state == "finished"
        local manual_final = final
            and tostring(snapshot.measurement_mode or "") == "manual"
        local final_seconds = math.floor(tonumber(self.config.HUDFinalResultSeconds) or 15)
        -- A manually controlled Boss result belongs to the operator until F2.
        -- Never attach the automatic-target expiry to that frozen snapshot;
        -- otherwise the overlay hides valid rows while Lua still owns them.
        local expires_at = manual_final and 0 or tonumber(snapshot.expires_at)
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
                local compact_counts = self:text("hud_skill_cast_quality", {
                    hits = tostring(math.floor(tonumber(skill.hits) or 0)),
                    casts = tostring(math.floor(tonumber(skill.casts) or 0)),
                    hit_casts = tostring(math.floor(tonumber(skill.hit_casts) or 0)),
                    zero_casts = tostring(math.floor(tonumber(skill.zero_damage_casts) or 0)),
                    pending_casts = tostring(math.floor(tonumber(skill.pending_casts) or 0)),
                })
                local hit_completion = tonumber(skill.hit_completion)
                local hit_quality = self:text("hud_skill_hit_quality", {
                    hits = tostring(math.floor(tonumber(skill.hits) or 0)),
                    per_cast = tostring(skill.per_cast_hits or ""),
                    completion = hit_completion ~= nil
                        and string.format("%.1f%%", hit_completion)
                        or self:text("hud_value_uncalibrated"),
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
                    protocol_field(hit_quality),
                    protocol_field(skill.category or "skill"),
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
            "damage_label=" .. protocol_field(self:text("hud_total_damage_label")),
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
            "shortcut_hint=" .. protocol_field(self:text("hud_shortcut_hint")),
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
        return self:sync_input_lock(false)
    end

    function self:sync_input_lock(should_lock)
        local controller = self.get_player_controller and self.get_player_controller() or nil
        if not object_is_valid(controller) then return should_lock ~= true end
        if should_lock == true then
            if not object_is_valid(self.native_widget_library)
                or not object_is_valid(self.native_settings_widget) then
                return false
            end
            local mode_ok = call_method(
                self.native_widget_library,
                "SetInputMode_UIOnlyEx",
                controller,
                self.native_settings_widget,
                0,
                true
            )
            local cursor_ok = call_method(controller, "SetShowMouseCursor", true)
            if not cursor_ok then
                cursor_ok = set_object_property(controller, "bShowMouseCursor", true)
            end
            return mode_ok == true and cursor_ok == true
        end
        if object_is_valid(self.native_widget_library) then
            call_method(self.native_widget_library, "SetInputMode_GameOnly", controller, true)
        end
        local cursor_ok = call_method(controller, "SetShowMouseCursor", false)
        if not cursor_ok then
            set_object_property(controller, "bShowMouseCursor", false)
        end
        return true
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
            "selected_tab=" .. tostring(math.max(0, math.min(1, tonumber(self.settings_page) or 0))),
            "title=" .. protocol_field(self:text(
                self.settings_page == 1 and "hud_results_title" or "hud_settings_title"
            )),
            "settings_title=" .. protocol_field(self:text("hud_settings_title")),
            "results_title=" .. protocol_field(self:text("hud_results_title")),
            "damage_label=" .. protocol_field(self:text("hud_total_damage_label")),
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
                local detail = self:detail_skill(skill)
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
                    protocol_field(skill.category or "skill"),
                    tostring(detail.hit_casts), tostring(detail.zero_casts), tostring(detail.pending_casts),
                    protocol_field(detail.per_cast_hits), protocol_number(detail.minimum_hits),
                    protocol_number(detail.average_hits), protocol_number(detail.maximum_hits),
                    protocol_number(detail.historical_max_hits), protocol_number(detail.full_hit_cap),
                    detail.approximate and "1" or "0",
                    tostring(detail.unassigned_hits),
                    protocol_field(detail.casts_text), protocol_field(detail.hits_text),
                    protocol_field(detail.range_text), protocol_field(detail.limits_text),
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

    function self:resolve_native_settings_runtime()
        if self.config.EnableNativeCommonUISettings ~= true then
            return false, "native CommonUI settings are disabled"
        end
        if type(self.load_asset) ~= "function" or type(self.static_find_object) ~= "function" then
            return false, "LoadAsset/StaticFindObject unavailable"
        end
        if not object_is_valid(self.native_settings_widget_class) then
            local found, widget_class = pcall(self.static_find_object, NATIVE_SETTINGS_CLASS)
            if not found or not object_is_valid(widget_class) then
                local called, loaded_asset, asset_found, asset_loaded =
                    pcall(self.load_asset, NATIVE_SETTINGS_ASSET)
                if not called then
                    return false, "settings asset load failed: " .. tostring(loaded_asset)
                end
                if asset_found == false then
                    return false, "settings asset is not registered: " .. NATIVE_SETTINGS_ASSET
                end
                if asset_loaded == false then
                    return false, "settings asset was found but could not be loaded: "
                        .. NATIVE_SETTINGS_ASSET
                end

                -- UE4SS LoadAsset queries the asset registry by full object
                -- path (Package.Asset), not by package path alone. Prefer the
                -- blueprint's GeneratedClass, then re-check the generated
                -- class object after loading the asset.
                if object_is_valid(loaded_asset) then
                    local generated, generated_class = pcall(function()
                        return loaded_asset.GeneratedClass
                    end)
                    if generated and object_is_valid(generated_class) then
                        widget_class = generated_class
                        found = true
                    end
                end
                if not object_is_valid(widget_class) then
                    found, widget_class = pcall(self.static_find_object, NATIVE_SETTINGS_CLASS)
                end
            end
            if not found or not object_is_valid(widget_class) then
                return false, "settings widget class not found after loading " .. NATIVE_SETTINGS_ASSET
            end
            self.native_settings_widget_class = widget_class
        end
        if not object_is_valid(self.native_widget_library) then
            local found, library = pcall(self.static_find_object, WIDGET_LIBRARY_PATH)
            if not found or not object_is_valid(library) then
                return false, "WidgetBlueprintLibrary not found"
            end
            self.native_widget_library = library
        end
        return true
    end

    function self:ensure_native_settings_widget()
        if object_is_valid(self.native_settings_widget) then return true end
        self.native_settings_widget = nil
        self.native_settings_added = false
        local ready, ready_error = self:resolve_native_settings_runtime()
        if not ready then return false, ready_error end
        local world = self.get_world_context and self.get_world_context() or nil
        local controller = self.get_player_controller and self.get_player_controller() or nil
        if not object_is_valid(world) or not object_is_valid(controller) then
            return false, "world/player controller unavailable"
        end
        local created, widget = call_method(
            self.native_widget_library,
            "Create",
            world,
            self.native_settings_widget_class,
            controller
        )
        if not created or not object_is_valid(widget) then
            return false, "CommonUI widget creation failed"
        end
        self.native_settings_widget = widget
        self.native_settings_creations = self.native_settings_creations + 1
        return true
    end

    function self:native_widget(name)
        if not object_is_valid(self.native_settings_widget) then return nil end
        local widget_name = tostring(name or "")
        local ok, widget = pcall(function()
            return self.native_settings_widget[widget_name]
        end)
        if not ok or not object_is_valid(widget) then
            local reason = ok and "Blueprint variable not found" or ("Blueprint variable lookup failed: " .. tostring(widget))
            if self.native_widget_failure_logged[name] ~= reason then
                self.native_widget_failure_logged[name] = reason
                self.log("native CommonUI widget lookup failed name=" .. name .. " reason=" .. reason)
            end
            return nil
        end
        self.native_widget_failure_logged[name] = nil
        if not self.native_widget_lookup_logged then
            self.native_widget_lookup_logged = true
            self.log("native CommonUI widget lookup ready source=BlueprintVariable")
        end
        return widget
    end

    function self:set_native_text(name, value)
        local widget = self:native_widget(name)
        if widget == nil then return false end
        local text = tostring(value or "")
        if self.make_ftext == nil then
            if self.native_text_failure_logged[name] ~= "FText unavailable" then
                self.native_text_failure_logged[name] = "FText unavailable"
                self.log("native CommonUI text update failed name=" .. name .. " reason=FText unavailable")
            end
            return false
        end
        local converted, native_text = pcall(self.make_ftext, text)
        if not converted or native_text == nil then
            local reason = "FText conversion failed: " .. tostring(native_text)
            if self.native_text_failure_logged[name] ~= reason then
                self.native_text_failure_logged[name] = reason
                self.log("native CommonUI text update failed name=" .. name .. " reason=" .. reason)
            end
            return false
        end
        local called, set_error = call_method(widget, "SetText", native_text)
        if not called then
            local reason = "SetText failed: " .. tostring(set_error)
            if self.native_text_failure_logged[name] ~= reason then
                self.native_text_failure_logged[name] = reason
                self.log("native CommonUI text update failed name=" .. name .. " reason=" .. reason)
            end
            return false
        end
        self.native_text_failure_logged[name] = nil
        if not self.native_text_bridge_logged then
            self.native_text_bridge_logged = true
            self.log("native CommonUI text bridge ready type=FText")
        end
        return true
    end

    function self:native_detail_text()
        local snapshot = self.latest_snapshot
        if snapshot == nil then return self:text("hud_no_results") end
        local lines = {
            self:text("hud_result_context", {
                target = snapshot.boss,
                seconds = decimal(snapshot.duration),
                count = math.floor(tonumber(snapshot.target_count) or 1),
            }),
            string.format(
                "%s %s  ·  %s DPS",
                self:text("hud_total_damage_label"),
                integer(snapshot.total_damage),
                decimal(snapshot.encounter_dps)
            ),
            "",
        }
        local shown = 0
        for _, source in ipairs(snapshot.sources or {}) do
            for _, skill in ipairs(source.skills or {}) do
                shown = shown + 1
                local skill_name = self:skill_display_name(skill)
                local detail = self:detail_skill(skill)
                lines[#lines + 1] = string.format(
                    "%d. %s  ·  %s %s  ·  %s DPS",
                    shown,
                    skill_name,
                    self:text("hud_total_damage_label"),
                    integer(skill.damage),
                    decimal(skill.encounter_dps)
                )
                lines[#lines + 1] = detail.casts_text
                lines[#lines + 1] = detail.hits_text
                lines[#lines + 1] = detail.range_text
                lines[#lines + 1] = detail.limits_text
                lines[#lines + 1] = ""
            end
        end
        if shown == 0 then lines[#lines + 1] = self:text("hud_no_results") end
        return table.concat(lines, "\n")
    end

    function self:render_settings()
        self.last_rendered_text = nil
        if not self.settings_open or not object_is_valid(self.native_settings_widget) then
            return false
        end
        local switcher = self:native_widget("PSDPS_PageSwitcher")
        if switcher ~= nil then
            call_method(switcher, "SetActiveWidgetIndex", self.settings_page == 1 and 1 or 0)
        end
        self:set_native_text("PSDPS_Title", self:text(
            self.settings_page == 1 and "hud_results_title" or "hud_settings_title"
        ))
        self:set_native_text("PSDPS_Footer", self:text("hud_settings_footer", { key = self.key_label }))
        self:set_native_text("PSDPS_DetailRows", self:native_detail_text())
        for _, key in ipairs(self.native_setting_keys) do
            self:set_native_text("PSDPS_" .. key .. "_Value", self:setting_value_text(key))
        end
        return true
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
        -- Measurement policy is captured by the active test. Changing these
        -- controls prepares the next test but must never clear current/frozen
        -- data behind the player's back; F2 is the only reset action.
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
            -- Keep the external HUD display-only. The in-game CommonUI widget owns
            -- settings interaction, cursor focus, and input mode.
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
        self.settings_page = 0
        self:sync_input_lock(false)
        if object_is_valid(self.native_settings_widget) and self.native_settings_added then
            call_method(self.native_settings_widget, "DeactivateWidget")
            call_method(self.native_settings_widget, "RemoveFromParent")
        end
        self.native_settings_added = false
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
        if self.config.EnableExternalHUDSettings ~= true then return false end
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
        if self.config.EnableNativeCommonUISettings ~= true then
            self.log("F3 settings refused: native CommonUI settings are disabled")
            self:show_notice(self:text("hud_settings_unavailable"), 3)
            return false
        end
        local created, create_error = self:ensure_native_settings_widget()
        if not created then
            self.log("F3 settings refused: " .. tostring(create_error))
            self:show_notice(self:text("hud_settings_unavailable"), 3)
            return false
        end
        self.settings_open = true
        self.settings_page = 0
        self.gameplay_available = true
        self:write_external_state("", false)
        local added = call_method(self.native_settings_widget, "AddToViewport", 10000)
        if not added then
            self.settings_open = false
            self.log("F3 settings refused: AddToViewport failed")
            self:show_notice(self:text("hud_settings_unavailable"), 3)
            return false
        end
        self.native_settings_added = true
        call_method(self.native_settings_widget, "ActivateWidget")
        if not self:sync_input_lock(true) then
            self.settings_open = false
            call_method(self.native_settings_widget, "DeactivateWidget")
            call_method(self.native_settings_widget, "RemoveFromParent")
            self.native_settings_added = false
            self:sync_input_lock(false)
            self.log("F3 settings refused: Palworld UI input mode could not be acquired")
            self:show_notice(self:text("hud_settings_unavailable"), 3)
            return false
        end
        call_method(self.native_settings_widget, "SetKeyboardFocus")
        self.last_rendered_text = nil
        self:render_settings()
        return true
    end

    function self:register_console_commands()
        if self.native_console_registered then return true end
        if type(self.register_console_command_handler) ~= "function" then
            self.log("native settings console command handler unavailable")
            return false
        end
        local function parameters_as_words(command, parameters)
            local words = {}
            if type(parameters) == "table" then
                local indexes = {}
                for index in pairs(parameters) do
                    if type(index) == "number" then indexes[#indexes + 1] = index end
                end
                table.sort(indexes)
                for _, index in ipairs(indexes) do
                    words[#words + 1] = tostring(parameters[index])
                end
            end
            if #words == 0 then
                for word in string.gmatch(tostring(command or ""), "%S+") do
                    if string.lower(word) ~= "psdps" then words[#words + 1] = word end
                end
            end
            return words
        end
        local function handle(command, parameters)
            local words = parameters_as_words(command, parameters)
            if string.lower(tostring(words[1] or "")) ~= "ui" then return false end
            local action = string.lower(tostring(words[2] or ""))
            local function apply()
                if action == "close" then
                    self:close_settings()
                elseif action == "reset" and self.settings_open then
                    self:reset_test()
                    self:render_settings()
                elseif action == "tab" and self.settings_open then
                    self.settings_page = string.lower(tostring(words[3] or "")) == "details" and 1 or 0
                    self:render_settings()
                elseif action == "cycle" and self.settings_open then
                    local key = tostring(words[3] or "")
                    local allowed = false
                    for _, candidate in ipairs(self.native_setting_keys) do
                        if candidate == key then allowed = true break end
                    end
                    if allowed then
                        self:cycle_setting(key, tonumber(words[4]) == -1 and -1 or 1)
                        self:render_settings()
                    end
                end
            end
            if type(ExecuteInGameThread) == "function" then
                ExecuteInGameThread(apply)
            else
                apply()
            end
            return true
        end
        local ok, register_error = pcall(self.register_console_command_handler, "psdps", handle)
        if not ok then
            self.log("native settings console command registration failed: " .. tostring(register_error))
            return false
        end
        self.native_console_registered = true
        self.log("native CommonUI settings command=psdps ui ...")
        return true
    end

    function self:register_keybinds()
        local register_async = type(RegisterKeyBindAsync) == "function"
        local register_function = register_async and RegisterKeyBindAsync or RegisterKeyBind
        if type(register_function) ~= "function" or type(Key) ~= "table" then
            self.log("HUD keybind unavailable")
            return false
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
            if Key.F3 ~= nil then
                register(Key.F3, {}, in_game(function() self:toggle_settings() end))
            end
            if Key.F2 ~= nil then
                register(Key.F2, {}, in_game(function()
                    if not self:gameplay_is_available() then return false end
                    return self:reset_test_from_key()
                end))
            end
        end)
        if not ok then
            self.log("HUD keybind registration failed: " .. tostring(register_error))
            return false
        end
        self.log("HUD settings/details hotkey=" .. self.key_label .. "; reset hotkey=" .. self.reset_key_label)
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
            -- CommonUI is created once. Live updates only replace text inside
            -- the existing widget, so the panel does not flash or lose focus.
            self:render_settings()
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
        local manual_final = snapshot.state == "finished"
            and tostring(snapshot.measurement_mode or "") == "manual"
        if snapshot.state == "finished" and not manual_final then
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
