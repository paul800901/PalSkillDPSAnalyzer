---@diagnostic disable: undefined-global

local config = require("./config")
local battle_commentary = require("./commentary")
local localization = require("./localization")
local skill_names = require("./skill_names")
local skill_effect_attribution = require("./skill_effect_attribution")
local runtime_source_chain = require("./runtime_source_chain")
local hud_module = require("./hud")

local MOD = "[PalSkillDPSAnalyzer]"
local unpack_args = table.unpack or unpack
local sessions = {}
local session_addresses = {}
local session_actor_keys = {}
local global_source_owner_cache = {}
local hooks = {
    damage = false,
    damage_mode = "none",
    final_damage = false,
    final_damage_path = "none",
    waza = false,
    action_begin = false,
    action_end = false,
    effect_initialize = false,
    attack_filter = false,
    effect_attack_count = 0,
    death = false,
    captured = false,
    captured_count = 0,
}
local cached_pal_utility = nil
local cached_gameplay_statics = nil
local cached_world_context = nil
local non_boss_addresses = {}
local recent_waza_by_pair = {}
local recent_waza_by_attacker = {}
local cached_waza_enum = nil
local cached_pal_ui_utility = nil
local cached_waza_database = nil
local cached_waza_metadata = {}
local canonical_skill_name
local game_time_seconds
local attack_signature
local action_skill_name
local action_records = {}
local action_record_order = {}
local recent_actions_by_actor = {}
local delayed_effect_bindings = {}
local source_chain = nil
local skill_hud = nil
hooks.last_native_status_hit_report = 0

-- Native damage hooks may run in the middle of an Unreal call. They must not
-- call UFunctions or retain references to the temporary event struct. The
-- hook copies only actor wrappers and primitive values into this bounded FIFO.
local pending_events = {}
local pending_head = 1
local pending_tail = 0
local drain_scheduled = false
local pending_messages = {}
local message_head = 1
local message_tail = 0
local message_pump_running = false
local metrics = {
    accepted = 0,
    dropped = 0,
    processed = 0,
    invalid = 0,
    errors = 0,
    non_boss_cache_hits = 0,
    composite_joins = 0,
    pal_metadata_cache_hits = 0,
    source_owner_cache_hits = 0,
    contributor_cache_hits = 0,
    native_buckets = 0,
    native_hits = 0,
    native_events = 0,
    ignored_player_damage = 0,
    waza_markers = 0,
    waza_matches = 0,
    skill_candidates = 0,
    skill_samples = 0,
    action_begins = 0,
    action_ends = 0,
    trace_events = 0,
}

local function log(message)
    print(MOD .. " " .. tostring(message) .. "\n")
end

hooks.log_native_diagnostic_status = function(reason)
    if type(BossDPSNativeStatus) ~= "function" then
        return
    end
    local ok, status = pcall(BossDPSNativeStatus)
    if ok then
        log("native diagnostic status reason=" .. tostring(reason)
            .. " " .. tostring(status))
    else
        metrics.errors = metrics.errors + 1
        log("native diagnostic status failed: " .. tostring(status))
    end
    if type(BossDPSNativeProbeReport) == "function" then
        local report_ok, report = pcall(BossDPSNativeProbeReport)
        if report_ok then
            log("native damage handler probe reason=" .. tostring(reason)
                .. " " .. tostring(report))
        else
            metrics.errors = metrics.errors + 1
            log("native damage handler probe failed: " .. tostring(report))
        end
    end
end

local function classify_native_target(target_key, state)
    if target_key == nil or type(BossDPSNativeClassifyTarget) ~= "function" then
        return
    end
    local ok, err = pcall(BossDPSNativeClassifyTarget, tostring(target_key), tostring(state))
    if not ok then
        metrics.errors = metrics.errors + 1
        log("native target classification failed: " .. tostring(err))
    end
end

local function safe_call(object, method_name, ...)
    if object == nil then
        return false, nil
    end

    local args = { ... }
    local method_found = false
    local ok, result = pcall(function()
        local method = object[method_name]
        if method == nil then
            return nil
        end
        method_found = true
        return method(object, unpack_args(args))
    end)
    if not ok then
        return false, result
    end
    if not method_found then
        return false, "method unavailable: " .. tostring(method_name)
    end
    return true, result
end

local function safe_property(object, property_name)
    if object == nil then
        return false, nil
    end
    return pcall(function()
        return object[property_name]
    end)
end

local function unwrap(value)
    if value == nil then
        return nil
    end

    local value_type = type(value)
    if value_type ~= "table" and value_type ~= "userdata" then
        return value
    end

    local ok, result = pcall(function()
        if value.get ~= nil then
            return value:get()
        end
        return value
    end)
    if ok then
        return result
    end
    return value
end

local function to_number(value)
    value = unwrap(value)
    if type(value) == "number" then
        return value
    end
    return tonumber(tostring(value or "")) or 0
end

local function finite_positive_number(value)
    local number = to_number(value)
    if number ~= number or number == math.huge or number == -math.huge or number <= 0 then
        return nil
    end
    return number
end

local function bool_value(value)
    value = unwrap(value)
    return value == true or value == 1 or tostring(value) == "true"
end

local function is_valid(object)
    if object == nil then
        return false
    end
    local ok, result = safe_call(object, "IsValid")
    return ok and result == true
end

local function text_value(value)
    value = unwrap(value)
    if value == nil then
        return ""
    end

    local ok, result = safe_call(value, "GetDisplayString")
    if ok and result ~= nil then
        value = result
    end

    ok, result = safe_call(value, "ToString")
    if ok and result ~= nil then
        value = result
    end

    local text = tostring(value or "")
    if text == "nil" or text == "None" or text == "Invalid" then
        return ""
    end
    return string.gsub(text, "^[%w_]+:%s*", "")
end

local translator = nil
local translator_requested = nil

local function detect_game_language()
    local ok, library = pcall(
        StaticFindObject,
        "/Script/Engine.Default__KismetInternationalizationLibrary"
    )
    if not ok or library == nil then
        return nil
    end
    local language_ok, language = safe_call(library, "GetCurrentLanguage")
    if language_ok then
        return text_value(language)
    end
    local localized_ok, localized = safe_call(library, "GetLocalizedLanguage")
    if localized_ok then
        return text_value(localized)
    end
    return nil
end

local function get_translator()
    local requested = tostring(config.Language or "auto")
    if translator == nil or translator_requested ~= requested then
        translator = localization.new(requested, detect_game_language)
        translator_requested = requested
        log("language selected=" .. tostring(translator.code)
            .. " requested=" .. requested)
    end
    return translator
end

local function tr(key, values)
    return get_translator():text(key, values)
end

local function localized_override(value)
    return get_translator():override(value)
end

local function skill_display_name(internal_code, runtime_name)
    local code = tostring(internal_code or "")
    local runtime = tostring(runtime_name or "")
    if tostring(config.Language or "auto") == "auto" and runtime ~= "" then
        return runtime
    end
    local bundled = skill_names.get(code, get_translator().code)
    if bundled ~= nil and bundled ~= "" then
        return bundled
    end
    if runtime ~= "" then
        return runtime
    end
    return code ~= "" and code or "UNKNOWN"
end

local function fun_commentary_enabled()
    -- The optional meme-heavy pool is intentionally Chinese-only. Core combat
    -- reports remain fully localized in every supported language.
    return config.EnableFunComments ~= false and get_translator().code == "zh-CN"
end

-- UE4SS converts Lua strings to Unreal FString when sending chat. Lua's
-- string.sub works in bytes, so cutting a Chinese name in the middle of a
-- multi-byte character produces an invalid UTF-8 string and UE4SS raises
-- "bad conversion". Keep every label and final message on valid boundaries.
local function utf8_sequence_length(text, index)
    local first = string.byte(text, index)
    if first == nil then
        return nil
    end
    if first <= 0x7F then
        return 1
    end

    local second = string.byte(text, index + 1)
    local third = string.byte(text, index + 2)
    local fourth = string.byte(text, index + 3)
    local continuation = function(value)
        return value ~= nil and value >= 0x80 and value <= 0xBF
    end

    if first >= 0xC2 and first <= 0xDF and continuation(second) then
        return 2
    end
    if first == 0xE0 and second ~= nil and second >= 0xA0 and second <= 0xBF
        and continuation(third) then
        return 3
    end
    if ((first >= 0xE1 and first <= 0xEC) or (first >= 0xEE and first <= 0xEF))
        and continuation(second) and continuation(third) then
        return 3
    end
    if first == 0xED and second ~= nil and second >= 0x80 and second <= 0x9F
        and continuation(third) then
        return 3
    end
    if first == 0xF0 and second ~= nil and second >= 0x90 and second <= 0xBF
        and continuation(third) and continuation(fourth) then
        return 4
    end
    if first >= 0xF1 and first <= 0xF3 and continuation(second)
        and continuation(third) and continuation(fourth) then
        return 4
    end
    if first == 0xF4 and second ~= nil and second >= 0x80 and second <= 0x8F
        and continuation(third) and continuation(fourth) then
        return 4
    end
    return nil
end

local function sanitize_utf8(value)
    local input = tostring(value or "")
    local output = {}
    local index = 1
    while index <= #input do
        local length = utf8_sequence_length(input, index)
        if length == nil then
            output[#output + 1] = "?"
            index = index + 1
        else
            local first = string.byte(input, index)
            if length == 1 and (first < 0x20 or first == 0x7F) then
                output[#output + 1] = " "
            else
                output[#output + 1] = string.sub(input, index, index + length - 1)
            end
            index = index + length
        end
    end
    return table.concat(output)
end

local function truncate_utf8(value, max_characters)
    local text = sanitize_utf8(value)
    local index = 1
    local count = 0
    local last_byte = 0
    while index <= #text and count < max_characters do
        local length = utf8_sequence_length(text, index) or 1
        last_byte = index + length - 1
        index = index + length
        count = count + 1
    end
    if last_byte < #text then
        return string.sub(text, 1, last_byte) .. "…"
    end
    return text
end

local function clean_label(value, fallback)
    local label = sanitize_utf8(text_value(value))
    label = string.gsub(label, "%s+", " ")
    if label == "" then
        label = sanitize_utf8(fallback or "")
    end
    return truncate_utf8(label, 48)
end

local function actor_full_name(actor)
    local ok, name = safe_call(actor, "GetFullName")
    if ok and name ~= nil then
        return text_value(name)
    end
    return ""
end

local function actor_address(actor)
    local ok, address = safe_call(actor, "GetAddress")
    address = ok and to_number(address) or 0
    if address <= 0 then
        return nil
    end
    return tostring(address)
end

local function actor_short_name(actor)
    local full_name = actor_full_name(actor)
    local text = string.match(full_name, "%.([^%.%s:]+)$") or ""
    if text == "" then
        local ok, name = safe_call(actor, "GetName")
        text = ok and text_value(name) or full_name
    end
    text = string.gsub(text, "_C_%d+$", "")
    text = string.gsub(text, "_C$", "")
    text = string.gsub(text, "^BP_", "")
    return text ~= "" and text or "Boss"
end

local function stable_object_identity(value)
    local text = tostring(value or "")
    text = string.gsub(text, "_C_%d+$", "_C")
    text = string.gsub(text, "_(%d+)$", "")
    return text
end

local function diagnostic_object_info(object)
    if not is_valid(object) then
        return {
            address = "",
            full_name = "",
            short_name = "",
            class_name = "",
        }
    end

    local full_name = actor_full_name(object)
    local short_name = actor_short_name(object)
    local class_name = ""
    local class_ok, class = safe_call(object, "GetClass")
    if class_ok and is_valid(class) then
        class_name = actor_full_name(class)
        if class_name == "" then
            local name_ok, name = safe_call(class, "GetName")
            class_name = name_ok and text_value(name) or ""
        end
    end

    return {
        address = actor_address(object) or "",
        full_name = stable_object_identity(full_name),
        short_name = stable_object_identity(short_name),
        class_name = stable_object_identity(class_name),
    }
end

local function guid_parts(value)
    value = unwrap(value)
    if value == nil then
        return nil
    end
    local ok, a, b, c, d = pcall(function()
        return value.A, value.B, value.C, value.D
    end)
    if not ok or a == nil or b == nil or c == nil or d == nil then
        return nil
    end
    return { A = a, B = b, C = c, D = d }
end

local function guid_key(value)
    local guid = guid_parts(value)
    if guid == nil then
        return nil
    end
    if to_number(guid.A) == 0 and to_number(guid.B) == 0
        and to_number(guid.C) == 0 and to_number(guid.D) == 0 then
        return nil
    end
    return table.concat({ tostring(guid.A), tostring(guid.B), tostring(guid.C), tostring(guid.D) }, ":")
end

local function action_instance_key(action)
    local id_ok, action_id = safe_call(action, "GetActionID")
    local id = id_ok and guid_key(action_id) or nil
    if id ~= nil then
        return "guid:" .. id
    end
    local identity = actor_address(action) or actor_full_name(action)
    return identity ~= nil and identity ~= "" and ("object:" .. tostring(identity)) or nil
end

local function copy_guid(value)
    local guid = guid_parts(value)
    if guid == nil then
        return nil
    end
    return {
        A = to_number(guid.A),
        B = to_number(guid.B),
        C = to_number(guid.C),
        D = to_number(guid.D),
    }
end

local function get_pal_utility()
    if cached_pal_utility ~= nil then
        return cached_pal_utility
    end
    local utility = StaticFindObject("/Script/Pal.Default__PalUtility")
    if is_valid(utility) then
        cached_pal_utility = utility
        return utility
    end
    return nil
end

local function get_gameplay_statics()
    if cached_gameplay_statics ~= nil then
        return cached_gameplay_statics
    end
    local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if is_valid(statics) then
        cached_gameplay_statics = statics
        return statics
    end
    return nil
end

local function find_world_context()
    if cached_world_context ~= nil and is_valid(cached_world_context) then
        return cached_world_context
    end
    local world = FindFirstOf("PalGameStateInGame")
    if is_valid(world) then
        cached_world_context = world
        return world
    end
    cached_world_context = nil
    return nil
end

local function player_uid(player_state)
    if not is_valid(player_state) then
        return nil
    end
    local ok, uid = safe_property(player_state, "PlayerUId")
    return ok and guid_key(uid) ~= nil and uid or nil
end

local function get_local_player_controller()
    local world = find_world_context()
    local statics = get_gameplay_statics()
    if world == nil or statics == nil then
        return nil
    end
    local controller_ok, controller = safe_call(statics, "GetPlayerController", world, 0)
    if not controller_ok or not is_valid(controller) then
        return nil
    end
    return controller
end

-- The Windows HUD is useful only while a playable pawn owns the screen. The
-- same Palworld process also owns the title screen, loading screens and native
-- pause/options menus, so foreground-process checks alone cannot distinguish
-- those states. F1's own workspace is allowed after it has acquired the pawn;
-- its cursor flag must not make the workspace hide itself.
local function local_gameplay_available(settings_open)
    local world = find_world_context()
    local statics = get_gameplay_statics()
    local controller = get_local_player_controller()
    if world == nil or statics == nil or controller == nil then
        return false
    end
    local pawn_ok, pawn = safe_call(controller, "GetPawn")
    if not pawn_ok or not is_valid(pawn) then
        pawn_ok, pawn = safe_property(controller, "Pawn")
    end
    if not pawn_ok or not is_valid(pawn) then
        return false
    end
    if settings_open == true then
        return true
    end
    local paused_ok, paused = safe_call(statics, "IsGamePaused", world)
    if paused_ok and bool_value(paused) then
        return false
    end
    local cursor_ok, cursor_visible = safe_property(controller, "bShowMouseCursor")
    if cursor_ok and bool_value(cursor_visible) then
        return false
    end
    return true
end

local function local_player_uid()
    local controller = get_local_player_controller()
    if controller == nil then
        return nil
    end
    local state_ok, state = safe_property(controller, "PlayerState")
    if not state_ok then
        return nil
    end
    return player_uid(state)
end

local function player_name(player_state)
    local ok, name = safe_property(player_state, "PlayerNamePrivate")
    name = ok and text_value(name) or ""
    if name == "" then
        local object_ok, object_name = safe_call(player_state, "GetName")
        name = object_ok and text_value(object_name) or "Unknown Player"
    end
    return clean_label(name, "Unknown Player")
end

local function state_from_actor_property(actor)
    local ok, state = safe_property(actor, "PlayerState")
    if ok and player_uid(state) ~= nil then
        return state
    end
    return nil
end

local function resolve_player_state(attacker, utility)
    if not is_valid(attacker) then
        return nil
    end

    local state = state_from_actor_property(attacker)
    if state ~= nil then
        return state
    end

    local state_ok, utility_state = safe_call(utility, "GetPlayerState", attacker)
    if state_ok and player_uid(utility_state) ~= nil then
        return utility_state
    end

    local trainer_ok, trainer = safe_call(utility, "GetTrainerPlayer", attacker)
    if not trainer_ok or not is_valid(trainer) then
        return nil
    end

    state = state_from_actor_property(trainer)
    if state ~= nil then
        return state
    end

    state_ok, utility_state = safe_call(utility, "GetPlayerState", trainer)
    if state_ok and player_uid(utility_state) ~= nil then
        return utility_state
    end
    return nil
end

local function state_from_player_actor(actor, utility)
    local state = state_from_actor_property(actor)
    if state ~= nil then
        return state
    end
    local state_ok, utility_state = safe_call(utility, "GetPlayerState", actor)
    return state_ok and player_uid(utility_state) ~= nil and utility_state or nil
end

local function trainer_state(actor, utility)
    local trainer_ok, trainer = safe_call(utility, "GetTrainerPlayer", actor)
    if not trainer_ok or not is_valid(trainer) then
        return nil
    end
    return state_from_player_actor(trainer, utility)
end

local function cached_source_owner(cache, identity)
    if cache == nil or identity == nil or identity == "" then
        return nil, nil, nil
    end
    local entry = cache[identity]
    if entry == nil then
        return nil, nil, nil
    end
    if not is_valid(entry.state) or not is_valid(entry.source_actor) then
        cache[identity] = nil
        return nil, nil, nil
    end
    metrics.source_owner_cache_hits = metrics.source_owner_cache_hits + 1
    return entry.state, entry.source_kind, entry.source_actor
end

local function remember_source_owner(cache, identity, state, source_kind, source_actor)
    if cache == nil or identity == nil or identity == "" or state == nil or source_actor == nil then
        return
    end
    cache._order = cache._order or {}
    cache._head = cache._head or 1
    cache._tail = cache._tail or 0
    local entry = cache[identity]
    if entry == nil then
        entry = {}
        cache._tail = cache._tail + 1
        cache._order[cache._tail] = { identity = identity, entry = entry }
    end
    entry.state = state
    entry.source_kind = source_kind
    entry.source_actor = source_actor
    cache[identity] = entry

    local max_entries = math.max(64, math.floor(to_number(config.MaxSourceOwnerCacheEntries)))
    while cache._tail - cache._head + 1 > max_entries do
        local expired = cache._order[cache._head]
        cache._order[cache._head] = nil
        cache._head = cache._head + 1
        if expired ~= nil and cache[expired.identity] == expired.entry then
            cache[expired.identity] = nil
        end
    end
end

local function resolve_source_actor(candidate, utility, depth, seen, cache)
    if depth > 3 or not is_valid(candidate) then
        return nil, nil, nil
    end
    local identity = actor_address(candidate) or actor_full_name(candidate)
    if identity ~= "" and seen[identity] then
        return nil, nil, nil
    end
    if identity ~= "" then
        seen[identity] = true
    end

    local cached_state, cached_kind, cached_actor = cached_source_owner(cache, identity)
    if cached_state ~= nil then
        return cached_state, cached_kind, cached_actor
    end

    -- A real Pal character exposes CharacterParameterComponent. Checking this
    -- before generic player lookup prevents a mounted Pal from becoming a
    -- player row when a helper API resolves its trainer.
    local component_ok, component = safe_property(candidate, "CharacterParameterComponent")
    if component_ok and is_valid(component) then
        local state = trainer_state(candidate, utility)
        if state ~= nil then
            remember_source_owner(cache, identity, state, "pal", candidate)
            return state, "pal", candidate
        end
    end

    local state = state_from_player_actor(candidate, utility)
    if state ~= nil then
        remember_source_owner(cache, identity, state, "player", candidate)
        return state, "player", candidate
    end

    -- Skill projectiles and unique ride weapons commonly keep the true source
    -- in one of these ownership fields. Follow a small bounded chain only.
    for _, property_name in ipairs({ "Owner", "Instigator", "InstigatorController", "OverrideNetworkOwner" }) do
        local nested_ok, nested = safe_property(candidate, property_name)
        if nested_ok and is_valid(nested) then
            local nested_state, nested_kind, nested_source =
                resolve_source_actor(nested, utility, depth + 1, seen, cache)
            if nested_state ~= nil then
                remember_source_owner(cache, identity, nested_state, nested_kind, nested_source)
                return nested_state, nested_kind, nested_source
            end
        end
    end

    local fallback_state = trainer_state(candidate, utility)
    if fallback_state ~= nil then
        remember_source_owner(cache, identity, fallback_state, "pal", candidate)
        return fallback_state, "pal", candidate
    end
    return nil, nil, nil
end

local function resolve_damage_owner(event, utility, cache)
    local candidates = {}
    for _, field_name in ipairs({
        "damage_causer", "override_network_owner", "info_attacker", "attacker",
    }) do
        local candidate = event[field_name]
        if candidate ~= nil then
            candidates[#candidates + 1] = candidate
        end
    end
    local seen = {}
    for _, candidate in ipairs(candidates) do
        if candidate ~= nil then
            local state, source_kind, source_actor =
                resolve_source_actor(candidate, utility, 0, seen, cache)
            if state ~= nil then
                return state, source_kind, source_actor
            end
        end
    end
    return nil, nil, nil
end

local function actor_name_matches_boss_pattern(actor)
    local lower_name = string.lower(actor_full_name(actor))
    if lower_name == "" then
        return false
    end
    for _, pattern in ipairs(config.BossNamePatterns or {}) do
        if string.find(lower_name, string.lower(tostring(pattern)), 1, true) ~= nil then
            return true
        end
    end
    return false
end

local function actor_is_player_owned(actor, utility)
    local ok, trainer = safe_call(utility, "GetTrainerPlayer", actor)
    return ok and is_valid(trainer)
end

local function normalized_boss_id(value)
    local text = text_value(value)
    text = string.match(text, "%.([^%.%s:]+)$") or text
    text = string.gsub(text, "_C_%d+$", "")
    text = string.gsub(text, "_C$", "")
    text = string.gsub(text, "^BP_", "")
    text = string.gsub(text, "^BOSS_", "")
    return text
end

local function composite_part_info(short_name)
    local part_id = normalized_boss_id(short_name)
    local definition = (config.CompositeBossParts or {})[part_id]
    if type(definition) ~= "table" or tostring(definition.group or "") == "" then
        return nil
    end
    return {
        id = part_id,
        group = tostring(definition.group),
        terminal = definition.terminal == true,
    }
end

local function composite_anchor_address(actor)
    local current = actor
    local last_address = nil
    local seen = {}
    for _ = 1, 4 do
        local current_address = actor_address(current)
        if current_address ~= nil then
            if seen[current_address] then
                break
            end
            seen[current_address] = true
        end

        local owner_ok, owner = safe_property(current, "Owner")
        if not owner_ok or not is_valid(owner) then
            local attach_ok, attach_parent = safe_call(current, "GetAttachParentActor")
            owner = attach_ok and attach_parent or nil
        end
        if not is_valid(owner) then
            break
        end
        local owner_address = actor_address(owner)
        if owner_address == nil or owner_address == current_address then
            break
        end
        last_address = owner_address
        current = owner
    end
    return last_address
end

local function boss_display_name(actor, utility, short_name)
    local character_id
    local id_ok, id_value = safe_call(utility, "GetCharacterIDFromCharacter", actor)
    if id_ok then
        character_id = normalized_boss_id(id_value)
    end

    -- This lookup runs once, on the game thread, when a session starts. The
    -- out-table matches UE4SS handling for FString/FText out parameters.
    if character_id ~= nil and character_id ~= "" then
        local world = find_world_context()
        local database_ok, database = false, nil
        if world ~= nil then
            database_ok, database = safe_call(utility, "GetDatabaseCharacterParameter", world)
        end
        if database_ok and is_valid(database) then
            local out_text = {}
            local localized_ok = safe_call(database, "GetLocalizedCharacterName", id_value, out_text)
            if localized_ok then
                local localized = text_value(out_text.OutText)
                if localized ~= "" and string.find(localized, "/Game/", 1, true) == nil then
                    return localized
                end
            end
        end
    end

    -- Prefer Palworld's own localized name. Overrides remain a fallback for
    -- custom or missing database entries and can themselves be localized.
    local overrides = config.BossNameOverrides or {}
    local candidates = { character_id, normalized_boss_id(short_name), short_name }
    for _, candidate in ipairs(candidates) do
        if candidate ~= nil and candidate ~= "" then
            local override = localized_override(overrides[candidate])
            if override ~= nil and tostring(override) ~= "" then
                return tostring(override)
            end
            local without_suffix = string.gsub(candidate, "_BOSS$", "")
            override = localized_override(overrides[without_suffix])
            if override ~= nil and tostring(override) ~= "" then
                return tostring(override)
            end
        end
    end

    -- A short internal id is preferable to leaking the full UObject path if
    -- this Pal has no localized name on the dedicated server.
    return normalized_boss_id(short_name)
end

local function get_boss_info(actor, utility)
    if not is_valid(actor) or actor_is_player_owned(actor, utility) then
        return nil
    end

    -- These are reflected bool properties on UPalStaticCharacterParameterComponent.
    -- Reading them avoids the crashing IsBossPal_Database/IsTowerBossPal UFunctions.
    local component_ok, component = safe_property(actor, "StaticCharacterParameterComponent")
    local is_boss = false
    if component_ok and is_valid(component) then
        local boss_ok, boss_value = safe_property(component, "IsBoss_Database")
        local tower_ok, tower_value = safe_property(component, "IsTowerBoss_Database")
        is_boss = (boss_ok and bool_value(boss_value)) or (tower_ok and bool_value(tower_value))
    end

    if not is_boss and config.UseBossNameFallback == true then
        is_boss = actor_name_matches_boss_pattern(actor)
    end
    if not is_boss then
        return nil
    end

    local full_name = actor_full_name(actor)
    if full_name == "" then
        return nil
    end
    local short_name = actor_short_name(actor)
    local display_name = boss_display_name(actor, utility, short_name)
    local composite = composite_part_info(short_name)
    return {
        key = full_name,
        address = actor_address(actor),
        name = tostring(display_name),
        is_boss = true,
        composite_group = composite and composite.group or nil,
        composite_part = composite and composite.id or nil,
        composite_terminal = composite and composite.terminal or false,
        composite_anchor = composite and composite_anchor_address(actor) or nil,
    }
end

local function localized_character_name(character_id, utility, fallback)
    local normalized = normalized_boss_id(character_id)
    local world = find_world_context()
    if world ~= nil then
        local database_ok, database = safe_call(utility, "GetDatabaseCharacterParameter", world)
        if database_ok and is_valid(database) then
            local out_text = {}
            local localized_ok = safe_call(database, "GetLocalizedCharacterName", character_id, out_text)
            if localized_ok then
                local localized = text_value(
                    out_text.OutText or out_text.outText or out_text.ReturnValue
                )
                if localized ~= "" and string.find(localized, "/Game/", 1, true) == nil then
                    return clean_label(localized, fallback)
                end
            end
        end
    end

    local override = localized_override((config.PalNameOverrides or {})[normalized])
    if override ~= nil and tostring(override) ~= "" then
        return clean_label(override, fallback)
    end
    return clean_label(normalized, fallback)
end

local function pal_source_info(actor, utility)
    local component_ok, component = safe_property(actor, "CharacterParameterComponent")
    local individual_ok, individual = false, nil
    if component_ok and is_valid(component) then
        individual_ok, individual = safe_property(component, "IndividualParameter")
    end

    local source_key = actor_address(actor) or actor_full_name(actor)
    local character_id = actor_short_name(actor)
    local nickname = ""
    if individual_ok and is_valid(individual) then
        source_key = actor_address(individual) or source_key
        local id_ok, id_value = safe_call(individual, "GetCharacterID")
        if id_ok and text_value(id_value) ~= "" then
            character_id = id_value
        end
        local out_name = {}
        local nickname_ok = safe_call(individual, "GetNickname", out_name)
        if nickname_ok then
            nickname = clean_label(
                out_name.outName or out_name.OutName or out_name.OutText or out_name.ReturnValue,
                ""
            )
        end
    end

    local species = localized_character_name(character_id, utility, actor_short_name(actor))
    local display = species
    if nickname ~= "" and nickname ~= species then
        display = tr("nickname_species", {
            nickname = nickname,
            species = species,
        })
    end
    return tostring(source_key or display), display, species, nickname
end

local function player_team_info(player_state, uid, fallback_name)
    local guild_ok, guild = safe_property(player_state, "GuildBelongTo")
    if guild_ok and is_valid(guild) then
        local guild_key = actor_address(guild)
        local name_ok, guild_name = safe_property(guild, "GuildName")
        guild_name = name_ok and clean_label(guild_name, "") or ""
        if guild_name == "" then
            local call_ok, call_name = safe_call(guild, "GetGuildName")
            guild_name = call_ok and clean_label(call_name, "") or ""
        end
        if guild_key ~= nil then
            return "guild:" .. guild_key, guild_name ~= "" and guild_name or tr("unnamed_guild")
        end
    end
    return "solo:" .. tostring(guid_key(uid)), tr("solo_team", {
        player = tostring(fallback_name),
    })
end

local function send_participant_message(message, recipients)
    local utility = get_pal_utility()
    local world = find_world_context()
    if utility == nil or world == nil then
        log("participant message skipped: PalUtility or PalGameStateInGame unavailable")
        return false
    end

    local chat_text = sanitize_utf8(message)
    local receiver_uids = recipients or {}
    if #receiver_uids == 0 then
        return false
    end

    -- Palworld 1.0 expects TArray<FGuid>, not one FGuid per call. Passing a
    -- single GUID is converted as an empty array, which makes the game treat
    -- the message as global system chat. Repeating that call for N players
    -- therefore broadcasts the same line N times. A Lua array of GUID structs
    -- is converted by UE4SS to the required TArray in one UFunction call.
    local ok, result = safe_call(
        utility, "SendSystemToPlayerChat", world, chat_text, receiver_uids
    )
    if not ok then
        log("participant message failed: " .. tostring(result))
        return false
    end
    return true
end

local function announce(message, recipients)
    local text = tostring(config.MessagePrefix or "[BossDPS]") .. " " .. tostring(message)
    if send_participant_message(text, recipients) then
        log(string.format("participant message recipients=%d: %s", #(recipients or {}), text))
    end
end

local function format_integer(value)
    local number = math.floor(math.max(0, to_number(value)) + 0.5)
    local text = tostring(number)
    local sign, digits = string.match(text, "^([%-]?)(%d+)$")
    if digits == nil then
        return text
    end
    local formatted = string.reverse(digits):gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (sign or "") .. formatted
end

local function ranked_contributors(session)
    local rows = {}
    for _, entry in pairs(session.contributors) do
        rows[#rows + 1] = entry
    end
    table.sort(rows, function(a, b)
        if a.damage == b.damage then
            if a.hits ~= b.hits then
                return a.hits > b.hits
            end
            return a.name < b.name
        end
        return a.damage > b.damage
    end)
    return rows
end

local function ranked_damage_entries(entries)
    local rows = {}
    for _, entry in pairs(entries or {}) do
        if entry.damage > 0 then
            rows[#rows + 1] = entry
        end
    end
    table.sort(rows, function(a, b)
        if a.damage == b.damage then
            if (a.hits or 0) ~= (b.hits or 0) then
                return (a.hits or 0) > (b.hits or 0)
            end
            return tostring(a.name) < tostring(b.name)
        end
        return a.damage > b.damage
    end)
    return rows
end

local function diagnostic_fields_text(fields)
    local keys = {}
    for key in pairs(fields or {}) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        local value = sanitize_utf8(tostring(fields[key]))
        value = string.gsub(value, "[|\r\n]", " ")
        parts[#parts + 1] = key .. "=" .. truncate_utf8(value, 64)
    end
    return #parts > 0 and table.concat(parts, ",") or "none"
end

local function same_diagnostic_object(left, right)
    if left.address ~= "" and right.address ~= "" then
        return left.address == right.address
    end
    return left.full_name ~= "" and left.full_name == right.full_name
end

local function diagnostic_actor_key(actor)
    return actor_address(actor) or actor_full_name(actor)
end

local function captured_value_identity(value)
    if value == nil then return nil end
    local ok, address = pcall(function() return value:GetAddress() end)
    address = ok and to_number(address) or 0
    if address > 0 then return "addr:" .. tostring(address) end
    local text = tostring(value)
    if text == "" or text == "nil" then return nil end
    return "ref:" .. text
end

local function object_instance_identity(value)
    local identity = captured_value_identity(value)
    if identity == nil then return nil end
    local full_name = actor_full_name(value)
    if full_name == "" then return identity end
    return identity .. "|" .. full_name
end

local function waza_name_from_id(waza_id)
    waza_id = math.floor(to_number(waza_id))
    if waza_id <= 0 then
        return nil
    end
    if cached_waza_enum == nil then
        local found, enum_object = pcall(StaticFindObject, "/Script/Pal.EPalWazaID")
        cached_waza_enum = found and is_valid(enum_object) and enum_object or false
    end
    if cached_waza_enum ~= false then
        local resolved, enum_name = safe_call(cached_waza_enum, "GetNameByValue", waza_id)
        if resolved then
            local name = text_value(enum_name)
            name = string.gsub(name, "^.*::", "")
            name = string.gsub(name, "^:+", "")
            if name ~= "" and name ~= "None" then
                return name
            end
        end
    end
    return "WAZA_ID_" .. tostring(waza_id)
end

local function out_parameter_value(container, names)
    if container == nil then
        return nil
    end
    for _, name in ipairs(names) do
        local ok, value = safe_property(container, name)
        if ok and value ~= nil then
            return value
        end
    end
    return nil
end

local function get_pal_ui_utility()
    if cached_pal_ui_utility ~= nil then
        return cached_pal_ui_utility ~= false and cached_pal_ui_utility or nil
    end
    local ok, utility = pcall(StaticFindObject, "/Script/Pal.Default__PalUIUtility")
    if ok and is_valid(utility) then
        cached_pal_ui_utility = utility
        return utility
    end
    cached_pal_ui_utility = false
    return nil
end

local function get_waza_database()
    if cached_waza_database ~= nil then
        return cached_waza_database ~= false and cached_waza_database or nil
    end
    local utility = get_pal_utility()
    local world = find_world_context()
    local ok, database = safe_call(utility, "GetWazaDatabase", world)
    if ok and is_valid(database) then
        cached_waza_database = database
        return database
    end
    cached_waza_database = false
    return nil
end

local function resolve_waza_metadata(waza_id, internal_name)
    waza_id = math.floor(to_number(waza_id))
    local cache_key = waza_id > 0 and tostring(waza_id) or tostring(internal_name or "")
    local cached = cached_waza_metadata[cache_key]
    if cached ~= nil then
        return cached
    end

    local code = waza_id > 0 and waza_name_from_id(waza_id) or tostring(internal_name or "")
    local localized_name = ""
    local panel_cool_time = nil
    if waza_id > 0 then
        local ui_utility = get_pal_ui_utility()
        local world = find_world_context()
        if ui_utility ~= nil and world ~= nil then
            local out_name = {}
            safe_call(ui_utility, "GetWazaName", world, waza_id, out_name)
            localized_name = text_value(out_parameter_value(out_name, {
                "outName", "OutName", "OutText", "ReturnValue",
            }))
        end

        local database = get_waza_database()
        if database ~= nil then
            local out_data = {}
            safe_call(database, "FindWazaForBP", waza_id, out_data)
            local raw = out_parameter_value(out_data, { "OutData", "outData", "ReturnValue" })
                or out_data
            panel_cool_time = finite_positive_number(
                out_parameter_value(raw, { "CoolTime", "coolTime" })
            )
        end
    end

    local fallback = config.SkillMetadataFallbacks
        and config.SkillMetadataFallbacks[code]
        or nil
    if localized_name == "" and fallback ~= nil then
        localized_name = localized_override(fallback.Name or fallback.name)
    end
    if panel_cool_time == nil and fallback ~= nil then
        panel_cool_time = finite_positive_number(
            fallback.PanelCoolTime or fallback.panel_cool_time
        )
    end
    cached = {
        id = waza_id > 0 and waza_id or nil,
        code = code,
        localized_name = localized_name,
        panel_cool_time = panel_cool_time,
    }
    cached_waza_metadata[cache_key] = cached
    return cached
end

local function for_each_unreal_array(array, callback)
    if array == nil then return false end
    if type(array) == "table" then
        for index, value in ipairs(array) do
            callback(index - 1, value)
        end
        return true
    end
    local ok = pcall(function()
        array:ForEach(function(index, element)
            callback(index, unwrap(element))
        end)
    end)
    return ok
end

-- Read the Pal's actual three equipped active-skill slots. Palworld keeps
-- default/filler attacks outside EquipWaza, so this is a stronger distinction
-- than assuming that a particular internal action name is always a basic hit.
local function refresh_equipped_waza(source, source_actor, force)
    if source == nil or source.kind ~= "pal" or not is_valid(source_actor) then
        return false
    end
    local now = os.time()
    -- The three equipped slots can change mid-test while the player swaps
    -- skills between engagements. The list must be re-read on every action
    -- begin and at least once per TTL; otherwise a newly equipped skill is
    -- wrongly labelled "basic" until the game restarts.
    if force ~= true and (source.equipped_waza_count or 0) > 0
        and (source.equipped_waza_refresh_at or 0) > now then
        return true
    end
    if source.equipped_waza_attempt_at == now then return false end
    source.equipped_waza_attempt_at = now

    local component_ok, component = safe_property(source_actor, "CharacterParameterComponent")
    if not component_ok or not is_valid(component) then
        local call_ok, found = safe_call(source_actor, "GetCharacterParameterComponent")
        component = call_ok and found or nil
    end
    if not is_valid(component) then return false end
    local individual_ok, individual = safe_property(component, "IndividualParameter")
    if not individual_ok or individual == nil then return false end
    local save_ok, save_parameter = safe_property(individual, "SaveParameter")
    if not save_ok or save_parameter == nil then return false end
    local equip_ok, equip_waza = safe_property(save_parameter, "EquipWaza")
    if not equip_ok or equip_waza == nil then return false end

    local ids = {}
    local codes = {}
    local ids_by_code = {}
    local code_list = {}
    local count = 0
    local iterated = for_each_unreal_array(equip_waza, function(_, raw_value)
        local numeric = math.floor(to_number(unwrap(raw_value)))
        if numeric > 0 and ids[numeric] ~= true then
            ids[numeric] = true
            local metadata = resolve_waza_metadata(numeric)
            local code = canonical_skill_name(metadata and metadata.code or "")
            if code ~= "" then
                codes[code] = true
                ids_by_code[code] = numeric
                code_list[#code_list + 1] = code
            end
            count = count + 1
        end
    end)
    if not iterated or count == 0 then return false end
    table.sort(code_list)
    local equipped_fingerprint = table.concat(code_list, ",")
    if source.equipped_waza_fingerprint ~= nil
        and source.equipped_waza_fingerprint ~= equipped_fingerprint then
        -- Only an observed loadout change invalidates learned mappings. Action
        -- begin fires for every cast, so clearing these tables there discarded
        -- accumulated damage and made the HUD row sum smaller than total damage.
        source.skill_signatures = nil
        source.known_equipped_signatures = nil
    end
    source.equipped_waza_fingerprint = equipped_fingerprint
    source.equipped_waza_ids = ids
    source.equipped_waza_codes = codes
    source.equipped_waza_ids_by_code = ids_by_code
    source.equipped_waza_count = count
    -- Equipped metadata is diagnostic context only. It may describe which
    -- skills could have produced a signature, but cannot identify this hit.
    source.known_equipped_signatures = {}
    for code in pairs(codes) do
        local fallback = config.SkillMetadataFallbacks
            and config.SkillMetadataFallbacks[code]
            or nil
        local base_power = fallback and finite_positive_number(fallback.BasePower) or nil
        local element = fallback and math.floor(to_number(fallback.AttackElementType)) or nil
        if base_power ~= nil and element ~= nil then
            local signature = string.format(
                "bp:%s|element:%s", tostring(base_power), tostring(element))
            local candidates = source.known_equipped_signatures[signature]
            if candidates == nil then
                candidates = {}
                source.known_equipped_signatures[signature] = candidates
            end
            candidates[code] = true
        end
    end
    local refresh_seconds = math.max(
        1,
        math.floor(to_number(config.EquipWazaRefreshSeconds) or 5)
    )
    source.equipped_waza_refresh_at = now + refresh_seconds
    log(string.format(
        "equipped-waza source=%s count=%d codes=%s",
        source.name,
        count,
        table.concat(code_list, ",")
    ))
    return true
end

local function skill_candidate_category(source, candidate)
    if source.kind ~= "pal" then return "skill" end
    local code = canonical_skill_name(candidate.name)
    if (source.equipped_waza_count or 0) > 0 then
        local waza_id = math.floor(to_number(candidate.waza_id))
        if waza_id > 0 then
            return source.equipped_waza_ids[waza_id] == true and "skill" or "basic"
        end
        if code ~= "" and source.equipped_waza_codes[code] == true then
            return "skill"
        end
        if code ~= "" and not string.find(code, "^UNKNOWN_")
            and not string.find(code, "^UNRESOLVED_") then
            return "basic"
        end
        return "other"
    end
    -- Compatibility fallback for builds where EquipWaza is temporarily not
    -- readable. Dark Shot is Palworld's documented Dark-element default hit.
    if code == "GravityShot" then return "basic" end
    if candidate.unresolved_signature ~= nil or string.find(code, "^UNKNOWN_")
        or string.find(code, "^UNRESOLVED_") then
        return "other"
    end
    return "skill"
end

local function waza_pair_key(attacker, defender)
    local attacker_key = diagnostic_actor_key(attacker)
    local defender_key = diagnostic_actor_key(defender)
    if attacker_key == nil or attacker_key == ""
        or defender_key == nil or defender_key == "" then
        return nil, attacker_key
    end
    return tostring(attacker_key) .. "->" .. tostring(defender_key), attacker_key
end

local function trace_skill_event(message)
    local maximum = math.max(0,
        math.floor(to_number(config.SkillDiagnosticMaxTraceEvents)))
    if maximum <= 0 or metrics.trace_events >= maximum then
        return
    end
    metrics.trace_events = metrics.trace_events + 1
    log("skill-trace " .. tostring(message))
end

source_chain = runtime_source_chain.new({
    enabled = function()
        return config.EnableDPSRecording ~= false
            and config.EnableSkillDiagnostics == true
    end,
    safe_call = safe_call,
    safe_property = safe_property,
    is_valid = is_valid,
    unwrap = unwrap,
    to_number = to_number,
    text_value = text_value,
    canonical = function(value) return canonical_skill_name(value) end,
    resolve_waza = resolve_waza_metadata,
    resolve_effect_asset = skill_effect_attribution.resolve,
    object_info = diagnostic_object_info,
    object_identity = object_instance_identity,
    value_identity = captured_value_identity,
    actor_key = diagnostic_actor_key,
    full_name = actor_full_name,
    clock = os.clock,
    action_records = function() return action_records end,
    register_hook = function(...) return RegisterHook(...) end,
    register_custom_event = function(...) return RegisterCustomEvent(...) end,
    trace = trace_skill_event,
    on_error = function(label, err)
        metrics.errors = metrics.errors + 1
        log(tostring(label) .. " error: " .. tostring(err))
    end,
    on_attack_hook_registered = function(full_name)
        hooks.effect_attack_count = hooks.effect_attack_count + 1
        trace_skill_event("effect-attack-hook function=" .. tostring(full_name))
    end,
    defer = function(callback)
        local ok, err = pcall(function() ExecuteInGameThread(callback) end)
        if not ok then
            metrics.errors = metrics.errors + 1
            log("effect attack cleanup scheduling failed: " .. tostring(err))
        end
    end,
})

local function prune_waza_markers(now)
    local ttl = math.max(1, tonumber(config.SkillMarkerTTLSeconds) or 30)
    local maximum = math.max(64, math.floor(to_number(config.SkillMarkerMaxEntries)))
    local function prune(entries)
        local rows = {}
        for key, bucket in pairs(entries) do
            local kept = {}
            for _, marker in ipairs(bucket) do
                if now - marker.at >= 0 and now - marker.at <= ttl then
                    kept[#kept + 1] = marker
                end
            end
            if #kept == 0 then
                entries[key] = nil
            else
                entries[key] = kept
                rows[#rows + 1] = { key = key, at = kept[#kept].at }
            end
        end
        -- The configured maximum limits tracked actor/pair buckets. Every
        -- bucket is independently bounded below, so memory remains bounded.
        if #rows > maximum then
            table.sort(rows, function(a, b) return a.at < b.at end)
            for index = 1, #rows - maximum do
                entries[rows[index].key] = nil
            end
        end
    end
    prune(recent_waza_by_pair)
    prune(recent_waza_by_attacker)
end

local function append_waza_marker(entries, key, marker)
    if key == nil or key == "" then return end
    local bucket = entries[key]
    if bucket == nil then
        bucket = {}
        entries[key] = bucket
    end
    bucket[#bucket + 1] = marker
    local maximum = math.max(4, math.floor(to_number(config.SkillMarkerMaxPerPair)))
    while #bucket > maximum do
        table.remove(bucket, 1)
    end
end

local function damage_marker_signature(fields)
    fields = fields or {}
    local power = fields["info.BasePower"] or fields["result.BasePower"]
    local element = fields["info.AttackElementType"] or fields["result.AttackElementType"]
    if power == nil and element == nil then return nil end
    return tostring(power or "?") .. "|" .. tostring(element or "?")
end

local function select_waza_marker(bucket, event)
    if bucket == nil or #bucket == 0 then return nil, false end
    local now = os.time()
    local now_clock = os.clock()
    local ttl = math.max(1, tonumber(config.SkillMarkerTTLSeconds) or 30)
    local signature = damage_marker_signature(event.diagnostic_fields)
    local candidates = {}
    for index = #bucket, 1, -1 do
        local marker = bucket[index]
        local age = now - marker.at
        if age >= 0 and age <= ttl
            and (signature == nil or marker.signature == nil
                or marker.signature == signature) then
            candidates[#candidates + 1] = marker
        elseif age > ttl then
            break
        end
    end
    if #candidates == 0 then return nil, false end
    local newest = candidates[1]
    local conflict_seconds = math.max(0,
        tonumber(config.SkillMarkerConflictSeconds) or 0.35)
    for index = 2, #candidates do
        local other = candidates[index]
        if newest.id ~= other.id
            and math.abs(newest.at - other.at) <= 1
            and math.abs(newest.clock - other.clock) <= conflict_seconds then
            return nil, true
        end
    end
    return newest, false
end

local function process_waza_marker(event)
    if not is_valid(event.attacker) then
        return
    end
    local waza_id = math.floor(to_number(event.waza_id))
    if waza_id <= 0 then
        return
    end
    local pair_key, attacker_key = waza_pair_key(event.attacker, event.defender)
    if attacker_key == nil or attacker_key == "" then
        return
    end
    local metadata = resolve_waza_metadata(waza_id)
    local marker = {
        id = waza_id,
        name = metadata.code,
        localized_name = metadata.localized_name,
        panel_cool_time = metadata.panel_cool_time,
        at = event.captured_at or os.time(),
        clock = event.captured_clock or os.clock(),
        signature = event.signature,
        return_summary = event.return_summary,
        matches = 0,
        damage_info_key = event.damage_info_key,
    }
    if marker.damage_info_key ~= nil then
        marker.cast_id = source_chain:link_damage_info(
            attacker_key, metadata.code, marker.damage_info_key)
    end
    append_waza_marker(recent_waza_by_pair, pair_key, marker)
    append_waza_marker(recent_waza_by_attacker, attacker_key, marker)
    metrics.waza_markers = metrics.waza_markers + 1
    trace_skill_event(string.format(
        "waza-marker seq=%d pair=%s id=%d code=%s signature=%s return=%s damage_info=%s",
        metrics.waza_markers, tostring(pair_key or attacker_key), waza_id,
        tostring(metadata.code), tostring(event.signature or "none"),
        tostring(event.return_summary or "none"),
        marker.damage_info_key ~= nil and "captured" or "none"
    ))
    if metrics.waza_markers % 64 == 1 then
        prune_waza_markers(marker.at)
    end
end

local function select_damage_info_marker(event)
    local key = tostring(event.damage_info_key or "")
    if key == "" then return nil end
    local attacker_key = diagnostic_actor_key(event.attacker)
    if attacker_key == nil or attacker_key == "" then return nil end
    local bucket = recent_waza_by_attacker[attacker_key] or {}
    local now = os.time()
    local ttl = math.max(1, tonumber(config.SkillMarkerTTLSeconds) or 30)
    for index = #bucket, 1, -1 do
        local marker = bucket[index]
        local age = now - marker.at
        if age > ttl then break end
        if marker.damage_info_key == key then return marker end
    end
    return nil
end

local function apply_waza_marker(event, marker, source_label)
    if marker == nil then return false end
    event.diagnostic_fields["waza.ID"] = marker.id
    event.diagnostic_fields["waza.Name"] = marker.name
    event.diagnostic_fields["waza.LocalizedName"] = marker.localized_name
    event.diagnostic_fields["waza.PanelCoolTime"] = marker.panel_cool_time
    event.diagnostic_fields["attribution.Source"] = source_label
    metrics.waza_matches = metrics.waza_matches + 1
    marker.matches = (marker.matches or 0) + 1
    return true
end

-- Pair/attacker marker queues remain trace-only because two simultaneous
-- skills can emit indistinguishable markers. Bounded loadout/action inference
-- below is deliberately separate and explicitly labelled as inferred.
local function apply_inferred_waza(event, marker, source_label)
    if marker == nil then return false end
    event.diagnostic_fields["inference.WazaID"] = marker.id
    event.diagnostic_fields["inference.WazaName"] = marker.name
    event.diagnostic_fields["inference.WazaLocalizedName"] = marker.localized_name
    event.diagnostic_fields["inference.WazaPanelCoolTime"] = marker.panel_cool_time
    event.diagnostic_fields["inference.Source"] = source_label
    marker.matches = (marker.matches or 0) + 1
    return true
end

local function recent_action_evidence(event, source_actor_key)
    if source_actor_key == nil then
        return nil, false
    end
    local now = game_time_seconds()
    local signature = attack_signature(event.diagnostic_fields)
    local binding_key = signature ~= nil and (source_actor_key .. "|" .. signature) or nil
    local binding = binding_key ~= nil and delayed_effect_bindings[binding_key] or nil
    local hit_gap = math.max(0.5, tonumber(config.SkillEffectHitGapSeconds) or 3)
    local effect_lifetime = math.max(hit_gap, tonumber(config.SkillEffectMaxLifetimeSeconds) or 45)
    if binding ~= nil
        and now - binding.last_hit_at >= 0 and now - binding.last_hit_at <= hit_gap
        and now - binding.started_at >= 0 and now - binding.started_at <= effect_lifetime then
        binding.last_hit_at = now
        return binding.record, false
    end

    local recent = recent_actions_by_actor[source_actor_key] or {}
    local post_hit_seconds = math.max(1, tonumber(config.SkillActionPostHitSeconds) or 10)
    local conflict_seconds = math.max(0, tonumber(config.SkillActionConflictSeconds) or 1.25)
    local nearest = nil
    local conflicting = false
    for index = #recent, 1, -1 do
        local candidate = recent[index]
        local ended_at = tonumber(candidate.ended_at)
        local age = ended_at ~= nil and (now - ended_at) or math.huge
        if age >= 0 and age <= post_hit_seconds then
            if nearest == nil then
                nearest = candidate
            elseif candidate.code ~= nearest.code
                and math.abs((tonumber(nearest.ended_at) or now) - ended_at) <= conflict_seconds then
                conflicting = true
                break
            end
        elseif age > post_hit_seconds then
            break
        end
    end
    if conflicting then
        return nil, true
    end
    if nearest ~= nil and binding_key ~= nil then
        delayed_effect_bindings[binding_key] = {
            record = nearest,
            started_at = now,
            last_hit_at = now,
        }
    end
    return nearest, false
end

local function apply_action_record(event, record, source_label)
    if record == nil or record.waza_id == nil then
        return false
    end
    event.diagnostic_fields["inference.WazaID"] = record.waza_id
    event.diagnostic_fields["inference.WazaName"] = record.code
    event.diagnostic_fields["inference.WazaLocalizedName"] = record.localized_name
    event.diagnostic_fields["inference.WazaPanelCoolTime"] = record.panel_cool_time
    event.diagnostic_fields["inference.ActionClass"] = record.code
    event.diagnostic_fields["inference.CastKey"] = record.key
    event.diagnostic_fields["inference.Source"] = source_label
    return true
end

local function promote_inferred_waza(event, metadata, waza_id, source_label, cast_key)
    if config.EnableBoundedSkillInference ~= true or metadata == nil then
        return false
    end
    local fields = event.diagnostic_fields or {}
    if fields["waza.ID"] ~= nil or fields["waza.Name"] ~= nil then
        return false
    end
    local code = canonical_skill_name(metadata.code or "")
    if code == "" then return false end
    waza_id = math.floor(to_number(waza_id or metadata.id))
    fields["waza.ID"] = waza_id > 0 and waza_id or nil
    fields["waza.Name"] = code
    fields["waza.LocalizedName"] = metadata.localized_name
    fields["waza.PanelCoolTime"] = metadata.panel_cool_time
    fields["attribution.Source"] = source_label
    fields["attribution.Confidence"] = "inferred"
    fields["inference.WazaID"] = fields["waza.ID"]
    fields["inference.WazaName"] = code
    fields["inference.Source"] = source_label
    if cast_key ~= nil and tostring(cast_key) ~= "" then
        fields["inference.CastKey"] = tostring(cast_key)
        event.cast_key = tostring(cast_key)
    end
    trace_skill_event(string.format(
        "bounded-inference source=%s id=%s code=%s cast=%s",
        tostring(source_label), tostring(fields["waza.ID"] or "none"),
        tostring(code), tostring(event.cast_key or "none")
    ))
    return true
end

local function promote_action_record(event, record, source_label)
    if record == nil or record.waza_id == nil then return false end
    return promote_inferred_waza(
        event,
        resolve_waza_metadata(record.waza_id, record.code),
        record.waza_id,
        source_label,
        record.cast_id or record.key
    )
end

-- A completed equipped cast may still own a delayed shard, explosion or
-- ground field after the Pal has started its filler attack. However, when the
-- final damage signature exactly matches that filler attack, the current
-- action is direct evidence and must win. Without this guard, every 40/Dark
-- GravityShot hit during a fire field was reassigned to the previous fire
-- skill.
local function action_matches_damage_signature(action_metadata, fields)
    if action_metadata == nil or action_metadata.code == nil then
        return false
    end
    local fallback = config.SkillMetadataFallbacks
        and config.SkillMetadataFallbacks[action_metadata.code]
        or nil
    local expected_power = fallback and finite_positive_number(fallback.BasePower) or nil
    local expected_element = fallback
        and math.floor(to_number(fallback.AttackElementType))
        or nil
    if expected_power == nil or expected_element == nil then
        return false
    end
    fields = fields or {}
    local actual_power = finite_positive_number(
        fields["result.BasePower"] or fields["info.BasePower"])
    local actual_element = fields["result.AttackElementType"]
        or fields["info.AttackElementType"]
    actual_element = actual_element ~= nil and math.floor(to_number(actual_element)) or nil
    return actual_power == expected_power and actual_element == expected_element
end

local function apply_unique_equipped_signature(event, source_profile)
    local fields = event.diagnostic_fields or {}
    if fields["waza.ID"] ~= nil or fields["waza.Name"] ~= nil
        or source_profile == nil then
        return false
    end
    local power = finite_positive_number(
        fields["result.BasePower"] or fields["info.BasePower"])
    local element = fields["result.AttackElementType"]
        or fields["info.AttackElementType"]
    element = element ~= nil and math.floor(to_number(element)) or nil
    if power == nil or element == nil then return false end
    local signature = string.format(
        "bp:%s|element:%s", tostring(power), tostring(element))
    local known = source_profile.known_equipped_signatures
        and source_profile.known_equipped_signatures[signature]
        or nil
    local code = nil
    local count = 0
    for candidate_code in pairs(known or {}) do
        code = candidate_code
        count = count + 1
    end
    if count ~= 1 then return false end
    local waza_id = source_profile.equipped_waza_ids_by_code
        and source_profile.equipped_waza_ids_by_code[code]
        or nil
    return promote_inferred_waza(
        event,
        resolve_waza_metadata(waza_id or 0, code),
        waza_id,
        "inferred_unique_equipped_signature",
        nil
    )
end

local function attach_runtime_skill_evidence(event, source_actor, source_kind, source_profile)
    if config.EnableSkillDiagnostics ~= true then
        return
    end
    event.diagnostic_fields = event.diagnostic_fields or {}
    local effect_attack = event.effect_attack
    if effect_attack ~= nil and effect_attack.code ~= nil then
        local metadata = effect_attack.waza_id ~= nil
            and resolve_waza_metadata(effect_attack.waza_id)
            or resolve_waza_metadata(0, effect_attack.code)
        event.diagnostic_fields["waza.ID"] = effect_attack.waza_id
        event.diagnostic_fields["waza.Name"] = metadata.code or effect_attack.code
        event.diagnostic_fields["waza.LocalizedName"] = metadata.localized_name
        event.diagnostic_fields["waza.PanelCoolTime"] = metadata.panel_cool_time
        event.diagnostic_fields["effect.Instance"] = effect_attack.effect_id
        event.diagnostic_fields["attribution.Source"] = effect_attack.cast_id ~= nil
            and "effect_cast_link" or "effect_waza"
        event.cast_key = effect_attack.cast_id
        trace_skill_event(string.format(
            "effect-hit-match token=%s effect=%s cast=%s code=%s",
            tostring(effect_attack.token), tostring(effect_attack.effect_id),
            tostring(effect_attack.cast_id or "none"), tostring(effect_attack.code)
        ))
        return
    end
    local identity_marker = select_damage_info_marker(event)
    if identity_marker ~= nil then
        -- The exact DamageInfo instance produced by MakeDamageInfoByWazaType
        -- is stronger than copied Waza fields, effect assets, current action,
        -- and timing. It also distinguishes simultaneous identical skills.
        apply_waza_marker(event, identity_marker, "waza_damage_info")
        trace_skill_event(string.format(
            "waza-match source=damage_info id=%d code=%s",
            identity_marker.id, tostring(identity_marker.name)
        ))
        return
    end
    -- The final damage event carried a captured DamageInfo identity but no
    -- Waza construction marker matched it. Palworld may copy/wrap the
    -- ReturnValue into another struct; trace the miss so the next on-device
    -- run can verify the chain instead of silently degrading to timing rules.
    if event.damage_info_key ~= nil and event.damage_info_key ~= "" then
        trace_skill_event(string.format(
            "damage-info-unmatched key=%s attacker=%s",
            event.damage_info_key,
            tostring(diagnostic_actor_key(event.attacker) or "none")
        ))
    end
    local causer_info = diagnostic_object_info(event.damage_causer)
    local effect_evidence = skill_effect_attribution.resolve(causer_info)
    local direct_waza_id = 0
    for _, field_name in ipairs({
        "result.WazaID", "result.WazaId", "info.WazaID", "info.WazaId",
    }) do
        direct_waza_id = math.floor(to_number(event.diagnostic_fields[field_name]))
        if direct_waza_id > 0 then break end
    end
    if direct_waza_id > 0 then
        local metadata = resolve_waza_metadata(direct_waza_id)
        event.diagnostic_fields["waza.ID"] = direct_waza_id
        event.diagnostic_fields["waza.Name"] = metadata.code
        event.diagnostic_fields["waza.LocalizedName"] = metadata.localized_name
        event.diagnostic_fields["waza.PanelCoolTime"] = metadata.panel_cool_time
        event.diagnostic_fields["attribution.Source"] = "damage_waza_id"
    end
    if effect_evidence ~= nil then
        event.diagnostic_fields["effect.Asset"] = effect_evidence.matched_token
        event.diagnostic_fields["effect.Phase"] = effect_evidence.phase
        event.diagnostic_fields["effect.Waza"] = effect_evidence.waza
        event.diagnostic_fields["effect.WazaPowerRate"] = effect_evidence.power_rate
        if event.diagnostic_fields["waza.ID"] == nil then
            event.diagnostic_fields["waza.Name"] = effect_evidence.code
            event.diagnostic_fields["waza.LocalizedName"] =
                skill_display_name(effect_evidence.code, "")
            event.diagnostic_fields["attribution.Source"] = "damage_causer_asset"
        end
    end

    -- Native Event v2 is the fail-closed attribution lane. If the collector
    -- could not carry an exact effect/cast/Waza source into this final hit,
    -- never let current-action or recent-action timing relabel it. Sustained
    -- fields routinely land after another move has started, which is exactly
    -- how IceAge/Apocalypse/SandTwister damage used to steal one another.
    if math.floor(to_number(event.api_version)) >= 2 then
        if event.diagnostic_fields["waza.ID"] == nil
            and event.diagnostic_fields["waza.Name"] == nil then
            event.diagnostic_fields["attribution.Source"] = "native_unresolved"
            event.diagnostic_fields["attribution.Confidence"] = "unresolved"
            trace_skill_event(string.format(
                "native-hit-unresolved sequence=%s evidence=%s candidate=%s waza=%s effect=%s",
                tostring(event.sequence or "none"),
                tostring(event.evidence_kind or "none"),
                tostring(event.skill_code or "none"),
                tostring(event.waza_id or "none"),
                tostring(event.effect_id or "none")
            ))
        end
        return
    end
    local pair_key, attacker_key = waza_pair_key(event.attacker, event.defender)
    local marker, marker_conflict = select_waza_marker(
        pair_key ~= nil and recent_waza_by_pair[pair_key] or nil, event)
    if marker == nil and not marker_conflict then
        marker, marker_conflict = select_waza_marker(
            attacker_key ~= nil and recent_waza_by_attacker[attacker_key] or nil, event)
    end
    if event.diagnostic_fields["waza.ID"] == nil
        and event.diagnostic_fields["waza.Name"] == nil
        and marker ~= nil then
        apply_inferred_waza(event, marker, "waza_marker")
    elseif event.diagnostic_fields["waza.ID"] == nil
        and event.diagnostic_fields["waza.Name"] == nil
        and marker_conflict then
        event.diagnostic_fields["inference.Source"] = "waza_marker_conflict"
    end

    -- Two unconsumed Waza construction events for the same attacker/target
    -- are stronger evidence of concurrency than whatever action happens to be
    -- current when the final damage callback runs. Never guess through it.
    if marker_conflict then
        return
    end

    -- A signature verified from game metadata and unique among the Pal's live
    -- three equipped slots is a bounded inference. It may populate a visible
    -- skill bucket, but remains marked inferred and never seeds the exact
    -- signature-learning table. Marker concurrency is checked first so a
    -- signature never guesses through two known simultaneous Waza events.
    apply_unique_equipped_signature(event, source_profile)

    if source_kind ~= "pal" or not is_valid(source_actor) then
        return
    end
    local source_actor_key = diagnostic_actor_key(source_actor)
    event.source_actor_key = source_actor_key
    local recent_record, recent_conflict = recent_action_evidence(event, source_actor_key)
    local component_ok, action_component = safe_property(source_actor, "ActionComponent")
    if not component_ok or not is_valid(action_component) then
        local call_ok, component = safe_call(source_actor, "GetActionComponent")
        action_component = call_ok and component or nil
    end
    local action_ok, action = false, nil
    if is_valid(action_component) then
        action_ok, action = safe_call(action_component, "GetCurrentAction")
    end
    local has_current_action = action_ok and is_valid(action)
    local has_current_skill_action = false
    local current_action_is_equipped = false
    local may_use_recent_action = not has_current_action
    if has_current_action then
        local simple_ok, simple_name = safe_call(action, "GetSimpleName")
        local action_info = diagnostic_object_info(action)
        local action_cast_key = action_instance_key(action)
        local waza_ok, action_waza_id = safe_call(action, "GetWazaID")
        action_waza_id = waza_ok and math.floor(to_number(action_waza_id)) or 0
        local fallback_action_name, ignored_action_kind = action_skill_name(action_info.short_name)
        has_current_skill_action = action_waza_id > 0 or fallback_action_name ~= nil
        may_use_recent_action = ignored_action_kind == "movement"
        if has_current_skill_action then
            if simple_ok and text_value(simple_name) ~= "" then
                event.diagnostic_fields["action.SimpleName"] = text_value(simple_name)
            end
            if action_info.short_name ~= "" then
                event.diagnostic_fields["action.Class"] = action_info.short_name
            end
            -- Current action is timing context only. Simultaneous and delayed
            -- effects make it unsafe as final-hit attribution.
            event.diagnostic_fields["inference.Source"] =
                event.diagnostic_fields["inference.Source"] or "current_action"
        elseif action_info.short_name ~= "" then
            -- Locomotion/animation actions can be current while a rain field,
            -- projectile or delayed explosion lands. They are timing context,
            -- never a damage skill, and must not block completed-cast lookup.
            event.diagnostic_fields["action.IgnoredClass"] = action_info.short_name
        end
        local existing_waza_id = math.floor(to_number(event.diagnostic_fields["waza.ID"]))
        local existing_waza_name = canonical_skill_name(
            event.diagnostic_fields["waza.Name"]
        )
        local action_metadata = action_waza_id > 0
            and resolve_waza_metadata(action_waza_id)
            or nil
        local action_waza_name = canonical_skill_name(
            action_metadata and action_metadata.code or ""
        )
        local equipped_known = source_profile ~= nil
            and (source_profile.equipped_waza_count or 0) > 0
        if equipped_known then
            current_action_is_equipped = (action_waza_id > 0
                    and source_profile.equipped_waza_ids[action_waza_id] == true)
                or (action_waza_name ~= ""
                    and source_profile.equipped_waza_codes[action_waza_name] == true)
        end
        local tracked_action = action_records[action_cast_key]
        local tracked_action_active = tracked_action ~= nil
            and tracked_action.ended_at == nil
            and tracked_action.actor_key == source_actor_key
        if tracked_action ~= nil and tracked_action.ended_at ~= nil then
            -- GetCurrentAction can keep returning the completed UObject. Its
            -- lifecycle record is authoritative for whether it is still live.
            may_use_recent_action = true
        end
        local recent_code = canonical_skill_name(recent_record and recent_record.code or "")
        local recent_differs = recent_record ~= nil and recent_code ~= ""
            and recent_code ~= action_waza_name
        local current_action_matches_damage = action_matches_damage_signature(
            action_metadata, event.diagnostic_fields)
        if existing_waza_id <= 0 and existing_waza_name == ""
            and tracked_action_active then
            -- This is the central practical fallback: the game has confirmed
            -- both the live three-slot loadout and the exact action instance
            -- currently executing. Equipped actions become skills; actions
            -- outside those slots (such as GravityShot) become basic attacks.
            promote_action_record(
                event,
                tracked_action,
                current_action_is_equipped
                    and "inferred_active_equipped_action"
                    or "inferred_active_basic_action"
            )
        elseif existing_waza_id <= 0 and existing_waza_name == ""
            and action_waza_id > 0 and equipped_known
            and recent_record ~= nil and not current_action_is_equipped
            and not current_action_matches_damage then
            -- A filler/basic action may already be current when rain, a falling
            -- projectile or a ground explosion from the just-completed skill
            -- lands. The completed equipped cast is stronger evidence.
            apply_action_record(event, recent_record, "recent_completed_action_over_current_basic")
        elseif existing_waza_id <= 0 and existing_waza_name == ""
            and action_waza_id > 0 and equipped_known
            and recent_differs and current_action_is_equipped then
            event.diagnostic_fields["inference.Source"] = "concurrent_action_conflict"
            event.diagnostic_fields["action.ConflictingClass"] = action_info.short_name
            event.diagnostic_fields["action.Class"] = nil
            event.diagnostic_fields["action.SimpleName"] = nil
        elseif existing_waza_id <= 0 and existing_waza_name == ""
            and recent_conflict then
            event.diagnostic_fields["inference.Source"] = "recent_action_conflict"
            event.diagnostic_fields["action.ConflictingClass"] = action_info.short_name
            event.diagnostic_fields["action.Class"] = nil
            event.diagnostic_fields["action.SimpleName"] = nil
        elseif action_waza_id > 0 and existing_waza_id <= 0
            and existing_waza_name == "" then
            if equipped_known and (current_action_matches_damage or recent_record == nil) then
                promote_inferred_waza(
                    event,
                    action_metadata,
                    action_waza_id,
                    current_action_is_equipped
                        and "inferred_current_equipped_action"
                        or "inferred_current_basic_action",
                    action_cast_key
                )
            else
                event.diagnostic_fields["inference.WazaID"] = action_waza_id
                event.diagnostic_fields["inference.WazaName"] = action_metadata.code
                event.diagnostic_fields["inference.WazaLocalizedName"] = action_metadata.localized_name
                event.diagnostic_fields["inference.WazaPanelCoolTime"] = action_metadata.panel_cool_time
                event.diagnostic_fields["inference.Source"] = "current_action"
                event.diagnostic_fields["inference.CastKey"] = action_cast_key
            end
        elseif has_current_skill_action and (action_waza_id <= 0 or action_waza_id == existing_waza_id
            or (existing_waza_name ~= "" and existing_waza_name == action_waza_name)) then
            event.diagnostic_fields["inference.CastKey"] = action_cast_key
        end
    end
    local unresolved_source = event.diagnostic_fields["inference.Source"]
    if may_use_recent_action
        and unresolved_source ~= "concurrent_action_conflict"
        and unresolved_source ~= "recent_action_conflict"
        and event.diagnostic_fields["waza.ID"] == nil
        and event.diagnostic_fields["waza.Name"] == nil
        and source_actor_key ~= nil then
        if recent_conflict then
            event.diagnostic_fields["inference.Source"] = "recent_action_conflict"
        else
            if not promote_action_record(
                event, recent_record, "inferred_recent_completed_action") then
                apply_action_record(event, recent_record, "recent_completed_action")
            end
        end
    end
end

local function first_diagnostic_field(fields, names)
    for _, name in ipairs(names) do
        if fields[name] ~= nil and tostring(fields[name]) ~= "" then
            return fields[name]
        end
    end
    return nil
end

game_time_seconds = function()
    local world = find_world_context()
    local statics = get_gameplay_statics()
    if world ~= nil and statics ~= nil then
        local ok, value = safe_call(statics, "GetTimeSeconds", world)
        value = ok and finite_positive_number(value) or nil
        if value ~= nil then
            return value
        end
    end
    -- This fallback is only used when the world is not ready. It keeps the
    -- diagnostic usable, while timing coverage in the report makes clear
    -- whether full action lifecycle observations were available.
    return os.clock()
end

canonical_skill_name = function(value)
    local name = tostring(value or "")
    name = string.gsub(name, "^.*::", "")
    name = string.gsub(name, "^:+", "")
    name = string.gsub(name, "^BP_", "")
    name = string.gsub(name, "_C_%d+$", "")
    name = string.gsub(name, "_C$", "")
    -- Palworld's enum and action Blueprint use different spellings here.
    if name == "BlastCanon" then
        name = "BlastCannon"
    end
    return name
end

action_skill_name = function(value)
    local name = canonical_skill_name(value)
    if name == "" or name == "ActionDamage" or name == "Action_Damage" then
        return nil, "generic_damage"
    end
    -- These are Pal AI movement/animation states, not attacks. Treating one as
    -- a skill creates bogus rows such as PalAction_AnimationStepLeft while a
    -- previously cast rain/ground effect is still dealing damage.
    if string.find(name, "^PalAction_Animation") ~= nil
        or string.find(name, "^PalAction_Move") ~= nil
        or string.find(name, "^PalAction_[^_]*Step") ~= nil then
        return nil, "movement"
    end
    name = string.gsub(name, "^Action_?", "")
    return name ~= "" and canonical_skill_name(name) or nil
end

local function action_lifecycle_details(action)
    if not is_valid(action) then
        return nil
    end
    local action_info = diagnostic_object_info(action)
    local key = action_instance_key(action)
    if key == nil or key == "" then
        return nil
    end
    local owner_ok, owner = safe_call(action, "GetActionCharacter")
    local owner_key = owner_ok and is_valid(owner) and diagnostic_actor_key(owner) or nil
    local waza_ok, waza_id = safe_call(action, "GetWazaID")
    waza_id = waza_ok and math.floor(to_number(waza_id)) or 0
    if waza_id <= 0 then
        return nil
    end
    local metadata = resolve_waza_metadata(waza_id, action_info.short_name)
    local code = metadata.code
    if code == nil or code == "" then
        return nil
    end
    return {
        key = tostring(key),
        actor_key = owner_key,
        waza_id = waza_id > 0 and waza_id or nil,
        code = canonical_skill_name(code),
        localized_name = metadata.localized_name,
        panel_cool_time = metadata.panel_cool_time,
    }
end

local function get_target_info(actor, utility)
    local boss_info = get_boss_info(actor, utility)
    if boss_info ~= nil then
        return boss_info
    end
    if tostring(config.TargetScope or "boss") ~= "all"
        or not is_valid(actor) or actor_is_player_owned(actor, utility) then
        return nil
    end

    -- The global hook also sees non-character damage. Open-world mode accepts
    -- only Pal character actors exposing one of Palworld's parameter
    -- components, so buildings and arbitrary destructibles never become tests.
    local character_ok, character_component = safe_property(actor, "CharacterParameterComponent")
    local static_ok, static_component = safe_property(actor, "StaticCharacterParameterComponent")
    if not ((character_ok and is_valid(character_component))
        or (static_ok and is_valid(static_component))) then
        return nil
    end
    local full_name = actor_full_name(actor)
    if full_name == "" then return nil end
    local short_name = actor_short_name(actor)
    return {
        key = full_name,
        address = actor_address(actor),
        name = tostring(boss_display_name(actor, utility, short_name)),
        is_boss = false,
    }
end

local function prune_action_records()
    local maximum = math.max(128, math.floor(to_number(config.SkillActionMaxEntries)))
    while #action_record_order > maximum do
        local oldest = table.remove(action_record_order, 1)
        if action_records[oldest.key] == oldest.record then
            action_records[oldest.key] = nil
        end
    end
end

-- A fresh action begin asks for a new EquipWaza read. It is not evidence that
-- the loadout changed: it fires for every ordinary cast. Learned mappings and
-- accumulated candidates are preserved here; refresh_equipped_waza invalidates
-- mappings only after observing a genuinely different three-slot fingerprint.
local function invalidate_equipped_waza(actor_key)
    if actor_key == nil then return end
    for _, session in pairs(sessions) do
        for _, source in pairs(session.diagnostic_sources or {}) do
            if source.kind == "pal" and source.runtime_actor_keys ~= nil
                and source.runtime_actor_keys[actor_key] == true then
                source.equipped_waza_refresh_at = 0
                -- The attempt guard is second-granularity. A cast that starts
                -- and lands within the same second must still re-read after a
                -- swap; otherwise the fresh list waits a full second.
                source.equipped_waza_attempt_at = nil
            end
        end
    end
end

local function process_action_lifecycle_event(event)
    local details = action_lifecycle_details(event.action)
    if details == nil then
        return
    end
    local now = game_time_seconds()
    local record = action_records[details.key]
    if event.kind == "action_begin" or record == nil then
        record = {
            key = details.key,
            actor_key = details.actor_key,
            waza_id = details.waza_id,
            code = details.code,
            localized_name = details.localized_name,
            panel_cool_time = details.panel_cool_time,
            started_at = event.kind == "action_begin" and now or nil,
            ended_at = nil,
        }
        action_records[details.key] = record
        action_record_order[#action_record_order + 1] = { key = details.key, record = record }
        prune_action_records()
    else
        record.actor_key = record.actor_key or details.actor_key
        record.waza_id = record.waza_id or details.waza_id
        record.code = record.code or details.code
        record.localized_name = (record.localized_name ~= nil and record.localized_name ~= "")
            and record.localized_name or details.localized_name
        record.panel_cool_time = record.panel_cool_time or details.panel_cool_time
    end
    if event.kind == "action_begin" then
        record.started_at = now
        record.cast_id = source_chain:on_cast_begin(
            record, event.captured_clock or now)
        metrics.action_begins = metrics.action_begins + 1
        invalidate_equipped_waza(record.actor_key)
        trace_skill_event(string.format(
            "action-begin key=%s cast=%s actor=%s id=%s code=%s game=%.3f",
            tostring(record.key), tostring(record.cast_id), tostring(record.actor_key),
            tostring(record.waza_id), tostring(record.code), now
        ))
    else
        record.ended_at = now
        if record.actor_key ~= nil then
            local recent = recent_actions_by_actor[record.actor_key]
            if recent == nil then
                recent = {}
                recent_actions_by_actor[record.actor_key] = recent
            end
            recent[#recent + 1] = record
            while #recent > 16 do
                table.remove(recent, 1)
            end
        end
        metrics.action_ends = metrics.action_ends + 1
        trace_skill_event(string.format(
            "action-end key=%s cast=%s actor=%s id=%s code=%s game=%.3f",
            tostring(record.key), tostring(record.cast_id), tostring(record.actor_key),
            tostring(record.waza_id), tostring(record.code), now
        ))
    end
end

attack_signature = function(diagnostic_fields)
    local base_power = first_diagnostic_field(diagnostic_fields, {
        "result.BasePower", "info.BasePower",
    })
    if base_power == nil then
        return nil
    end
    local element = first_diagnostic_field(diagnostic_fields, {
        "result.AttackElementType", "info.AttackElementType",
    })
    return string.format("bp:%s|element:%s", tostring(base_power), tostring(element or "unknown"))
end

local function skill_candidate_from_event(event, source_actor, source_kind)
    local causer = diagnostic_object_info(event and event.damage_causer or nil)
    local source = diagnostic_object_info(source_actor)
    local diagnostic_fields = event and event.diagnostic_fields or {}
    local fields = diagnostic_fields_text(diagnostic_fields)
    local signature = attack_signature(diagnostic_fields)
    local label
    local identity
    local concrete = false

    local waza_name = first_diagnostic_field(diagnostic_fields, { "waza.Name" })
    local waza_id = first_diagnostic_field(diagnostic_fields, { "waza.ID" })
    local localized_name = first_diagnostic_field(diagnostic_fields, { "waza.LocalizedName" })
    local panel_cool_time = first_diagnostic_field(diagnostic_fields, { "waza.PanelCoolTime" })
    local explicit_skill = first_diagnostic_field(diagnostic_fields, {
        "result.SkillName", "info.SkillName",
        "result.SkillID", "info.SkillID",
        "result.SkillId", "info.SkillId",
        "result.AttackSkillID", "info.AttackSkillID",
        "result.AttackSkillId", "info.AttackSkillId",
    })
    local action_name = action_skill_name(first_diagnostic_field(diagnostic_fields, {
        "action.Class", "action.SimpleName",
    }))

    if waza_name ~= nil or waza_id ~= nil then
        label = canonical_skill_name(waza_name or ("WAZA_ID_" .. tostring(waza_id)))
        identity = "skill:" .. label
        concrete = true
    elseif explicit_skill ~= nil then
        label = canonical_skill_name(explicit_skill)
        identity = "skill:" .. label
        concrete = true
    else
        local base_power = first_diagnostic_field(diagnostic_fields, {
            "result.BasePower", "info.BasePower",
        })
        local element = first_diagnostic_field(diagnostic_fields, {
            "result.AttackElementType", "info.AttackElementType",
        })
        label = source_kind == "player"
            and (causer.short_name ~= "" and ("UNKNOWN_PLAYER_WEAPON_" .. causer.short_name)
                or "UNKNOWN_PLAYER_WEAPON")
            or (base_power ~= nil
                and string.format("UNRESOLVED_PAL_ATTACK_BP_%s_ELEMENT_%s", tostring(base_power), tostring(element or "unknown"))
                or "UNKNOWN_NO_DAMAGE_CAUSER")
        identity = label
    end

    return {
        -- The evidence text deliberately stays out of the key. It contains
        -- per-cast UObject instance numbers and variable hit metadata; using
        -- it as identity split every repeated cast into a different skill.
        key = tostring(identity),
        name = tostring(label),
        localized_name = text_value(localized_name),
        panel_cool_time = finite_positive_number(panel_cool_time),
        waza_id = math.floor(to_number(waza_id)) > 0 and math.floor(to_number(waza_id)) or nil,
        cast_key = concrete and event and event.cast_key or nil,
        observed_at = event and event.observed_at or nil,
        fields = fields,
        signature = signature,
        concrete = concrete,
        attribution_source = tostring(diagnostic_fields["attribution.Source"] or ""),
        confidence = tostring(diagnostic_fields["attribution.Confidence"]
            or (concrete and "exact" or "unresolved")),
        unresolved_signature = not concrete and signature or nil,
        causer_full_name = causer.full_name ~= "" and causer.full_name or "none",
        causer_class_name = causer.class_name ~= "" and causer.class_name or "none",
        source_full_name = source.full_name ~= "" and source.full_name or "none",
    }
end

-- Only direct Waza, exact DamageInfo identity, and effect-asset evidence may
-- build the per-Pal signature table. "Most recently completed cast" and other
-- timing guesses are display-only: letting them seed a signature lets one
-- BasePower+element map to several skills and poisons reconciliation.
local reliable_attribution_sources = {
    ["waza_damage_info"] = true,
    ["damage_waza_id"] = true,
    ["damage_causer_asset"] = true,
    ["damage_info_cast_link"] = true,
    ["effect_cast_link"] = true,
    ["effect_waza"] = true,
}

local function reliable_attribution(fields)
    return reliable_attribution_sources[tostring(
        (fields or {})["attribution.Source"]
    )] == true
end

local function record_skill_candidate(session, source, event, source_actor, damage, hit_count)
    if config.EnableSkillDiagnostics ~= true or source == nil then
        return
    end
    source.skill_candidates = source.skill_candidates or {}
    local evidence = skill_candidate_from_event(event, source_actor, source.kind)
    if evidence.concrete and evidence.signature ~= nil
        and reliable_attribution(event.diagnostic_fields or {}) then
        source.skill_signatures = source.skill_signatures or {}
        local signature_candidates = source.skill_signatures[evidence.signature]
        if signature_candidates == nil then
            signature_candidates = {}
            source.skill_signatures[evidence.signature] = signature_candidates
        end
        signature_candidates[evidence.key] = true
    end
    local candidate = source.skill_candidates[evidence.key]
    if candidate == nil then
        candidate = {
            name = evidence.name,
            localized_name = evidence.localized_name,
            panel_cool_time = evidence.panel_cool_time,
            waza_id = evidence.waza_id,
            evidence_key = evidence.key,
            fields = evidence.fields,
            causer_full_name = evidence.causer_full_name,
            causer_class_name = evidence.causer_class_name,
            source_full_name = evidence.source_full_name,
            unresolved_signature = evidence.unresolved_signature,
            confidence = evidence.confidence,
            attribution_sources = {},
            exact_damage = 0,
            inferred_damage = 0,
            damage = 0,
            hits = 0,
            samples = 0,
            casts = {},
        }
        source.skill_candidates[evidence.key] = candidate
        session.skill_candidate_count = (session.skill_candidate_count or 0) + 1
        metrics.skill_candidates = metrics.skill_candidates + 1
    end

    candidate.damage = candidate.damage + damage
    candidate.hits = candidate.hits + hit_count
    if evidence.attribution_source ~= "" then
        candidate.attribution_sources[evidence.attribution_source] = true
    end
    if evidence.confidence == "inferred" then
        candidate.inferred_damage = candidate.inferred_damage + damage
    elseif evidence.concrete then
        candidate.exact_damage = candidate.exact_damage + damage
        candidate.confidence = "exact"
    end
    if (candidate.localized_name == nil or candidate.localized_name == "")
        and evidence.localized_name ~= "" then
        candidate.localized_name = evidence.localized_name
    end
    candidate.panel_cool_time = candidate.panel_cool_time or evidence.panel_cool_time
    candidate.waza_id = candidate.waza_id or evidence.waza_id
    if evidence.cast_key ~= nil and tostring(evidence.cast_key) ~= "" then
        local cast_key = tostring(evidence.cast_key)
        local cast = candidate.casts[cast_key]
        if cast == nil then
            cast = {
                key = cast_key,
                damage = 0,
                hits = 0,
                first_hit_at = evidence.observed_at,
                last_hit_at = evidence.observed_at,
            }
            candidate.casts[cast_key] = cast
        end
        cast.damage = cast.damage + damage
        cast.hits = cast.hits + hit_count
        if evidence.observed_at ~= nil then
            cast.first_hit_at = cast.first_hit_at == nil
                and evidence.observed_at
                or math.min(cast.first_hit_at, evidence.observed_at)
            cast.last_hit_at = cast.last_hit_at == nil
                and evidence.observed_at
                or math.max(cast.last_hit_at, evidence.observed_at)
        end
    end
    local sample_limit = math.max(
        0,
        math.floor(to_number(config.SkillDiagnosticMaxSamplesPerCandidate))
    )
    if candidate.samples < sample_limit then
        candidate.samples = candidate.samples + 1
        metrics.skill_samples = metrics.skill_samples + 1
        log(string.format(
            "damage-sample boss=%s source_kind=%s source=%s candidate=%s damage=%s hits=%d causer=%s class=%s fields=%s actor=%s",
            session.name,
            tostring(source.kind),
            source.name,
            candidate.name,
            format_integer(damage),
            hit_count,
            candidate.causer_full_name,
            candidate.causer_class_name,
            candidate.fields,
            candidate.source_full_name
        ))
    end
end

-- Live and final output use the same raw buckets. Weak evidence must not become
-- authoritative merely because only one known skill shares the signature.
local function snapshot_skill_candidates(source)
    return source.skill_candidates or {}
end

local function session_recipients(session)
    local recipients = {}
    for _, entry in pairs(session.contributors) do
        local uid = copy_guid(entry.uid)
        if uid ~= nil then
            recipients[#recipients + 1] = uid
        end
    end
    if config.LocalOnlyMessages == true then
        local local_uid = local_player_uid()
        local local_key = guid_key(local_uid)
        if local_key ~= nil and session.contributors[local_key] ~= nil then
            return { copy_guid(local_uid) }
        end
        -- A true single-player encounter has exactly one participant, so this
        -- fallback preserves local output if GameplayStatics is unavailable.
        -- Listen servers with multiple contributors fail closed instead of
        -- sending a client-only report to remote players.
        if local_uid == nil and #recipients == 1 then
            return recipients
        end
        log("local-only report skipped: local participant could not be resolved")
        return {}
    end
    return recipients
end

local run_message_pump

local function schedule_message_pump(delay)
    local ok, err = pcall(function()
        ExecuteInGameThreadWithDelay(delay, run_message_pump)
    end)
    if not ok then
        message_pump_running = false
        metrics.errors = metrics.errors + 1
        log("failed to schedule broadcast pump: " .. tostring(err))
    end
end

run_message_pump = function()
    if message_head > message_tail then
        message_head = 1
        message_tail = 0
        message_pump_running = false
        return
    end

    local message = pending_messages[message_head]
    pending_messages[message_head] = nil
    message_head = message_head + 1
    local sent, send_err = pcall(announce, message.text, message.recipients)
    if not sent then
        metrics.errors = metrics.errors + 1
        log("delayed broadcast error: " .. tostring(send_err))
    end

    if message_head <= message_tail then
        local interval = math.max(0, math.floor(to_number(config.MessageIntervalMilliseconds)))
        schedule_message_pump(interval)
    else
        message_head = 1
        message_tail = 0
        message_pump_running = false
    end
end

local function queue_messages(messages, recipients)
    if #(recipients or {}) == 0 then
        return
    end
    for _, message in ipairs(messages) do
        message_tail = message_tail + 1
        pending_messages[message_tail] = {
            text = tostring(message),
            recipients = recipients,
        }
    end
    if not message_pump_running and message_head <= message_tail then
        message_pump_running = true
        schedule_message_pump(0)
    end
end

local function team_recipients(session, team_key)
    local recipients = {}
    for _, entry in pairs(session.contributors) do
        if entry.team_key == team_key then
            local uid = copy_guid(entry.uid)
            if uid ~= nil then
                recipients[#recipients + 1] = uid
            end
        end
    end
    if config.LocalOnlyMessages == true then
        local local_uid = local_player_uid()
        local local_key = guid_key(local_uid)
        local contributor = local_key ~= nil and session.contributors[local_key] or nil
        if contributor ~= nil and contributor.team_key == team_key then
            return { copy_guid(local_uid) }
        end
        if local_uid == nil and #recipients == 1 then
            return recipients
        end
        return {}
    end
    return recipients
end

local function pal_damage_breakdown_enabled()
    -- EnableTeamDetails was the original, unclear setting name. Keep it as an
    -- alias so existing server configs continue to work without migration.
    return config.EnablePalDamageBreakdown == true or config.EnableTeamDetails == true
end

local function queue_team_details(session, duration)
    local max_rows = math.max(1, math.floor(to_number(config.TeamDetailMaxRows)))
    for team_key, team in pairs(session.teams) do
        local sources = {}
        for _, entry in pairs(session.contributors) do
            if entry.team_key == team_key and entry.direct_damage > 0 then
                sources[#sources + 1] = {
                    name = tr("player_role", { player = entry.name }),
                    damage = entry.direct_damage,
                    hits = entry.direct_hits,
                }
            end
        end
        for _, pal in pairs(session.pal_sources) do
            if pal.team_key == team_key and pal.damage > 0 then
                sources[#sources + 1] = {
                    name = pal.name .. "［" .. pal.owner_name .. "］",
                    damage = pal.damage,
                    hits = pal.hits,
                }
            end
        end
        sources = ranked_damage_entries(sources)

        local messages = {
            tr("team_report", {
                team = team.name,
                damage = format_integer(team.damage),
                dps = format_integer(team.damage / duration),
                sources = #sources,
            }),
        }
        for index = 1, math.min(max_rows, #sources) do
            local source = sources[index]
            local percent = team.damage > 0 and source.damage * 100 / team.damage or 0
            messages[#messages + 1] = tr("team_row", {
                rank = index,
                source = source.name,
                damage = format_integer(source.damage),
                percent = string.format("%.1f", percent),
                dps = format_integer(source.damage / duration),
            })
        end
        if #sources > max_rows then
            messages[#messages + 1] = tr("remaining_sources", {
                count = #sources - max_rows,
            })
        end
        queue_messages(messages, team_recipients(session, team_key))
    end
end

local function decimal(value)
    return value ~= nil and string.format("%.1f", value) or "—"
end

local function number_stats(values)
    if #values == 0 then
        return nil
    end
    local total = 0
    local minimum = values[1]
    local maximum = values[1]
    for _, value in ipairs(values) do
        total = total + value
        minimum = math.min(minimum, value)
        maximum = math.max(maximum, value)
    end
    return {
        count = #values,
        average = total / #values,
        minimum = minimum,
        maximum = maximum,
        total = total,
    }
end

local function stats_text(stats, translator_code)
    if stats == nil then
        return "—"
    end
    local chinese = translator_code == "zh-TW" or translator_code == "zh-CN"
    if stats.count <= 1 or math.abs(stats.maximum - stats.minimum) < 0.05 then
        return decimal(stats.average) .. (chinese and "秒" or "s")
    end
    if chinese then
        return string.format(
            "%.1f秒（%.1f–%.1f）",
            stats.average, stats.minimum, stats.maximum
        )
    end
    return string.format("%.1fs (%.1f–%.1f)", stats.average, stats.minimum, stats.maximum)
end

local function diagnostic_skill_display_name(candidate, translator_code)
    local code = tostring(candidate.name or "UNKNOWN")
    local localized = tostring(candidate.localized_name or "")
    if localized ~= "" and localized ~= code then
        if translator_code == "zh-TW" or translator_code == "zh-CN" then
            return localized .. "（" .. code .. "）"
        end
        return localized .. " (" .. code .. ")"
    end
    return code
end

local function candidate_timing(session, source, candidate)
    candidate.casts = candidate.casts or {}
    local canonical_name = canonical_skill_name(candidate.name)
    for action_key, record in pairs(action_records) do
        local actor_matches = record.actor_key ~= nil
            and source.runtime_actor_keys ~= nil
            and source.runtime_actor_keys[record.actor_key] == true
        local skill_matches = canonical_skill_name(record.code) == canonical_name
        local started_before_finish = record.started_at == nil
            or record.started_at <= (session.finished_game_at or math.huge)
        local ended_after_start = record.ended_at == nil
            or record.ended_at >= (session.started_game_at or 0)
        if actor_matches and skill_matches and started_before_finish and ended_after_start then
            local cast = candidate.casts[action_key]
            if cast == nil then
                cast = { key = action_key, damage = 0, hits = 0 }
                candidate.casts[action_key] = cast
            end
        end
    end

    local casts = {}
    for action_key, cast in pairs(candidate.casts) do
        local record = action_records[action_key]
        if record ~= nil then
            cast.started_at = record.started_at
            cast.ended_at = record.ended_at
            candidate.localized_name = (candidate.localized_name ~= nil
                and candidate.localized_name ~= "")
                and candidate.localized_name or record.localized_name
            candidate.panel_cool_time = candidate.panel_cool_time
                or record.panel_cool_time
        end
        casts[#casts + 1] = cast
    end
    table.sort(casts, function(a, b)
        local left = a.started_at or a.first_hit_at or a.ended_at or math.huge
        local right = b.started_at or b.first_hit_at or b.ended_at or math.huge
        if left == right then
            return tostring(a.key) < tostring(b.key)
        end
        return left < right
    end)

    local action_durations = {}
    local action_damage = 0
    local hit_windows = {}
    local intervals = {}
    local full_start_intervals = 0
    local reuse_gaps = {}
    local hit_cast_count = 0
    for index, cast in ipairs(casts) do
        if (cast.hits or 0) > 0 then
            hit_cast_count = hit_cast_count + 1
            local hit_window = math.max(
                0,
                (cast.last_hit_at or cast.first_hit_at or 0)
                    - (cast.first_hit_at or cast.last_hit_at or 0)
            )
            hit_windows[#hit_windows + 1] = hit_window
        end
        if cast.started_at ~= nil and cast.ended_at ~= nil
            and cast.ended_at > cast.started_at then
            cast.action_duration = cast.ended_at - cast.started_at
            action_durations[#action_durations + 1] = cast.action_duration
            action_damage = action_damage + (cast.damage or 0)
        end
        if index > 1 then
            local previous = casts[index - 1]
            local previous_start = previous.started_at or previous.first_hit_at
            local current_start = cast.started_at or cast.first_hit_at
            if previous_start ~= nil and current_start ~= nil
                and current_start > previous_start then
                intervals[#intervals + 1] = current_start - previous_start
                if previous.started_at ~= nil and cast.started_at ~= nil then
                    full_start_intervals = full_start_intervals + 1
                end
            end
            if previous.ended_at ~= nil and cast.started_at ~= nil
                and cast.started_at >= previous.ended_at then
                reuse_gaps[#reuse_gaps + 1] = cast.started_at - previous.ended_at
            end
        end
    end

    local action_stats = number_stats(action_durations)
    local interval_stats = number_stats(intervals)
    local panel_cd = finite_positive_number(candidate.panel_cool_time)
    local timing = {
        casts = casts,
        cast_count = #casts,
        hit_cast_count = hit_cast_count,
        average_cast_damage = #casts > 0 and candidate.damage / #casts or nil,
        action_stats = action_stats,
        action_dps = action_stats ~= nil and action_stats.total > 0
            and action_damage / action_stats.total
            or nil,
        hit_window_stats = number_stats(hit_windows),
        interval_stats = interval_stats,
        full_start_intervals = full_start_intervals,
        reuse_gap_stats = number_stats(reuse_gaps),
        panel_cool_time = panel_cd,
        panel_delta = interval_stats ~= nil and panel_cd ~= nil
            and interval_stats.average - panel_cd
            or nil,
    }
    return timing
end

local function diagnostic_snapshot(session, state, reason)
    local finished_at = session.finished_game_at
    local now = finished_at or game_time_seconds()
    local duration = math.max(0.1, now - (session.started_game_at or now))
    local translator_code = get_translator().code
    local snapshot = {
        state = state or "active",
        reason = reason,
        boss = session.name,
        duration = duration,
        total_damage = session.total_damage,
        encounter_dps = session.total_damage / duration,
        include_player = config.IncludePlayerDamage == true,
        measurement_mode = session.manual == true and "manual" or "target",
        target_count = session.target_count or 1,
        language = translator_code,
        sources = {},
    }
    for _, source in ipairs(ranked_damage_entries(session.diagnostic_sources or {})) do
        local source_row = {
            kind = source.kind,
            name = source.name,
            damage = source.damage,
            dps = source.damage / duration,
            hits = source.hits or 0,
            skills = {},
        }
        for _, candidate in ipairs(ranked_damage_entries(snapshot_skill_candidates(source))) do
            local timing = candidate_timing(session, source, candidate)
            local internal_code = tostring(candidate.name or "UNKNOWN")
            local localized_name = tostring(candidate.localized_name or "")
            source_row.skills[#source_row.skills + 1] = {
                name = skill_display_name(internal_code, localized_name),
                runtime_name = localized_name,
                internal_code = internal_code,
                category = skill_candidate_category(source, candidate),
                damage = candidate.damage,
                encounter_dps = candidate.damage / duration,
                hits = candidate.hits or 0,
                casts = timing.cast_count,
                damage_per_cast = timing.average_cast_damage,
                panel_cd = timing.panel_cool_time,
                actual_interval = timing.interval_stats and timing.interval_stats.average or nil,
                action_duration = timing.action_stats and timing.action_stats.average or nil,
                action_dps = timing.action_dps,
                reuse_gap = timing.reuse_gap_stats and timing.reuse_gap_stats.average or nil,
                lifecycle_complete = timing.action_stats and timing.action_stats.count or 0,
            }
        end
        snapshot.sources[#snapshot.sources + 1] = source_row
    end
    return snapshot
end

local function publish_skill_hud(session, state, reason)
    if skill_hud == nil or session == nil then
        return
    end
    skill_hud:publish(diagnostic_snapshot(session, state, reason))
end

local function log_candidate_casts(session, source, candidate, timing)
    if config.SkillDiagnosticLogCasts ~= true then
        return
    end
    local maximum = math.max(0, math.floor(to_number(config.SkillDiagnosticMaxCastLogRows)))
    for index = 1, math.min(maximum, #timing.casts) do
        local cast = timing.casts[index]
        local hit_window = cast.first_hit_at ~= nil and cast.last_hit_at ~= nil
            and math.max(0, cast.last_hit_at - cast.first_hit_at)
            or nil
        local cast_dps = cast.action_duration ~= nil and cast.action_duration > 0
            and cast.damage / cast.action_duration
            or nil
        log(string.format(
            "diagnostic-cast boss=%s source=%s candidate=%s cast=%d damage=%s hits=%d action_duration=%s cast_dps=%s hit_window=%s lifecycle=%s",
            session.name,
            source.name,
            candidate.name,
            index,
            format_integer(cast.damage or 0),
            cast.hits or 0,
            decimal(cast.action_duration),
            decimal(cast_dps),
            decimal(hit_window),
            cast.started_at ~= nil and cast.ended_at ~= nil and "complete" or "partial"
        ))
    end
end

local function finish_skill_diagnostics(session, duration, reason, recipients)
    -- Untagged hits remain unresolved through final reporting. Do not reconcile
    -- them from BasePower/element signatures learned from other hits.
    publish_skill_hud(session, "finished", reason)
    local sources = ranked_damage_entries(session.diagnostic_sources)
    local candidate_total = 0
    local translator_code = get_translator().code
    local chat_rows = {}
    local chat_candidate_count = 0
    local chat_maximum = math.max(0, math.floor(to_number(config.SkillDiagnosticChatMaxRows)))
    log(string.format(
        "diagnostic-summary-begin boss=%s reason=%s duration=%d damage=%s sources=%d include_player=%s",
        session.name,
        tostring(reason),
        duration,
        format_integer(session.total_damage),
        #sources,
        tostring(config.IncludePlayerDamage == true)
    ))

    for _, source in ipairs(sources) do
        local candidates = ranked_damage_entries(source.skill_candidates)
        candidate_total = candidate_total + #candidates
        log(string.format(
            "diagnostic-source boss=%s source_kind=%s source=%s owner=%s damage=%s dps=%s hits=%d candidates=%d",
            session.name,
            tostring(source.kind),
            source.name,
            source.owner_name,
            format_integer(source.damage),
            format_integer(source.damage / duration),
            source.hits or 0,
            #candidates
        ))
        for rank, candidate in ipairs(candidates) do
            local share = source.damage > 0 and candidate.damage * 100 / source.damage or 0
            local average = candidate.hits > 0 and candidate.damage / candidate.hits or 0
            local timing = candidate_timing(session, source, candidate)
            local display_name = diagnostic_skill_display_name(candidate, translator_code)
            log(string.format(
                "diagnostic-candidate boss=%s source_kind=%s source=%s rank=%d candidate=%s localized=%s damage=%s share=%.1f encounter_dps=%s hits=%d avg_hit=%s casts=%d hit_casts=%d avg_cast_damage=%s panel_cd=%s actual_interval=%s interval_min=%s interval_max=%s panel_delta=%s action_duration=%s action_duration_min=%s action_duration_max=%s action_dps=%s reuse_gap=%s hit_window=%s lifecycle_coverage=%d/%d causer=%s class=%s fields=%s actor=%s",
                session.name,
                tostring(source.kind),
                source.name,
                rank,
                candidate.name,
                candidate.localized_name ~= "" and candidate.localized_name or "none",
                format_integer(candidate.damage),
                share,
                format_integer(candidate.damage / duration),
                candidate.hits,
                format_integer(average),
                timing.cast_count,
                timing.hit_cast_count,
                decimal(timing.average_cast_damage),
                decimal(timing.panel_cool_time),
                decimal(timing.interval_stats and timing.interval_stats.average),
                decimal(timing.interval_stats and timing.interval_stats.minimum),
                decimal(timing.interval_stats and timing.interval_stats.maximum),
                decimal(timing.panel_delta),
                decimal(timing.action_stats and timing.action_stats.average),
                decimal(timing.action_stats and timing.action_stats.minimum),
                decimal(timing.action_stats and timing.action_stats.maximum),
                decimal(timing.action_dps),
                decimal(timing.reuse_gap_stats and timing.reuse_gap_stats.average),
                decimal(timing.hit_window_stats and timing.hit_window_stats.average),
                timing.action_stats and timing.action_stats.count or 0,
                timing.cast_count,
                candidate.causer_full_name,
                candidate.causer_class_name,
                candidate.fields,
                candidate.source_full_name
            ))
            log_candidate_casts(session, source, candidate, timing)
            if chat_candidate_count < chat_maximum then
                chat_candidate_count = chat_candidate_count + 1
                if translator_code == "zh-TW" then
                    chat_rows[#chat_rows + 1] = string.format(
                        "%s｜技能 #%d %s｜傷害 %s｜占比 %.1f%%｜整場DPS %s｜命中 %d｜平均每擊 %s",
                        source.name, rank, display_name,
                        format_integer(candidate.damage), share,
                        format_integer(candidate.damage / duration),
                        candidate.hits, format_integer(average)
                    )
                    chat_rows[#chat_rows + 1] = string.format(
                        "↳ 觀測施放 %d次（命中%d）｜每次傷害 %s｜面板CD %s秒｜實際開始間隔 %s｜較面板 %s秒",
                        timing.cast_count, timing.hit_cast_count,
                        decimal(timing.average_cast_damage), decimal(timing.panel_cool_time),
                        stats_text(timing.interval_stats, translator_code),
                        timing.panel_delta ~= nil and string.format("%+.1f", timing.panel_delta) or "—"
                    )
                    chat_rows[#chat_rows + 1] = string.format(
                        "↳ 完整動作 %s｜單次施放DPS %s｜再用空窗 %s｜首末命中窗 %s｜完整計時 %d/%d",
                        stats_text(timing.action_stats, translator_code), decimal(timing.action_dps),
                        stats_text(timing.reuse_gap_stats, translator_code),
                        stats_text(timing.hit_window_stats, translator_code),
                        timing.action_stats and timing.action_stats.count or 0,
                        timing.cast_count
                    )
                elseif translator_code == "zh-CN" then
                    chat_rows[#chat_rows + 1] = string.format(
                        "%s｜技能 #%d %s｜伤害 %s｜占比 %.1f%%｜整场DPS %s｜命中 %d｜平均每击 %s",
                        source.name, rank, display_name,
                        format_integer(candidate.damage), share,
                        format_integer(candidate.damage / duration),
                        candidate.hits, format_integer(average)
                    )
                    chat_rows[#chat_rows + 1] = string.format(
                        "↳ 观测施放 %d次（命中%d）｜每次伤害 %s｜面板CD %s秒｜实际开始间隔 %s｜较面板 %s秒",
                        timing.cast_count, timing.hit_cast_count,
                        decimal(timing.average_cast_damage), decimal(timing.panel_cool_time),
                        stats_text(timing.interval_stats, translator_code),
                        timing.panel_delta ~= nil and string.format("%+.1f", timing.panel_delta) or "—"
                    )
                    chat_rows[#chat_rows + 1] = string.format(
                        "↳ 完整动作 %s｜单次施放DPS %s｜再用空窗 %s｜首末命中窗 %s｜完整计时 %d/%d",
                        stats_text(timing.action_stats, translator_code), decimal(timing.action_dps),
                        stats_text(timing.reuse_gap_stats, translator_code),
                        stats_text(timing.hit_window_stats, translator_code),
                        timing.action_stats and timing.action_stats.count or 0,
                        timing.cast_count
                    )
                else
                    chat_rows[#chat_rows + 1] = string.format(
                        "%s | skill #%d %s | damage %s | share %.1f%% | encounter DPS %s | hits %d | avg %s",
                        source.name, rank, display_name,
                        format_integer(candidate.damage), share,
                        format_integer(candidate.damage / duration),
                        candidate.hits, format_integer(average)
                    )
                    chat_rows[#chat_rows + 1] = string.format(
                        "↳ observed casts %d (hit %d) | damage/cast %s | panel CD %ss | actual start interval %s | delta %ss",
                        timing.cast_count, timing.hit_cast_count,
                        decimal(timing.average_cast_damage), decimal(timing.panel_cool_time),
                        stats_text(timing.interval_stats, translator_code), decimal(timing.panel_delta)
                    )
                    chat_rows[#chat_rows + 1] = string.format(
                        "↳ full action %s | cast DPS %s | reuse gap %s | hit window %s | timing coverage %d/%d",
                        stats_text(timing.action_stats, translator_code), decimal(timing.action_dps),
                        stats_text(timing.reuse_gap_stats, translator_code),
                        stats_text(timing.hit_window_stats, translator_code),
                        timing.action_stats and timing.action_stats.count or 0,
                        timing.cast_count
                    )
                end
            end
        end
    end
    log(string.format(
        "diagnostic-summary-end boss=%s candidates=%d schema_dump=%s",
        session.name,
        candidate_total,
        tostring(config.DumpDamageSchema == true)
    ))

    local message
    if translator_code == "zh-TW" then
        message = string.format(
            "傷害驗證完成：%s｜納入傷害 %s｜來源 %d個｜技能／武器候選 %d個｜請保留 UE4SS.log",
            session.name,
            format_integer(session.total_damage),
            #sources,
            candidate_total
        )
    elseif translator_code == "zh-CN" then
        message = string.format(
            "伤害验证完成：%s｜纳入伤害 %s｜来源 %d个｜技能/武器候选 %d个｜请保留 UE4SS.log",
            session.name,
            format_integer(session.total_damage),
            #sources,
            candidate_total
        )
    else
        message = string.format(
            "Damage diagnostics complete: %s | damage %s | sources %d | candidates %d | keep UE4SS.log",
            session.name,
            format_integer(session.total_damage),
            #sources,
            candidate_total
        )
    end
    local chat_mode = tostring(config.SkillDiagnosticChatMode or "off")
    if chat_mode == "summary" then
        queue_messages({ message }, recipients)
    elseif chat_mode == "full" then
        local messages = { message }
        for _, row in ipairs(chat_rows) do
            messages[#messages + 1] = row
        end
        queue_messages(messages, recipients)
    end
end

local function bind_session_actor(session, boss_info)
    session.actor_addresses = session.actor_addresses or {}
    session.actor_keys = session.actor_keys or {}
    session.actor_parts_by_address = session.actor_parts_by_address or {}
    session.actor_parts_by_key = session.actor_parts_by_key or {}
    session.composite_parts_seen = session.composite_parts_seen or {}
    session.native_target_keys = session.native_target_keys or {}

    local part = nil
    if boss_info.composite_part ~= nil then
        part = {
            id = boss_info.composite_part,
            terminal = boss_info.composite_terminal == true,
        }
        session.composite_parts_seen[part.id] = true
    end
    if session.composite_anchor == nil and boss_info.composite_anchor ~= nil then
        session.composite_anchor = boss_info.composite_anchor
    end

    if boss_info.address ~= nil then
        session.actor_addresses[boss_info.address] = true
        session_addresses[boss_info.address] = session
        session.actor_parts_by_address[boss_info.address] = part
    end
    if boss_info.key ~= nil and boss_info.key ~= "" then
        session.actor_keys[boss_info.key] = true
        session_actor_keys[boss_info.key] = session
        session.actor_parts_by_key[boss_info.key] = part
    end
end

local function unbind_session_actor(session, address, key)
    if address ~= nil then
        session_addresses[address] = nil
        if session.actor_addresses ~= nil then
            session.actor_addresses[address] = nil
        end
    end
    if key ~= nil and key ~= "" then
        session_actor_keys[key] = nil
        if session.actor_keys ~= nil then
            session.actor_keys[key] = nil
        end
    end
end

local function find_composite_session(boss_info)
    if boss_info.composite_group == nil then
        return nil
    end
    local now = os.time()
    local join_window = math.max(1, math.floor(to_number(config.CompositePartJoinWindowSeconds)))
    local fallback = nil
    for _, session in pairs(sessions) do
        if session.finished ~= true and session.composite_group == boss_info.composite_group then
            local anchor_matches = session.composite_anchor ~= nil
                and boss_info.composite_anchor ~= nil
                and session.composite_anchor == boss_info.composite_anchor
            if anchor_matches then
                return session
            end

            local anchor_conflicts = session.composite_anchor ~= nil
                and boss_info.composite_anchor ~= nil
                and session.composite_anchor ~= boss_info.composite_anchor
            local part_is_new = boss_info.composite_part == nil
                or session.composite_parts_seen[boss_info.composite_part] ~= true
            if not anchor_conflicts and part_is_new
                and now - session.started_at <= join_window
                and (fallback == nil or session.started_at > fallback.started_at) then
                fallback = session
            end
        end
    end
    return fallback
end

local function finish_session(session, reason)
    if session == nil or session.finished == true then
        return
    end
    session.finished = true
    session.finished_game_at = game_time_seconds()
    sessions[session.key] = nil
    for address in pairs(session.actor_addresses or {}) do
        session_addresses[address] = nil
    end
    for key in pairs(session.actor_keys or {}) do
        session_actor_keys[key] = nil
    end
    for target_key in pairs(session.native_target_keys or {}) do
        classify_native_target(target_key, "unknown")
    end

    local duration = math.max(1, os.time() - session.started_at)
    local rows = ranked_contributors(session)
    local teams = ranked_damage_entries(session.teams)
    local pals = ranked_damage_entries(session.pal_sources)
    local recipients = session_recipients(session)
    hooks.log_native_diagnostic_status("session-" .. tostring(reason))
    if config.SkillDiagnosticsOnly == true then
        finish_skill_diagnostics(session, duration, reason, recipients)
        return
    end
    local messages = {}
    local team_prefix = #teams == 1 and (teams[1].name .. "｜") or ""
    if reason == "defeated" then
        messages[#messages + 1] = tr("kill_summary", {
            team_prefix = team_prefix,
            killer = session.last_hitter_label or tr("team_default"),
            boss = session.name,
            seconds = duration,
            dps = format_integer(session.total_damage / duration),
            damage = format_integer(session.total_damage),
            players = #rows,
        })
    else
        local summary_key = reason == "captured" and "captured_summary" or "timeout_summary"
        messages[#messages + 1] = tr(summary_key, {
            team_prefix = team_prefix,
            boss = session.name,
            damage = format_integer(session.total_damage),
            dps = format_integer(session.total_damage / duration),
            seconds = duration,
            players = #rows,
        })
    end

    if fun_commentary_enabled() then
        local top_share = #rows > 0 and rows[1].damage * 100 / session.total_damage or 0
        local second_share = #rows > 1 and rows[2].damage * 100 / session.total_damage or 0
        local comment = battle_commentary.final({
            key = session.key,
            reason = reason,
            total = session.total_damage,
            duration = duration,
            team_dps = session.total_damage / duration,
            top_share = top_share,
            second_share = second_share,
            guild = #teams > 0 and teams[1].name or tr("team_default"),
            player = #rows > 0 and rows[1].name or tr("player_default"),
            runnerup = #rows > 1 and rows[2].name or tr("runnerup_default"),
            pal = #pals > 0 and pals[1].name or tr("pal_default"),
            boss = session.name,
        })
        messages[#messages + 1] = tr("battle_comment", { comment = comment })
    end

    if config.EnableDetailedAwards == true then
        if #teams > 1 then
            local team = teams[1]
            local team_percent = session.total_damage > 0 and team.damage * 100 / session.total_damage or 0
            messages[#messages + 1] = tr("top_team", {
                team = team.name,
                damage = format_integer(team.damage),
                percent = string.format("%.1f", team_percent),
                dps = format_integer(team.damage / duration),
            })
        end

        local direct_players = {}
        for _, row in ipairs(rows) do
            if row.direct_damage > 0 then
                direct_players[#direct_players + 1] = {
                    name = row.name,
                    damage = row.direct_damage,
                    hits = row.direct_hits,
                }
            end
        end
        direct_players = ranked_damage_entries(direct_players)
        if #direct_players > 0 then
            local direct = direct_players[1]
            messages[#messages + 1] = tr("top_player", {
                player = direct.name,
                damage = format_integer(direct.damage),
                dps = format_integer(direct.damage / duration),
            })
        end

        if #pals > 0 then
            local pal = pals[1]
            messages[#messages + 1] = tr("top_pal", {
                pal = pal.name,
                trainer = pal.owner_name,
                damage = format_integer(pal.damage),
                dps = format_integer(pal.damage / duration),
            })
        end
    end

    local max_rows = math.max(1, math.floor(to_number(config.MaxResultRows)))
    for index = 1, math.min(max_rows, #rows) do
        local row = rows[index]
        local percent = session.total_damage > 0 and row.damage * 100 / session.total_damage or 0
        local rank_label = string.format("#%d", index)
        if index == 1 and config.MarkTopAsMVP ~= false then
            rank_label = "MVP #1"
        end
        local line = tr("rank_line", {
            rank = rank_label,
            player = row.name,
            damage = format_integer(row.damage),
            percent = string.format("%.1f", percent),
        })
        if config.ShowDPS == true then
            line = line .. tr("dps_append", {
                dps = format_integer(row.damage / duration),
            })
        end
        messages[#messages + 1] = line
    end
    if #rows > max_rows then
        messages[#messages + 1] = tr("remaining_participants", {
            count = #rows - max_rows,
        })
    end

    log(string.format(
        "session finished reason=%s boss=%s damage=%s duration=%d contributors=%d",
        tostring(reason), session.name, format_integer(session.total_damage), duration, #rows
    ))
    queue_messages(messages, recipients)
    if pal_damage_breakdown_enabled() then
        queue_team_details(session, duration)
    end
end

local function start_session(boss_info)
    local now = os.time()
    local session = {
        key = boss_info.key,
        address = boss_info.address,
        name = boss_info.name,
        manual = boss_info.manual == true,
        manual_armed = boss_info.manual == true,
        target_count = 0,
        composite_group = boss_info.composite_group,
        composite_anchor = boss_info.composite_anchor,
        composite_parts_seen = {},
        actor_addresses = {},
        actor_keys = {},
        actor_parts_by_address = {},
        actor_parts_by_key = {},
        started_at = now,
        started_game_at = game_time_seconds(),
        last_damage_at = now,
        last_progress_at = now,
        total_damage = 0,
        progress_damage = 0,
        previous_progress_dps = 0,
        progress_index = 0,
        contributors = {},
        teams = {},
        pal_sources = {},
        pal_actor_sources = {},
        player_sources = {},
        diagnostic_sources = {},
        source_owner_cache = {},
        player_state_entries = {},
        skill_candidate_count = 0,
        start_announced = false,
        finished = false,
    }
    sessions[session.key] = session
    bind_session_actor(session, boss_info)
    log("session started target=" .. session.name .. " key=" .. session.key
        .. " manual=" .. tostring(session.manual))
    return session
end

local function ensure_manual_session()
    local key = "__PAL_SKILL_DPS_MANUAL_TEST__"
    local session = sessions[key]
    if session ~= nil and session.finished ~= true then return session end
    return start_session({
        key = key,
        name = tr("hud_manual_test"),
        manual = true,
    })
end

local function record_damage(
    session,
    player_state,
    damage,
    source_kind,
    source_actor,
    utility,
    hit_count,
    event
)
    hit_count = math.max(1, math.floor(to_number(hit_count)))
    if session.manual == true and session.manual_armed == true then
        local now = os.time()
        session.manual_armed = false
        session.started_at = now
        session.started_game_at = game_time_seconds()
        session.last_damage_at = now
        session.last_progress_at = now
        log("manual test recording started on first accepted hit")
    end
    local state_address = actor_address(player_state)
    local key = state_address ~= nil and session.player_state_entries[state_address] or nil
    local entry = key ~= nil and session.contributors[key] or nil
    local uid = nil
    if entry ~= nil then
        metrics.contributor_cache_hits = metrics.contributor_cache_hits + 1
    else
        uid = player_uid(player_state)
        key = guid_key(uid)
        if key == nil then
            return
        end
        entry = session.contributors[key]
    end
    if entry == nil then
        entry = {
            uid = copy_guid(uid),
            name = player_name(player_state),
            damage = 0,
            progress_damage = 0,
            hits = 0,
            direct_damage = 0,
            direct_hits = 0,
        }
        entry.team_key, entry.team_name = player_team_info(player_state, uid, entry.name)
        session.contributors[key] = entry
    end
    if state_address ~= nil then
        session.player_state_entries[state_address] = key
    end
    entry.damage = entry.damage + damage
    entry.progress_damage = entry.progress_damage + damage
    entry.hits = entry.hits + hit_count
    session.total_damage = session.total_damage + damage
    session.progress_damage = session.progress_damage + damage
    session.last_damage_at = os.time()

    local team = session.teams[entry.team_key]
    if team == nil then
        team = { name = entry.team_name, damage = 0, hits = 0 }
        session.teams[entry.team_key] = team
    end
    team.name = entry.team_name
    team.damage = team.damage + damage
    team.hits = team.hits + hit_count

    if source_kind == "pal" then
        local actor_source_key = actor_address(source_actor) or actor_full_name(source_actor)
        local source_key = session.pal_actor_sources[actor_source_key]
        local pal = source_key ~= nil and session.pal_sources[source_key] or nil
        local display_name
        if pal ~= nil then
            display_name = pal.name
            metrics.pal_metadata_cache_hits = metrics.pal_metadata_cache_hits + 1
        else
            source_key, display_name = pal_source_info(source_actor, utility)
            if actor_source_key ~= nil and actor_source_key ~= "" then
                session.pal_actor_sources[actor_source_key] = source_key
            end
            pal = session.pal_sources[source_key]
        end
        if pal == nil then
            pal = {
                kind = "pal",
                name = display_name,
                owner_name = entry.name,
                owner_uid_key = key,
                team_key = entry.team_key,
                damage = 0,
                hits = 0,
                skill_candidates = {},
                runtime_actor_keys = {},
            }
            session.pal_sources[source_key] = pal
        end
        pal.name = display_name
        pal.owner_name = entry.name
        pal.team_key = entry.team_key
        pal.damage = pal.damage + damage
        pal.hits = pal.hits + hit_count
        local runtime_actor_key = diagnostic_actor_key(source_actor)
        if runtime_actor_key ~= nil and runtime_actor_key ~= "" then
            pal.runtime_actor_keys[runtime_actor_key] = true
        end
        session.diagnostic_sources["pal:" .. tostring(source_key)] = pal
        refresh_equipped_waza(pal, source_actor)
        attach_runtime_skill_evidence(event, source_actor, source_kind, pal)
        record_skill_candidate(session, pal, event, source_actor, damage, hit_count)
        session.last_hitter_label = tr("pal_killer", {
            player = entry.name,
            pal = display_name,
        })
    else
        entry.direct_damage = entry.direct_damage + damage
        entry.direct_hits = entry.direct_hits + hit_count
        local player_source = session.player_sources[key]
        if player_source == nil then
            player_source = {
                kind = "player",
                name = tr("player_role", { player = entry.name }),
                owner_name = entry.name,
                owner_uid_key = key,
                team_key = entry.team_key,
                damage = 0,
                hits = 0,
                skill_candidates = {},
                runtime_actor_keys = {},
            }
            session.player_sources[key] = player_source
        end
        player_source.damage = player_source.damage + damage
        player_source.hits = player_source.hits + hit_count
        local runtime_actor_key = diagnostic_actor_key(source_actor)
        if runtime_actor_key ~= nil and runtime_actor_key ~= "" then
            player_source.runtime_actor_keys[runtime_actor_key] = true
        end
        session.diagnostic_sources["player:" .. tostring(key)] = player_source
        attach_runtime_skill_evidence(event, source_actor, source_kind, player_source)
        record_skill_candidate(session, player_source, event, source_actor, damage, hit_count)
        session.last_hitter_label = entry.name
    end

    if session.start_announced ~= true then
        session.start_announced = true
        local diagnostics_chat_enabled = config.SkillDiagnosticsOnly ~= true
            or tostring(config.SkillDiagnosticChatMode or "off") ~= "off"
        if config.BroadcastStart ~= false and diagnostics_chat_enabled then
            local start_message = tr("start", { boss = session.name })
            if config.SkillDiagnosticsOnly == true then
                local code = get_translator().code
                if code == "zh-TW" then
                    start_message = (config.IncludePlayerDamage == true
                        and "開始記錄技能／武器候選："
                        or "開始記錄帕魯技能候選：") .. session.name
                elseif code == "zh-CN" then
                    start_message = (config.IncludePlayerDamage == true
                        and "开始记录技能/武器候选："
                        or "开始记录帕鲁技能候选：") .. session.name
                else
                    start_message = (config.IncludePlayerDamage == true
                        and "Skill/weapon diagnostics started: "
                        or "Pal skill diagnostics started: ") .. session.name
                end
            end
            queue_messages(
                { start_message },
                session_recipients(session)
            )
        end
    end

    if config.TraceDamage == true then
        log(string.format(
            "damage boss=%s player=%s actual=%s player_total=%s team_total=%s",
            session.name, entry.name, format_integer(damage),
            format_integer(entry.damage), format_integer(session.total_damage)
        ))
    end
end

local function publish_progress()
    if config.EnableProgressReports ~= true then
        return
    end
    local interval_setting = math.max(0, math.floor(to_number(config.ProgressIntervalSeconds)))
    if interval_setting <= 0 then
        return
    end

    local now = os.time()
    for _, session in pairs(sessions) do
        if session.finished ~= true and session.total_damage > 0
            and now - session.last_progress_at >= interval_setting then
            local window = math.max(1, now - session.last_progress_at)
            local rows = ranked_contributors(session)
            local teams = ranked_damage_entries(session.teams)
            local pals = ranked_damage_entries(session.pal_sources)
            local recipients = session_recipients(session)
            local current_dps = session.progress_damage / window
            local team_prefix = #teams == 1 and (teams[1].name .. "｜") or ""
            local messages = {
                tr("progress", {
                    team_prefix = team_prefix,
                    boss = session.name,
                    damage = format_integer(session.total_damage),
                    dps = format_integer(current_dps),
                }),
            }

            local max_rows = math.max(1, math.floor(to_number(config.ProgressMaxRows)))
            local compact = {}
            for index = 1, math.min(max_rows, #rows) do
                local row = rows[index]
                local percent = session.total_damage > 0 and row.damage * 100 / session.total_damage or 0
                compact[#compact + 1] = tr("progress_row", {
                    rank = index,
                    player = row.name,
                    damage = format_integer(row.damage),
                    percent = string.format("%.1f", percent),
                    dps = format_integer(row.progress_damage / window),
                })
            end
            if #rows > max_rows then
                compact[#compact + 1] = tr("more_players", {
                    count = #rows - max_rows,
                })
            end
            if #compact > 0 then
                messages[#messages + 1] = tr("output", {
                    rows = table.concat(compact, "｜"),
                })
            end

            session.progress_index = session.progress_index + 1
            if fun_commentary_enabled() and session.progress_damage > 0 then
                local top_share = #rows > 0 and rows[1].damage * 100 / session.total_damage or 0
                local comment = battle_commentary.progress({
                    key = session.key,
                    total = session.total_damage,
                    previous_total = session.total_damage - session.progress_damage,
                    window_damage = session.progress_damage,
                    current_dps = current_dps,
                    previous_dps = session.previous_progress_dps,
                    top_share = top_share,
                    window_index = session.progress_index,
                    guild = #teams > 0 and teams[1].name or tr("team_default"),
                    player = #rows > 0 and rows[1].name or tr("player_default"),
                    runnerup = #rows > 1 and rows[2].name or tr("runnerup_default"),
                    pal = #pals > 0 and pals[1].name or tr("pal_default"),
                    boss = session.name,
                })
                if comment ~= nil then
                    messages[#messages + 1] = tr("progress_comment", { comment = comment })
                end
            end

            if session.progress_damage > 0 then
                queue_messages(messages, recipients)
            end
            session.previous_progress_dps = current_dps
            session.last_progress_at = now
            session.progress_damage = 0
            for _, row in ipairs(rows) do
                row.progress_damage = 0
            end
        end
    end
end

local function non_boss_cache_hit(address)
    if address == nil then
        return false
    end
    local expires_at = non_boss_addresses[address]
    if expires_at == nil then
        return false
    end
    if expires_at < os.time() then
        non_boss_addresses[address] = nil
        return false
    end
    metrics.non_boss_cache_hits = metrics.non_boss_cache_hits + 1
    return true
end

local function remember_non_boss(address, native_target_key)
    if address == nil then
        return
    end
    local ttl = math.max(5, math.floor(to_number(config.NonBossCacheSeconds)))
    non_boss_addresses[address] = os.time() + ttl
    classify_native_target(native_target_key, "nonboss")
end

local function process_damage_event(event)
    if not is_valid(event.defender) then
        metrics.invalid = metrics.invalid + 1
        return
    end

    local address = actor_address(event.defender)
    local scope_all = tostring(config.TargetScope or "boss") == "all"
    if not scope_all and non_boss_cache_hit(address) then
        return
    end

    local key = actor_full_name(event.defender)
    if key == "" then
        metrics.invalid = metrics.invalid + 1
        return
    end
    local session = address ~= nil and session_addresses[address] or session_actor_keys[key]
    if not is_valid(event.attacker) then
        metrics.invalid = metrics.invalid + 1
        return
    end
    local utility = get_pal_utility()
    if utility == nil then
        metrics.invalid = metrics.invalid + 1
        return
    end

    -- Resolve the owner before opening an all-world/manual test. This prevents
    -- wild-vs-wild combat elsewhere in the world from creating phantom rows.
    local state, source_kind, source_actor = resolve_damage_owner(
        event,
        utility,
        session and session.source_owner_cache or global_source_owner_cache
    )
    if state == nil then
        return
    end
    if source_kind ~= "pal" and config.IncludePlayerDamage ~= true then
        metrics.ignored_player_damage = metrics.ignored_player_damage + math.max(
            1,
            math.floor(to_number(event.hits))
        )
        return
    end

    local target_info = nil
    if session == nil then
        target_info = get_target_info(event.defender, utility)
        if target_info == nil then
            if not scope_all then remember_non_boss(address, event.target_key) end
            return
        end

        if tostring(config.MeasurementMode or "target") == "manual" then
            session = ensure_manual_session()
            local already_bound = (target_info.address ~= nil
                and session.actor_addresses[target_info.address] == true)
                or (target_info.key ~= nil and session.actor_keys[target_info.key] == true)
            bind_session_actor(session, target_info)
            if not already_bound then
                session.target_count = (session.target_count or 0) + 1
            end
        else
            session = find_composite_session(target_info)
            if session ~= nil then
                bind_session_actor(session, target_info)
                metrics.composite_joins = metrics.composite_joins + 1
                log(string.format(
                    "composite part joined target=%s group=%s part=%s",
                    session.name,
                    tostring(target_info.composite_group),
                    tostring(target_info.composite_part)
                ))
            else
                session = start_session(target_info)
                session.target_count = 1
            end
        end
    end
    if event.target_key ~= nil then
        session.native_target_keys = session.native_target_keys or {}
        session.native_target_keys[event.target_key] = true
        classify_native_target(event.target_key, "boss")
    end

    event.observed_at = game_time_seconds()
    record_damage(
        session,
        state,
        event.damage,
        source_kind,
        source_actor or event.attacker,
        utility,
        event.hits,
        event
    )
end

local activate_lua_damage_fallback
local handle_native_collector_failure

local function drain_native_damage()
    if (hooks.damage_mode ~= "native" and hooks.damage_mode ~= "native-event")
        or config.EnableDPSRecording == false then
        return
    end
    local limit = math.max(1, math.floor(to_number(config.NativeMaxBucketsPerDrain)))
    for _ = 1, limit do
        local event_mode = hooks.damage_mode == "native-event"
        local called, has_record, first, defender, damage, damage_causer,
            override_network_owner, info_attacker, hits, target_key
        local native_event_results
        if event_mode then
            native_event_results = table.pack(pcall(BossDPSNativeDrainEventOne))
            called = native_event_results[1]
            has_record = native_event_results[2]
            first = native_event_results[3]
        else
            called, has_record, first, defender, damage, damage_causer,
                override_network_owner, info_attacker, hits, target_key =
                pcall(BossDPSNativeDrainOne)
        end
        if not called then
            metrics.errors = metrics.errors + 1
            log("native collector drain failed: " .. tostring(has_record))
            if handle_native_collector_failure ~= nil then
                handle_native_collector_failure("native collector drain call failed")
            end
            return
        end
        if has_record ~= true then
            if (first == "faulted" or first == "overflow")
                and handle_native_collector_failure ~= nil then
                handle_native_collector_failure("native collector " .. tostring(first)
                    .. " at runtime")
            end
            return
        end
        local event
        if event_mode then
            if type(first) == "table" then
                -- Compatibility with the first API-v2 development build.
                event = first
            else
                event = {
                    api_version = first,
                    kind = native_event_results[4],
                    sequence = native_event_results[5],
                    captured_ns = native_event_results[6],
                    damage = native_event_results[7],
                    hits = native_event_results[8],
                    evidence_kind = native_event_results[9],
                    attacker = native_event_results[10],
                    defender = native_event_results[11],
                    damage_causer = native_event_results[12],
                    override_network_owner = native_event_results[13],
                    info_attacker = native_event_results[14],
                    attacker_id = native_event_results[15],
                    defender_id = native_event_results[16],
                    damage_causer_id = native_event_results[17],
                    override_network_owner_id = native_event_results[18],
                    info_attacker_id = native_event_results[19],
                    damage_info_id = native_event_results[20],
                    action_id = native_event_results[21],
                    cast_id = native_event_results[22],
                    effect_id = native_event_results[23],
                    filter_id = native_event_results[24],
                    status_application_id = native_event_results[25],
                    target_key = native_event_results[26],
                    waza_id = native_event_results[27],
                    skill_code = native_event_results[28],
                    status_code = native_event_results[29],
                }
            end
            if type(event) ~= "table" or event.kind ~= "damage" then
                metrics.errors = metrics.errors + 1
                log("native event payload was invalid")
                return
            end
            local native_exact_evidence = event.evidence_kind == "effect_waza"
                or event.evidence_kind == "effect_cast_link"
                or event.evidence_kind == "damage_info_cast_link"
                or event.evidence_kind == "direct_waza_token"
            if native_exact_evidence
                and math.floor(to_number(event.waza_id)) > 0 then
                local native_waza_id = math.floor(to_number(event.waza_id))
                local native_code = tostring(event.skill_code or "")
                if native_code == "" then
                    native_code = "WAZA_ID_" .. tostring(native_waza_id)
                end
                event.effect_attack = {
                    token = event.sequence,
                    effect_id = event.effect_id,
                    cast_id = tostring(event.cast_id or "") ~= ""
                        and event.cast_id or nil,
                    code = native_code,
                    waza_id = native_waza_id,
                }
            end
            metrics.native_events = metrics.native_events + 1
        else
            event = {
                kind = "damage",
                attacker = first,
                defender = defender,
                damage = damage,
                damage_causer = damage_causer,
                override_network_owner = override_network_owner,
                info_attacker = info_attacker,
                hits = hits,
                target_key = target_key,
            }
        end
        metrics.accepted = metrics.accepted + 1
        metrics.processed = metrics.processed + 1
        metrics.native_buckets = metrics.native_buckets + 1
        metrics.native_hits = metrics.native_hits
            + math.max(1, math.floor(to_number(event.hits)))
        if config.EnableSkillDiagnostics == true
            and metrics.native_hits - hooks.last_native_status_hit_report >= 64 then
            hooks.last_native_status_hit_report = metrics.native_hits
            hooks.log_native_diagnostic_status("hit-checkpoint-" .. tostring(metrics.native_hits))
        end
        local ok, err = pcall(process_damage_event, event)
        if not ok then
            metrics.errors = metrics.errors + 1
            log("native damage processing error: " .. tostring(err))
        end
    end
end

local function process_finish_event(event)
    local candidates = event.candidates or { event.actor }
    local session = nil
    local matched_address = nil
    local matched_key = nil
    for _, actor in ipairs(candidates) do
        if actor ~= nil then
            -- GetAddress is a UE4SS wrapper operation and does not dereference
            -- the UObject. It can still identify a session after capture has
            -- invalidated the actor. Different 1.0 capture events put the
            -- captured character at different argument positions.
            local address = actor_address(actor)
            if address ~= nil then
                non_boss_addresses[address] = nil
            end
            local key = is_valid(actor) and actor_full_name(actor) or nil
            session = address ~= nil and session_addresses[address] or nil
            if session == nil and key ~= nil then
                session = key ~= "" and session_actor_keys[key] or nil
            end
            if session ~= nil then
                matched_address = address
                matched_key = key
                break
            end
        end
    end
    if session ~= nil then
        if session.manual == true then
            unbind_session_actor(session, matched_address, matched_key)
            log(string.format(
                "manual test target ended reason=%s target=%s; recording remains active",
                tostring(event.reason), tostring(matched_key or matched_address)
            ))
            return
        elseif event.reason == "defeated" and session.composite_group ~= nil then
            local part = (matched_address ~= nil and session.actor_parts_by_address[matched_address])
                or (matched_key ~= nil and session.actor_parts_by_key[matched_key])
            if part ~= nil and part.terminal ~= true then
                unbind_session_actor(session, matched_address, matched_key)
                log(string.format(
                    "composite part ended boss=%s group=%s part=%s; encounter remains active",
                    session.name, tostring(session.composite_group), tostring(part.id)
                ))
                return
            end
        end
        finish_session(session, event.reason)
    elseif event.reason == "captured" then
        log(string.format("capture event did not match an active boss session; candidates=%d", #candidates))
    end
end

local schedule_drain

local function queue_size()
    return pending_tail >= pending_head and (pending_tail - pending_head + 1) or 0
end

local function pop_event()
    if pending_tail < pending_head then
        return nil
    end
    local event = pending_events[pending_head]
    pending_events[pending_head] = nil
    pending_head = pending_head + 1
    if pending_head > pending_tail then
        pending_head = 1
        pending_tail = 0
    end
    return event
end

local function drain_events()
    drain_scheduled = false
    local limit = math.max(1, math.floor(to_number(config.MaxEventsPerDrain)))
    local count = 0
    while count < limit do
        local event = pop_event()
        if event == nil then
            break
        end
        count = count + 1
        metrics.processed = metrics.processed + 1
        local ok, err
        if event.kind == "damage" then
            ok, err = pcall(process_damage_event, event)
        elseif event.kind == "waza" then
            ok, err = pcall(process_waza_marker, event)
        elseif event.kind == "action_begin" or event.kind == "action_end" then
            ok, err = pcall(process_action_lifecycle_event, event)
        else
            ok, err = pcall(process_finish_event, event)
        end
        if not ok then
            metrics.errors = metrics.errors + 1
            log("event processing error: " .. tostring(err))
        end
    end
    if queue_size() > 0 then
        schedule_drain()
    end
end

schedule_drain = function()
    if drain_scheduled then
        return
    end
    drain_scheduled = true
    local ok, err = pcall(function()
        if EngineTickAvailable == true and EGameThreadMethod ~= nil then
            ExecuteInGameThread(drain_events, EGameThreadMethod.EngineTick)
        else
            ExecuteInGameThread(drain_events)
        end
    end)
    if not ok then
        drain_scheduled = false
        metrics.errors = metrics.errors + 1
        log("failed to schedule game-thread drain: " .. tostring(err))
    end
end

local function enqueue_event(event)
    local max_pending = math.max(64, math.floor(to_number(config.MaxPendingEvents)))
    if (event.kind == "damage" or event.kind == "waza"
        or event.kind == "action_begin" or event.kind == "action_end")
        and queue_size() >= max_pending then
        metrics.dropped = metrics.dropped + 1
        return
    end
    pending_tail = pending_tail + 1
    pending_events[pending_tail] = event
    metrics.accepted = metrics.accepted + 1
    schedule_drain()
end

local function capture_damage(damage_param)
    if config.EnableDPSRecording == false then
        return
    end
    -- Only unwrap the temporary hook parameter and copy its fields here.
    -- Do not call IsValid, Find*, StaticFindObject, or any UFunction.
    local result = unwrap(damage_param)
    if result == nil then
        return
    end
    local ok, attacker, defender, damage = pcall(function()
        return result.Attacker, result.Defender, finite_positive_number(result.ActualDamage)
    end)
    if not ok or attacker == nil or defender == nil or damage == nil then
        return
    end
    local function copied_field(container, field_name)
        if container == nil then
            return nil
        end
        local field_ok, value = pcall(function()
            return container[field_name]
        end)
        return field_ok and value or nil
    end

    local damage_info = copied_field(result, "DamageInfo")
        or copied_field(result, "CharacterDamageInfo")
        or copied_field(result, "damageInfo")
    local damage_info_key = nil
    if damage_info ~= nil then
        damage_info_key = captured_value_identity(damage_info)
    end
    local damage_causer = copied_field(result, "DamageCauser")
        or copied_field(result, "damageCauser")
        or copied_field(damage_info, "DamageCauser")
    local override_network_owner = copied_field(result, "OverrideNetworkOwner")
        or copied_field(damage_info, "OverrideNetworkOwner")
    local info_attacker = copied_field(damage_info, "Attacker")
    local diagnostic_fields = nil
    if config.EnableSkillDiagnostics == true then
        diagnostic_fields = {}
        local field_names = {
            "BasePower", "AttackElementType",
            "SkillID", "SkillId", "SkillName", "SkillType",
            "AttackSkillID", "AttackSkillId", "AttackType", "AttackAttribute",
            "AttackElement", "ElementType", "DamageType", "DamageAttribute",
            "WeaponType", "WazaID", "WazaId", "ActionID", "ActionId",
            "BulletID", "BulletId",
        }
        for _, container in ipairs({
            { prefix = "result.", value = result },
            { prefix = "info.", value = damage_info },
        }) do
            for _, field_name in ipairs(field_names) do
                local value = copied_field(container.value, field_name)
                local value_type = type(value)
                if value_type == "number" or value_type == "string" or value_type == "boolean" then
                    diagnostic_fields[container.prefix .. field_name] = value
                end
            end
        end
    end

    local effect_attack = source_chain:consume_hit(
        attacker, defender, damage_info_key)

    enqueue_event({
        kind = "damage",
        attacker = attacker,
        defender = defender,
        damage = damage,
        damage_causer = damage_causer,
        override_network_owner = override_network_owner,
        info_attacker = info_attacker,
        diagnostic_fields = diagnostic_fields,
        damage_info_key = damage_info_key,
        effect_attack = effect_attack,
    })
end

-- PalCharacterParameterComponent:OnDamage is Palworld's final-damage lane in
-- current builds. The payload shape differs from the older event-notify hook,
-- so probe only the temporary callback parameters and forward the first
-- struct that exposes Attacker/Defender/ActualDamage. No UFunction is called
-- from the hook.
local function capture_final_damage(...)
    if config.EnableDPSRecording == false then return end
    for index = 1, select("#", ...) do
        local candidate = unwrap(select(index, ...))
        local usable = false
        if candidate ~= nil then
            local probe_ok, probe_result = pcall(function()
                return candidate.Attacker ~= nil
                    and candidate.Defender ~= nil
                    and finite_positive_number(candidate.ActualDamage) ~= nil
            end)
            usable = probe_ok and probe_result == true
        end
        if usable then
            capture_damage(candidate)
            return
        end
    end
end

local function capture_waza_marker(attacker_param, defender_param, waza_param, return_param)
    if config.EnableDPSRecording == false or config.EnableSkillDiagnostics ~= true then
        return
    end
    local attacker = unwrap(attacker_param)
    local defender = unwrap(defender_param)
    local waza_id = math.floor(to_number(waza_param))
    if attacker == nil or defender == nil or waza_id <= 0 then
        return
    end
    local returned = unwrap(return_param)
    local damage_info_key = nil
    if returned ~= nil then
        damage_info_key = captured_value_identity(returned)
    end
    local function primitive_field(name)
        if returned == nil then return nil end
        local ok, value = pcall(function() return returned[name] end)
        if not ok then return nil end
        local value_type = type(value)
        if value_type == "number" or value_type == "string"
            or value_type == "boolean" then
            return value
        end
        return nil
    end
    local base_power = primitive_field("BasePower")
    local element = primitive_field("AttackElementType")
    local signature = nil
    if base_power ~= nil or element ~= nil then
        signature = tostring(base_power or "?") .. "|" .. tostring(element or "?")
    end
    local summary_parts = {}
    for _, name in ipairs({ "WazaID", "WazaId", "BasePower", "AttackElementType" }) do
        local value = primitive_field(name)
        if value ~= nil then
            summary_parts[#summary_parts + 1] = name .. "=" .. tostring(value)
        end
    end
    enqueue_event({
        kind = "waza",
        attacker = attacker,
        defender = defender,
        waza_id = waza_id,
        captured_at = os.time(),
        captured_clock = os.clock(),
        signature = signature,
        return_summary = #summary_parts > 0 and table.concat(summary_parts, ",") or nil,
        damage_info_key = damage_info_key,
    })
end

local function capture_action_lifecycle(kind, action_param)
    if config.EnableDPSRecording == false or config.EnableSkillDiagnostics ~= true then
        return
    end
    local action = unwrap(action_param)
    if action == nil then
        return
    end
    enqueue_event({ kind = kind, action = action, captured_clock = os.clock() })
end

activate_lua_damage_fallback = function(reason)
    if hooks.damage_mode == "lua-fallback" then
        return true
    end
    local damage_ok, damage_err = pcall(function()
        RegisterHook("/Script/Pal.PalEventNotify_Character:OnCharacterDamaged_ServerInternal", function(_, damage_result)
            local ok, err = pcall(capture_damage, damage_result)
            if not ok then
                metrics.errors = metrics.errors + 1
                log("damage capture error: " .. tostring(err))
            end
        end)
    end)
    hooks.damage = damage_ok
    hooks.damage_mode = damage_ok and "lua-fallback" or "none"
    if damage_ok then
        log("using Lua damage hook fallback: " .. tostring(reason or "native unavailable"))
    else
        log("damage hook registration failed: " .. tostring(damage_err))
    end
    return damage_ok
end

handle_native_collector_failure = function(reason)
    if hooks.damage_mode ~= "native" and hooks.damage_mode ~= "native-event" then
        return
    end
    if config.RequireNativeCollector == true then
        hooks.damage = false
        hooks.damage_mode = "required-native-faulted"
        log(tostring(reason) .. "; native collector is required, damage recording disabled")
        return
    end
    activate_lua_damage_fallback(reason)
end

local function capture_death(dead_param)
    if config.EnableDPSRecording == false then
        return
    end
    local result = unwrap(dead_param)
    if result == nil then
        return
    end
    local ok, actor = pcall(function()
        return result.SelfActor
    end)
    if ok and actor ~= nil then
        enqueue_event({ kind = "finish", reason = "defeated", actor = actor })
    end
end

local function capture_captured(...)
    if config.EnableDPSRecording == false then
        return
    end
    local candidates = {}
    for index = 1, select("#", ...) do
        local candidate = unwrap(select(index, ...))
        if candidate ~= nil then
            candidates[#candidates + 1] = candidate
        end
    end
    if #candidates > 0 then
        enqueue_event({
            kind = "finish",
            reason = "captured",
            actor = candidates[1],
            candidates = candidates,
        })
    end
end

local function cleanup_sessions()
    local timeout = math.max(0, math.floor(to_number(config.InactivityTimeoutSeconds)))
    if timeout <= 0 then
        return
    end
    local now = os.time()
    for address, expires_at in pairs(non_boss_addresses) do
        if expires_at < now then
            non_boss_addresses[address] = nil
        end
    end
    local expired = {}
    for _, session in pairs(sessions) do
        if session.finished ~= true and session.manual ~= true
            and now - session.last_damage_at >= timeout then
            expired[#expired + 1] = session
        end
    end
    for _, session in ipairs(expired) do
        finish_session(session, "timeout")
    end
end

local function activate_final_damage_hook()
    local candidates = {
        "/Script/Pal.PalCharacterParameterComponent:OnDamage",
        "/Script/Pal.PalDamageReactionComponent:MulticastDamageReact",
    }
    local errors = {}
    for _, path in ipairs(candidates) do
        local ok, err = pcall(function()
            RegisterHook(path, function(...)
                local captured, capture_err = pcall(capture_final_damage, ...)
                if not captured then
                    metrics.errors = metrics.errors + 1
                    log("final damage capture error: " .. tostring(capture_err))
                end
            end)
        end)
        if ok then
            hooks.final_damage = true
            hooks.final_damage_path = path
            log("final damage hook=" .. path)
            return true
        end
        errors[#errors + 1] = path .. ": " .. tostring(err)
    end
    hooks.final_damage = false
    hooks.final_damage_path = "none"
    log("final damage hook unavailable; compatibility hook retained: "
        .. table.concat(errors, " | "))
    return false
end

local function reset_skill_diagnostics()
    hooks.log_native_diagnostic_status("before-reset")
    if type(BossDPSNativeResetEvents) == "function" then
        local ok, err = pcall(BossDPSNativeResetEvents)
        if not ok then
            metrics.errors = metrics.errors + 1
            log("native diagnostic reset failed: " .. tostring(err))
        end
    end
    hooks.last_native_status_hit_report = metrics.native_hits
    local count = 0
    for key, session in pairs(sessions) do
        count = count + 1
        session.finished = true
        sessions[key] = nil
        for address in pairs(session.actor_addresses or {}) do
            session_addresses[address] = nil
        end
        for actor_key in pairs(session.actor_keys or {}) do
            session_actor_keys[actor_key] = nil
        end
        for target_key in pairs(session.native_target_keys or {}) do
            classify_native_target(target_key, "unknown")
        end
    end
    recent_waza_by_pair = {}
    recent_waza_by_attacker = {}
    global_source_owner_cache = {}
    action_records = {}
    action_record_order = {}
    recent_actions_by_actor = {}
    delayed_effect_bindings = {}
    source_chain:reset()
    metrics.trace_events = 0
    if skill_hud ~= nil then
        skill_hud:clear()
    end
    if tostring(config.MeasurementMode or "target") == "manual" then
        ensure_manual_session()
    end
    log("diagnostic reset active_sessions=" .. tostring(count))
end

local function publish_current_skill_hud()
    if skill_hud == nil or config.EnableSkillDiagnostics ~= true then
        return
    end
    skill_hud:poll_external_commands()
    local latest = nil
    for _, session in pairs(sessions) do
        if session.finished ~= true and session.total_damage > 0
            and (latest == nil or session.started_at > latest.started_at) then
            latest = session
        end
    end
    if latest ~= nil then
        publish_skill_hud(latest, "active")
    end
end

local function schedule_cleanup()
    local seconds = math.max(5, math.floor(to_number(config.CleanupIntervalSeconds)))
    local ok, err = pcall(function()
        LoopInGameThreadWithDelay(seconds * 1000, function()
            local cleaned, cleanup_err = pcall(cleanup_sessions)
            if not cleaned then
                metrics.errors = metrics.errors + 1
                log("cleanup error: " .. tostring(cleanup_err))
            end
        end)
    end)
    if not ok then
        metrics.errors = metrics.errors + 1
        log("cleanup scheduling failed: " .. tostring(err))
    end
end

local function schedule_progress()
    local seconds = math.max(0, math.floor(to_number(config.ProgressIntervalSeconds)))
    if seconds <= 0 then
        return
    end
    local ok, err = pcall(function()
        LoopInGameThreadWithDelay(seconds * 1000, function()
            local published, publish_err = pcall(publish_progress)
            if not published then
                metrics.errors = metrics.errors + 1
                log("progress publishing error: " .. tostring(publish_err))
            end
        end)
    end)
    if not ok then
        metrics.errors = metrics.errors + 1
        log("progress scheduling failed: " .. tostring(err))
    end
end

local function schedule_skill_hud()
    if config.EnableSkillDiagnostics ~= true then
        return
    end
    local milliseconds = math.max(100, math.floor(to_number(config.HUDRefreshMilliseconds)))
    local ok, err = pcall(function()
        LoopInGameThreadWithDelay(milliseconds, function()
            local published, publish_err = pcall(publish_current_skill_hud)
            if not published then
                metrics.errors = metrics.errors + 1
                log("HUD publishing error: " .. tostring(publish_err))
            end
        end)
    end)
    if not ok then
        metrics.errors = metrics.errors + 1
        log("HUD scheduling failed: " .. tostring(err))
    end
end

local function schedule_native_drain()
    if hooks.damage_mode ~= "native" and hooks.damage_mode ~= "native-event" then
        return
    end
    local milliseconds = math.max(
        10,
        math.floor(to_number(config.NativeDrainIntervalMilliseconds))
    )
    local ok, err = pcall(function()
        LoopInGameThreadWithDelay(milliseconds, function()
            local drained, drain_err = pcall(drain_native_damage)
            if not drained then
                metrics.errors = metrics.errors + 1
                log("native drain loop error: " .. tostring(drain_err))
            end
        end)
    end)
    if not ok then
        metrics.errors = metrics.errors + 1
        log("native drain scheduling failed: " .. tostring(err))
    end
end

local function reflected_name(object)
    local ok, fname = safe_call(object, "GetFName")
    if ok then
        local value = text_value(fname)
        if value ~= "" then
            return value
        end
    end
    ok, fname = safe_call(object, "GetName")
    return ok and text_value(fname) or "unknown"
end

local function dump_damage_schema()
    if config.EnableSkillDiagnostics ~= true or config.DumpDamageSchema ~= true then
        return
    end
    local function_path = "/Script/Pal.PalEventNotify_Character:OnCharacterDamaged_ServerInternal"
    local ok, damage_function = pcall(StaticFindObject, function_path)
    if not ok or not is_valid(damage_function) then
        log("damage-schema unavailable function=" .. function_path .. " error=" .. tostring(damage_function))
        return
    end

    local maximum = math.max(1, math.floor(to_number(config.SkillDiagnosticMaxSchemaFields)))
    local count = 0
    local seen_structs = {}
    local function walk(owner, prefix, depth)
        if owner == nil or count >= maximum then
            return
        end
        local nested_structs = {}
        local walked, walk_error = safe_call(owner, "ForEachProperty", function(property)
            if count >= maximum then
                return true
            end
            count = count + 1
            local property_name = reflected_name(property)
            local class_ok, property_class = safe_call(property, "GetClass")
            local property_type = class_ok and reflected_name(property_class) or "unknown"
            local offset_ok, offset = safe_call(property, "GetOffset_Internal")
            log(string.format(
                "damage-schema field=%s%s type=%s offset=%s",
                prefix,
                property_name,
                property_type,
                offset_ok and tostring(offset) or "unknown"
            ))

            if depth < 1 and string.find(property_type, "StructProperty", 1, true) ~= nil then
                local struct_ok, script_struct = safe_call(property, "GetStruct")
                if struct_ok and is_valid(script_struct) then
                    local struct_name = actor_full_name(script_struct)
                    if struct_name == "" then
                        struct_name = reflected_name(script_struct)
                    end
                    if seen_structs[struct_name] ~= true then
                        seen_structs[struct_name] = true
                        log("damage-schema struct=" .. struct_name .. " parent=" .. prefix .. property_name)
                        nested_structs[#nested_structs + 1] = {
                            value = script_struct,
                            prefix = prefix .. property_name .. ".",
                        }
                    end
                end
            end
            return false
        end)
        if not walked then
            log("damage-schema reflection failed owner=" .. prefix .. " error=" .. tostring(walk_error))
            return
        end
        for _, nested in ipairs(nested_structs) do
            walk(nested.value, nested.prefix, depth + 1)
        end
    end

    log("damage-schema-begin function=" .. function_path)
    walk(damage_function, "event.", 0)
    log(string.format("damage-schema-end fields=%d capped=%s", count, tostring(count >= maximum)))
end

local function schedule_damage_schema_dump()
    if rawget(_G, "__BOSS_DPS_TEST") == true
        or config.EnableSkillDiagnostics ~= true
        or config.DumpDamageSchema ~= true then
        return
    end
    local scheduled, schedule_error = pcall(function()
        ExecuteInGameThread(function()
            local dumped, dump_error = pcall(dump_damage_schema)
            if not dumped then
                metrics.errors = metrics.errors + 1
                log("damage-schema error=" .. tostring(dump_error))
            end
        end)
    end)
    if not scheduled then
        metrics.errors = metrics.errors + 1
        log("damage-schema scheduling failed: " .. tostring(schedule_error))
    end
end

local function register_hooks()
    local native_event_ready = false
    local native_ready = false
    if config.PreferNativeCollector ~= false
        and type(BossDPSNativeEventIsReady) == "function"
        and type(BossDPSNativeDrainEventOne) == "function" then
        local status_ok, status = pcall(BossDPSNativeEventIsReady)
        native_event_ready = status_ok and status == true
        if not status_ok then
            log("native event collector readiness check failed: " .. tostring(status))
        end
        if not native_event_ready then
            local native_status = type(BossDPSNativeStatus) == "function"
                and select(2, pcall(BossDPSNativeStatus))
                or "status-unavailable"
            local capabilities = type(BossDPSNativeCapabilities) == "function"
                and select(2, pcall(BossDPSNativeCapabilities))
                or "capabilities-unavailable"
            log("native event collector not ready: status=" .. tostring(native_status)
                .. " capabilities=" .. tostring(capabilities))
        end
    end
    if not native_event_ready and config.PreferNativeCollector ~= false
        and config.AllowLegacyNativeAggregate == true
        and type(BossDPSNativeIsReady) == "function"
        and type(BossDPSNativeDrainOne) == "function" then
        local status_ok, status = pcall(BossDPSNativeIsReady)
        native_ready = status_ok and status == true
        if not status_ok then
            log("native collector readiness check failed: " .. tostring(status))
        end
    end

    if native_event_ready then
        hooks.damage = true
        hooks.damage_mode = "native-event"
        local capabilities = type(BossDPSNativeCapabilities) == "function"
            and select(2, pcall(BossDPSNativeCapabilities))
            or "api_version=2"
        log("native event collector selected: " .. tostring(capabilities))
    elseif native_ready then
        hooks.damage = true
        hooks.damage_mode = "native"
        local status = type(BossDPSNativeStatus) == "function"
            and select(2, pcall(BossDPSNativeStatus))
            or "ready"
        log("native collector selected: " .. tostring(status))
    elseif config.RequireNativeCollector == true then
        hooks.damage = false
        hooks.damage_mode = "required-native-unavailable"
        log("native collector is required but unavailable; damage recording disabled")
    else
        if activate_final_damage_hook() then
            hooks.damage = true
            hooks.damage_mode = "pal-final-damage"
        else
            activate_lua_damage_fallback("final damage hook unavailable")
        end
    end

    if config.EnableSkillDiagnostics == true then
        local action_begin_ok, action_begin_err = pcall(function()
            RegisterHook("/Script/Pal.PalActionBase:OnBeginAction", function(action)
                local ok, err = pcall(capture_action_lifecycle, "action_begin", action)
                if not ok then
                    metrics.errors = metrics.errors + 1
                    log("action begin capture error: " .. tostring(err))
                end
            end)
        end)
        hooks.action_begin = action_begin_ok
        if not action_begin_ok then
            log("action begin hook unavailable; using hit-window timing: " .. tostring(action_begin_err))
        end

        local action_end_ok, action_end_err = pcall(function()
            RegisterHook("/Script/Pal.PalActionBase:OnEndAction", function(action)
                local ok, err = pcall(capture_action_lifecycle, "action_end", action)
                if not ok then
                    metrics.errors = metrics.errors + 1
                    log("action end capture error: " .. tostring(err))
                end
            end)
        end)
        hooks.action_end = action_end_ok
        if not action_end_ok then
            log("action end hook unavailable; delayed hits will remain unresolved: " .. tostring(action_end_err))
        end

        if config.EnableSkillSourceChain ~= false then
            local effect_ok, effect_err = source_chain:register_effect_hook()
            hooks.effect_initialize = effect_ok
            if effect_ok then
                log("skill source hook=/Script/Pal.PalSkillEffectBase:OnInitialize")
            else
                log("skill source hook unavailable; source-less hits remain unresolved: "
                    .. tostring(effect_err))
            end
            local filter_ok, filter_err = source_chain:register_filter_hook()
            hooks.attack_filter = filter_ok
            if filter_ok then
                log("skill source hook=/Script/Pal.PalAttackFilter:BindPrimitiveComponent")
            else
                log("attack filter hook unavailable; uninitialized effects may stay unresolved: "
                    .. tostring(filter_err))
            end
        end

        local waza_ok, waza_err = pcall(function()
            RegisterHook("/Script/Pal.PalUtility:MakeDamageInfoByWazaType", function(
                _, attacker, defender, attacker_hit_component,
                defender_hit_component, hit_location, foliage_index, waza_type
            )
                -- The post callback owns the completed ReturnValue. Capturing
                -- here would create a second, weaker marker before the damage
                -- info has been populated.
            end, function(
                -- UE4SS places a non-void ReturnValue immediately after the
                -- Context in post callbacks, before the original parameters.
                -- The former callback assumed it was last, so attacker/waza
                -- were shifted and every live marker was silently discarded.
                _, return_value, attacker, defender, attacker_hit_component,
                defender_hit_component, hit_location, foliage_index, waza_type,
                ...
            )
                local ok, err = pcall(
                    capture_waza_marker, attacker, defender, waza_type, return_value)
                if not ok then
                    metrics.errors = metrics.errors + 1
                    log("Waza post-marker capture error: " .. tostring(err))
                end
            end)
        end)
        hooks.waza = waza_ok
        if waza_ok then
            log("Waza attribution hook=/Script/Pal.PalUtility:MakeDamageInfoByWazaType")
        else
            log("Waza attribution hook unavailable; source-less hits remain unresolved: " .. tostring(waza_err))
        end
    end

    local death_ok, death_err = pcall(function()
        RegisterHook("/Script/Pal.PalEventNotify_Character:OnCharacterDead_ServerInternal", function(_, dead_info)
            local ok, err = pcall(capture_death, dead_info)
            if not ok then
                metrics.errors = metrics.errors + 1
                log("death capture error: " .. tostring(err))
            end
        end)
    end)
    hooks.death = death_ok
    if not death_ok then
        log("death hook registration failed: " .. tostring(death_err))
    end

    local capture_candidates = {
        -- Central 1.0 capture-success utility. Its two object parameters are
        -- the attacking player and the captured monster, so it covers normal
        -- field bosses without relying on an encounter-specific listener.
        "/Script/Pal.PalUtility:PalCaptureSuccess",
        -- Palworld 1.0 Modding Kit owners and exact signatures. These are
        -- encounter-specific follow-up listeners. Some field-boss capture
        -- flows do not call them, but they remain useful as compatibility
        -- fallbacks for dungeons, lock gimmicks, raids, and special bosses.
        "/Script/Pal.PalDungeonInstanceModel:OnCapturedBoss_ServerInternal",
        "/Script/Pal.PalDungeonGimmickUnlockableDoor_DefeatCharacterOnSpawner:OnCapturedCharacter_ServerInternal",
        "/Script/Pal.PalAICombatModule_KingWhale_Wild:OnCaptured_ServerInternal",
        "/Script/Pal.PalLevelObject_LockGimmickPalFight:OnPalCaptured",
        "/Script/Pal.PalRaidBossComponent:OnCapturePal",
        "/Script/Pal.PalNegotiatorComponent:OnOwnerCaptured",
        "/Script/Pal.PalCharacter:OnCaptured",
        "/Script/Pal.PalCaptureJudgeObject:OnCaptureSuccess",
    }
    local capture_errors = {}
    for _, capture_path in ipairs(capture_candidates) do
        local captured_ok, captured_err = pcall(function()
            RegisterHook(capture_path, function(_, first, second, third, fourth)
                local ok, err = pcall(capture_captured, first, second, third, fourth)
                if not ok then
                    metrics.errors = metrics.errors + 1
                    log("capture completion error: " .. tostring(err))
                end
            end)
        end)
        if captured_ok then
            hooks.captured = true
            hooks.captured_count = hooks.captured_count + 1
            log("capture completion hook=" .. capture_path)
        else
            capture_errors[#capture_errors + 1] = capture_path .. ": " .. tostring(captured_err)
        end
    end
    if not hooks.captured then
        log("capture hook registration failed: " .. table.concat(capture_errors, " | "))
    end

    if hooks.damage and hooks.death then
        log(string.format(
            "loaded v0.5.14-native-exact-attribution; collector=%s enabled=%s diagnostics=%s diagnostics_only=%s include_player=%s chat_mode=%s waza_hook=%s action_hooks=%s/%s effect_hook=%s filter_hook=%s effect_attack_hooks=%d local_only=%s; captured_hooks=%d",
            hooks.damage_mode,
            tostring(config.EnableDPSRecording ~= false),
            tostring(config.EnableSkillDiagnostics == true),
            tostring(config.SkillDiagnosticsOnly == true),
            tostring(config.IncludePlayerDamage == true),
            tostring(config.SkillDiagnosticChatMode or "off"),
            tostring(hooks.waza == true),
            tostring(hooks.action_begin == true),
            tostring(hooks.action_end == true),
            tostring(hooks.effect_initialize == true),
            tostring(hooks.attack_filter == true),
            hooks.effect_attack_count,
            tostring(config.LocalOnlyMessages == true),
            hooks.captured_count
        ))
    else
        log("disabled: one or more required hooks could not be registered")
    end
end

skill_hud = hud_module.new({
    config = config,
    log = log,
    get_player_controller = get_local_player_controller,
    get_world_context = find_world_context,
    is_gameplay_available = local_gameplay_available,
    get_language = function() return get_translator().code end,
    get_language_name = localization.language_name,
    language_options = localization.language_options(),
    translate = tr,
    get_skill_name = skill_display_name,
    on_reset = reset_skill_diagnostics,
})
skill_hud:initialize_external()
skill_hud:register_keybinds()

register_hooks()
if hooks.damage and hooks.death then
    schedule_damage_schema_dump()
    schedule_native_drain()
    schedule_cleanup()
    schedule_progress()
    schedule_skill_hud()
end

if rawget(_G, "__BOSS_DPS_TEST") == true then
    _G.BossDPSBroadcastTestApi = {
        config = config,
        metrics = metrics,
        sessions = sessions,
        hooks = hooks,
        queue_size = queue_size,
        drain_events = drain_events,
        drain_native_damage = drain_native_damage,
        cleanup_sessions = cleanup_sessions,
        publish_progress = publish_progress,
        publish_current_skill_hud = publish_current_skill_hud,
        reset_skill_diagnostics = reset_skill_diagnostics,
        skill_display_name = skill_display_name,
        skill_hud = skill_hud,
    }
end
