package.path = "../Scripts/?.lua;" .. package.path

-- Fengari does not expose filesystem writes. The HUD persistence path is
-- exercised here without mutating the developer machine.
io.open = io.open or function()
    return {
        write = function() end,
        close = function() end,
    }
end

local phase = "bootstrap"
local callbacks = {}
local post_callbacks = {}
local game_tasks = {}
local delayed_tasks = {}
local loop_tasks = {}
local delivered = {}
local delivered_by_uid = {}
local chat_call_count = 0
local object_accesses = 0
local localized_name_calls = 0
local nickname_calls = 0
local fake_time = 1000
fake_game_time = 1000

local original_os_time = os.time
os.time = function()
    return fake_time
end

local function require_game_thread(operation)
    assert(phase == "game", operation .. " executed outside the game thread (phase=" .. phase .. ")")
    object_accesses = object_accesses + 1
end

local function object(fields, methods)
    local storage = fields or {}
    local valid = true
    methods = methods or {}

    methods.IsValid = function()
        return valid
    end
    methods.__invalidate = function()
        valid = false
    end

    return setmetatable({}, {
        __index = function(_, key)
            require_game_thread("UObject member " .. tostring(key))
            if methods[key] ~= nil then
                return methods[key]
            end
            return storage[key]
        end,
        __newindex = function(_, key, value)
            require_game_thread("UObject member " .. tostring(key))
            storage[key] = value
        end,
    })
end

local zero_guid = { A = 0, B = 0, C = 0, D = 0 }
local uid_one = { A = 1, B = 2, C = 3, D = 4 }
local uid_two = { A = 5, B = 6, C = 7, D = 8 }
local uid_spectator = { A = 9, B = 10, C = 11, D = 12 }
guild_one_id = { A = 101, B = 102, C = 103, D = 104 }
guild_two_id = { A = 105, B = 106, C = 107, D = 108 }
base_camp_one_id = { A = 201, B = 202, C = 203, D = 204 }

local function test_guid_key(uid)
    return table.concat({ uid.A, uid.B, uid.C, uid.D }, ":")
end

delivered_by_uid[test_guid_key(uid_one)] = delivered
delivered_by_uid[test_guid_key(uid_two)] = {}
delivered_by_uid[test_guid_key(uid_spectator)] = {}

local guild_one = object({ GuildName = "红队" }, {
    GetAddress = function() return 9001 end,
    GetId = function() return guild_one_id end,
})
local guild_two = object({ GuildName = "蓝队" }, {
    GetAddress = function() return 9002 end,
    GetId = function() return guild_two_id end,
})
local player_one_state = object({
    PlayerUId = uid_one,
    PlayerNamePrivate = "Alice",
    GuildBelongTo = guild_one,
}, { GetAddress = function() return 9201 end })
local player_two_state = object({
    PlayerUId = uid_two,
    PlayerNamePrivate = "Bob",
    GuildBelongTo = guild_two,
}, { GetAddress = function() return 9202 end })
local input_look_events = {}
local input_move_events = {}
input_cursor_events = {}
input_controller_action_events = {}
input_pawn_action_events = {}
input_mode_events = {}
native_settings_events = {}
native_settings_text = {}
native_settings_page = nil
native_settings_creation_count = 0
native_ftext_set_count = 0
console_command_callbacks = {}

FText = setmetatable({}, {
    __call = function(_, value)
        local content = tostring(value or "")
        return {
            ToString = function() return content end,
            type = function() return "FText" end,
        }
    end,
})

FName = setmetatable({}, {
    __call = function(_, value)
        local content = tostring(value or "")
        return {
            ToString = function() return content end,
            type = function() return "FName" end,
        }
    end,
})
local_input_pawn = object({}, {
    DisableInput = function()
        input_pawn_action_events[#input_pawn_action_events + 1] = "disable"
    end,
    EnableInput = function()
        input_pawn_action_events[#input_pawn_action_events + 1] = "enable"
    end,
})
local_player_controller_fields = {
    PlayerState = player_one_state,
    bShowMouseCursor = false,
}
local local_player_controller = object(local_player_controller_fields, {
    GetPawn = function()
        return local_input_pawn
    end,
    SetIgnoreLookInput = function(_, value)
        input_look_events[#input_look_events + 1] = value == true
    end,
    SetIgnoreMoveInput = function(_, value)
        input_move_events[#input_move_events + 1] = value == true
    end,
    SetShowMouseCursor = function(_, value)
        local_player_controller_fields.bShowMouseCursor = value == true
        input_cursor_events[#input_cursor_events + 1] = value == true
    end,
    DisableInput = function()
        input_controller_action_events[#input_controller_action_events + 1] = "disable"
    end,
    EnableInput = function()
        input_controller_action_events[#input_controller_action_events + 1] = "enable"
    end,
})

local next_actor_address = 10000

local function actor(name, fields)
    fields = fields or {}
    next_actor_address = next_actor_address + 1
    local address = next_actor_address
    return object(fields, {
        GetAddress = function()
            return address
        end,
        GetName = function()
            return name
        end,
        GetFullName = function()
            return "/Game/Test." .. name
        end,
    })
end

local player_one = actor("BP_Player_C_1", { PlayerState = player_one_state })
local player_two = actor("BP_Player_C_2", { PlayerState = player_two_state })
local player_two_pal_parameter = object({
    SaveParameter = {
        EquipWaza = { 501, 502, 601 },
    },
}, {
    GetAddress = function()
        return 9102
    end,
    GetCharacterID = function()
        return "PinkCat"
    end,
    GetNickname = function(_, out_name)
        nickname_calls = nickname_calls + 1
        out_name.outName = "棉花糖"
    end,
})
local player_two_pal_component = object({
    IndividualParameter = player_two_pal_parameter,
})
local player_two_pal = actor("BP_PinkCat_C_3", {
    CharacterParameterComponent = player_two_pal_component,
})

local function boss_actor(name, extra_fields)
    local component = object({
        IsBoss_Database = true,
        IsTowerBoss_Database = false,
    })
    local fields = extra_fields or {}
    fields.StaticCharacterParameterComponent = component
    return actor(name, fields)
end

local boss = boss_actor("BP_RaidBoss_Test_C_9")
local normal_target = actor("BP_Sheep_C_4", {
    StaticCharacterParameterComponent = object({
        IsBoss_Database = false,
        IsTowerBoss_Database = false,
    }),
})
local world = object()
game_paused = false

native_ui = { named_widgets = {}, reset_count = 0, asset_loaded = false, asset_load_count = 0 }
native_ui.text_widget = function(name)
    local widget = object({}, {
        SetText = function(_, value)
            assert(type(value) == "table" and value:type() == "FText",
                "native settings SetText must receive an FText value")
            native_ftext_set_count = native_ftext_set_count + 1
            native_settings_text[name] = value:ToString()
        end,
    })
    native_ui.named_widgets[name] = widget
    return widget
end

native_ui.switcher = object({}, {
    SetActiveWidgetIndex = function(_, index)
        native_settings_page = index
    end,
})
native_ui.named_widgets.PSDPS_PageSwitcher = native_ui.switcher
native_ui.text_widget("PSDPS_Title")
native_ui.text_widget("PSDPS_Footer")
native_ui.text_widget("PSDPS_GroupRows")
native_ui.text_widget("PSDPS_GroupIntro")
native_ui.text_widget("PSDPS_DetailRows")
native_ui.text_widget("PSDPS_DetailIntro")
native_ui.text_widget("PSDPS_TabSettingsLabel")
native_ui.text_widget("PSDPS_TabGroupsLabel")
native_ui.text_widget("PSDPS_TabDetailsLabel")
for _, key in ipairs({
    "Language",
    "MeasurementMode",
    "TargetScope",
    "IncludePlayerDamage",
    "EnableSkillDPSHUD",
    "HUDAnchor",
    "HUDScale",
    "HUDFinalResultSeconds",
}) do
    native_ui.text_widget("PSDPS_" .. key .. "_Value")
end

native_ui.widget = object(native_ui.named_widgets, {
    GetWidgetFromName = function()
        error("native settings must use exposed Blueprint widget variables")
    end,
    AddToViewport = function(_, z_order)
        assert(z_order == 10000, "native settings must use the intended viewport layer")
        native_settings_events[#native_settings_events + 1] = "add"
    end,
    ActivateWidget = function()
        native_settings_events[#native_settings_events + 1] = "activate"
    end,
    DeactivateWidget = function()
        native_settings_events[#native_settings_events + 1] = "deactivate"
    end,
    RemoveFromParent = function()
        native_settings_events[#native_settings_events + 1] = "remove"
    end,
    SetKeyboardFocus = function()
        native_settings_events[#native_settings_events + 1] = "focus"
    end,
})
native_ui.class = object()
native_ui.asset = object({ GeneratedClass = native_ui.class })
native_ui.widget_library = object({}, {
    Create = function(_, context, widget_class, controller)
        assert(context == world, "native settings used the wrong world")
        assert(widget_class == native_ui.class, "native settings used the wrong widget class")
        assert(controller == local_player_controller, "native settings used the wrong player controller")
        native_settings_creation_count = native_settings_creation_count + 1
        return native_ui.widget
    end,
    SetInputMode_UIOnlyEx = function(_, controller, widget, mouse_lock, flush_input)
        assert(controller == local_player_controller and widget == native_ui.widget,
            "UIOnly input mode did not target the native settings widget")
        assert(mouse_lock == 0 and flush_input == true,
            "UIOnly input mode did not request an unlocked, flushed cursor")
        input_mode_events[#input_mode_events + 1] = "ui"
    end,
    SetInputMode_GameOnly = function(_, controller, flush_input)
        assert(controller == local_player_controller and flush_input == true,
            "GameOnly input restore used the wrong controller/options")
        input_mode_events[#input_mode_events + 1] = "game"
    end,
})

local gameplay_statics = object({}, {
    GetPlayerController = function(_, context, index)
        assert(context == world, "unexpected local-player world context")
        assert(index == 0, "local player must use controller index zero")
        return local_player_controller
    end,
    GetTimeSeconds = function(_, context)
        assert(context == world, "unexpected game-time world context")
        return fake_game_time
    end,
    IsGamePaused = function(_, context)
        assert(context == world, "unexpected pause-state world context")
        return game_paused
    end,
})

local trainer_by_actor = {}
trainer_by_actor[player_two_pal] = player_two

local character_database = object({}, {
    GetLocalizedCharacterName = function(_, character_id, out_text)
        localized_name_calls = localized_name_calls + 1
        local id = tostring(character_id)
        if string.find(id, "Suzaku", 1, true) ~= nil then
            out_text.OutText = "朱雀"
        elseif string.find(id, "DarkScorpion", 1, true) ~= nil then
            out_text.OutText = "冥铠蝎"
        elseif string.find(id, "PinkCat", 1, true) ~= nil then
            out_text.OutText = "捣蛋猫"
        elseif string.find(id, "YakushimaBoss002", 1, true) ~= nil then
            out_text.OutText = "月亮领主"
        end
    end,
})

waza_metadata = {
    [137] = { localized = "暗能弹", cooldown = 2 },
    [501] = { localized = "暗黑球", cooldown = 4 },
    [502] = { localized = "毒雾", cooldown = 30 },
    [601] = { localized = "切割龙息", cooldown = 16 },
    [602] = { localized = "晶钻之雨", cooldown = 22 },
    [42] = { localized = "烈焰球", cooldown = 30 },
    [46] = { localized = "烈焰风暴", cooldown = 12 },
    [54] = { localized = "流火", cooldown = 16 },
}
waza_database = object({}, {
    FindWazaForBP = function(_, waza_id, out_data)
        local metadata = waza_metadata[waza_id]
        if metadata == nil then
            return false
        end
        out_data.CoolTime = metadata.cooldown
        return true
    end,
})
pal_ui_utility = object({}, {
    GetWazaName = function(_, context, waza_id, out_name)
        assert(context == world, "unexpected Waza localization world context")
        local metadata = waza_metadata[waza_id]
        if metadata ~= nil then
            out_name.outName = metadata.localized
        end
    end,
})

local utility = object({}, {
    GetPlayerState = function(_, candidate)
        if candidate == player_one then
            return player_one_state
        elseif candidate == player_two then
            return player_two_state
        end
        return nil
    end,
    GetTrainerPlayer = function(_, candidate)
        return trainer_by_actor[candidate]
    end,
    GetCharacterIDFromCharacter = function(_, candidate)
        return candidate:GetName()
    end,
    GetDatabaseCharacterParameter = function(_, context)
        assert(context == world, "unexpected localization world context")
        return character_database
    end,
    GetWazaDatabase = function(_, context)
        assert(context == world, "unexpected Waza database world context")
        return waza_database
    end,
    SendSystemToPlayerChat = function(_, context, message, receiver_uids)
        assert(context == world, "unexpected world context")
        assert(utf8.len(message) ~= nil, "invalid UTF-8 reached SendSystemToPlayerChat")
        assert(type(receiver_uids) == "table", "receiver parameter must be a TArray-compatible Lua table")
        assert(#receiver_uids > 0, "receiver array must not be empty/global")
        chat_call_count = chat_call_count + 1
        local seen = {}
        for _, receiver_uid in ipairs(receiver_uids) do
            local key = test_guid_key(receiver_uid)
            assert(seen[key] == nil, "duplicate UID inside one receiver array")
            seen[key] = true
            local inbox = delivered_by_uid[key]
            assert(inbox ~= nil, "message sent to unknown receiver")
            inbox[#inbox + 1] = message
        end
    end,
})

-- Legacy report formatter coverage stays inside the offline harness. The
-- shipped runtime has no SendSystemToPlayerChat lookup or call.
_G.__BOSS_DPS_TEST_MESSAGE_SINK = function(messages, recipients)
    if #(recipients or {}) == 0 then return end
    for index, message in ipairs(messages or {}) do
        ExecuteInGameThreadWithDelay(index - 1, function()
            utility:SendSystemToPlayerChat(
                world,
                "[PalSkillDPS] " .. tostring(message),
                recipients
            )
        end)
    end
end

local internationalization_library = object({}, {
    GetCurrentLanguage = function()
        return "zh-Hans-CN"
    end,
    GetLocalizedLanguage = function()
        return "zh"
    end,
})

local waza_names = {
    [137] = "EPalWazaID::GravityShot",
    [501] = "EPalWazaID::DarkBall",
    [502] = "EPalWazaID::PoisonFog",
    [601] = "EPalWazaID::BeamSlicer",
    [602] = "EPalWazaID::DiamondFall",
    [116] = "EPalWazaID::IcicleThrow",
    [186] = "EPalWazaID::DoubleIcicleThrow",
    [205] = "EPalWazaID::Unique_BlackCentaur_TwoSpearRushes",
    [300] = "EPalWazaID::Unique_BlueThunderHorse_Tossin",
    [307] = "EPalWazaID::Unique_MummyPal_MummyAttack",
    [158] = "EPalWazaID::Commet",
    [177] = "EPalWazaID::CommetRain",
    [42] = "EPalWazaID::FireBall",
    [46] = "EPalWazaID::FlareTornado",
    [54] = "EPalWazaID::FlameFunnel",
    [131] = "EPalWazaID::DarkLaser",
    [135] = "EPalWazaID::PoisonShot",
    [161] = "EPalWazaID::DarkLegion",
    [701] = "EPalWazaID::IceAge",
    [702] = "EPalWazaID::Apocalypse",
    [703] = "EPalWazaID::SandTwister",
}
local waza_enum = object({}, {
    GetNameByValue = function(_, value)
        return waza_names[value] or ("EPalWazaID::TestWaza" .. tostring(value))
    end,
})

function StaticFindObject(path)
    require_game_thread("StaticFindObject")
    if path == "/Game/Mods/PalSkillDPSAnalyzerSP/WBP_PalSkillDPSSettings.WBP_PalSkillDPSSettings_C"
        and native_ui.asset_loaded then
        return native_ui.class
    end
    if path == "/Script/UMG.Default__WidgetBlueprintLibrary" then
        return native_ui.widget_library
    end
    if path == "/Script/Pal.Default__PalUtility" then
        return utility
    end
    if path == "/Script/Pal.Default__PalUIUtility" then
        return pal_ui_utility
    end
    if path == "/Script/Engine.Default__GameplayStatics" then
        return gameplay_statics
    end
    if path == "/Script/Engine.Default__KismetInternationalizationLibrary" then
        return internationalization_library
    end
    if path == "/Script/Pal.EPalWazaID" then
        return waza_enum
    end
    error("unexpected StaticFindObject path: " .. tostring(path))
end

function LoadAsset(path)
    require_game_thread("LoadAsset")
    assert(path == "/Game/Mods/PalSkillDPSAnalyzerSP/WBP_PalSkillDPSSettings.WBP_PalSkillDPSSettings",
        "unexpected native settings asset path")
    native_ui.asset_loaded = true
    native_ui.asset_load_count = native_ui.asset_load_count + 1
    return native_ui.asset, true, true
end

function RegisterConsoleCommandHandler(name, callback)
    assert(phase == "bootstrap", "console command handler must register during bootstrap")
    assert(name == "psdps" and type(callback) == "function",
        "unexpected native settings console command registration")
    console_command_callbacks[name] = callback
end

function FindFirstOf(type_name)
    require_game_thread("FindFirstOf")
    assert(type_name == "PalGameStateInGame")
    return world
end

function RegisterHook(path, callback, post_callback)
    assert(phase == "bootstrap" or phase == "game",
        "RegisterHook must run during bootstrap or on the game thread")
    local allowed = {
        ["/Script/Pal.PalEventNotify_Character:OnCharacterDamaged_ServerInternal"] = true,
        ["/Script/Pal.PalCharacterParameterComponent:OnDamage"] = true,
        ["/Script/Pal.PalDamageReactionComponent:MulticastDamageReact"] = true,
        ["/Script/Pal.PalUtility:MakeDamageInfoByWazaType"] = true,
        ["/Script/Pal.PalActionBase:OnBeginAction"] = true,
        ["/Script/Pal.PalActionBase:OnEndAction"] = true,
        ["/Script/Pal.PalSkillEffectBase:OnInitialize"] = true,
        ["/Script/Pal.PalAttackFilter:BindPrimitiveComponent"] = true,
        ["/Script/Pal.PalEventNotify_Character:OnCharacterDead_ServerInternal"] = true,
        ["/Script/Pal.PalUtility:PalCaptureSuccess"] = true,
    }
    if not allowed[path] then
        error("simulated Palworld 1.0: UFunction not found")
    end
    callbacks[path] = callback
    post_callbacks[path] = post_callback
end

function RegisterCustomEvent(name, callback)
    registered_custom_events = registered_custom_events or {}
    registered_custom_events[name] = callback
end

EGameThreadMethod = { EngineTick = 1, ProcessEvent = 2 }
EngineTickAvailable = true
Key = {
    F1 = "F1",
    F2 = "F2",
    F3 = "F3",
    UP_ARROW = "UP",
    DOWN_ARROW = "DOWN",
    LEFT_ARROW = "LEFT",
    RIGHT_ARROW = "RIGHT",
    RETURN = "RETURN",
}
ModifierKey = { CONTROL = "CONTROL" }
key_callbacks = {}

function IsKeyBindRegistered(_, _)
    return false
end

function RegisterKeyBindAsync(key, modifiers, callback)
    assert(phase == "bootstrap", "keybinds must be registered during bootstrap")
    assert(type(modifiers) == "table", "async keybind registration requires a modifier table")
    key_callbacks[key] = callback
end

function ExecuteInGameThread(callback, method)
    assert(phase == "hook" or phase == "game", "unexpected game-thread scheduling phase")
    assert(method == nil or method == EGameThreadMethod.EngineTick)
    game_tasks[#game_tasks + 1] = callback
end

function ExecuteInGameThreadWithDelay(delay, callback)
    assert(phase == "game", "delayed action was not scheduled from the game thread")
    delayed_tasks[#delayed_tasks + 1] = { delay = delay, callback = callback }
    return #delayed_tasks
end

function LoopInGameThreadWithDelay(delay, callback)
    assert(phase == "bootstrap" or phase == "game")
    loop_tasks[#loop_tasks + 1] = { delay = delay, callback = callback }
    return #loop_tasks
end

function ExecuteWithDelay()
    error("deprecated asynchronous ExecuteWithDelay must never be used")
end

local function run_game_tasks(max_tasks)
    local ran = 0
    while #game_tasks > 0 and (max_tasks == nil or ran < max_tasks) do
        local callback = table.remove(game_tasks, 1)
        phase = "game"
        callback()
        phase = "idle"
        ran = ran + 1
    end
    return ran
end

local function run_delayed_tasks()
    table.sort(delayed_tasks, function(a, b)
        return a.delay < b.delay
    end)
    while #delayed_tasks > 0 do
        local task = table.remove(delayed_tasks, 1)
        phase = "game"
        task.callback()
        phase = "idle"
    end
end

local function hook_param(value)
    return {
        get = function()
            assert(phase == "hook", "temporary hook parameter escaped its callback")
            return value
        end,
    }
end

local function damage(attacker, defender, amount, extra_fields)
    local payload = {
        Attacker = attacker,
        Defender = defender,
        ActualDamage = amount,
    }
    for key, value in pairs(extra_fields or {}) do
        payload[key] = value
    end
    phase = "hook"
    local hook = callbacks["/Script/Pal.PalCharacterParameterComponent:OnDamage"]
        or callbacks["/Script/Pal.PalEventNotify_Character:OnCharacterDamaged_ServerInternal"]
    hook(nil, hook_param(payload))
    phase = "idle"
end

local function waza(attacker, defender, waza_id, returned_damage_info)
    phase = "hook"
    callbacks["/Script/Pal.PalUtility:MakeDamageInfoByWazaType"](
        nil,
        hook_param(attacker),
        hook_param(defender),
        hook_param(nil),
        hook_param(nil),
        hook_param(nil),
        hook_param({}),
        hook_param(waza_id)
    )
    local post = post_callbacks["/Script/Pal.PalUtility:MakeDamageInfoByWazaType"]
    if post ~= nil then
        post(
            nil,
            hook_param(returned_damage_info or { WazaID = waza_id }),
            hook_param(attacker),
            hook_param(defender),
            hook_param(nil),
            hook_param(nil),
            hook_param(nil),
            hook_param({}),
            hook_param(waza_id)
        )
    end
    phase = "idle"
end

function action_begin(action)
    phase = "hook"
    callbacks["/Script/Pal.PalActionBase:OnBeginAction"](hook_param(action))
    phase = "idle"
end

function action_end(action)
    phase = "hook"
    callbacks["/Script/Pal.PalActionBase:OnEndAction"](hook_param(action))
    phase = "idle"
end

local function death(dead_actor)
    phase = "hook"
    callbacks["/Script/Pal.PalEventNotify_Character:OnCharacterDead_ServerInternal"](nil, hook_param({
        SelfActor = dead_actor,
    }))
    phase = "idle"
end

local function captured(captured_actor, attacker)
    phase = "hook"
    callbacks["/Script/Pal.PalUtility:PalCaptureSuccess"](
        nil,
        hook_param(attacker),
        hook_param(captured_actor)
    )
    phase = "idle"
end

_G.__BOSS_DPS_TEST = true
dofile("../Scripts/main.lua")
assert(type(_G.__BOSS_DPS_TEST_MESSAGE_SINK) == "function",
    "offline legacy report sink was lost while loading the runtime")

local runtime_config = BossDPSBroadcastTestApi.config
assert(runtime_config.EnableDPSRecording == true, "DPS recording should default to enabled")
assert(runtime_config.EnableSkillDiagnostics == true, "skill diagnostics should default to enabled")
assert(runtime_config.SkillDiagnosticsOnly == true, "diagnostic-only output should default to enabled")
assert(runtime_config.IncludePlayerDamage == false, "player damage should default to disabled")
assert(runtime_config.EnableSkillDPSHUD == true, "skill DPS HUD should default to enabled")
assert(runtime_config.HUDSettingsVersion == 5, "HUD settings schema should be v5")
assert(runtime_config.MeasurementMode == "manual", "damage lab should default to a manual test window")
assert(runtime_config.TargetScope == "field",
    "damage lab should default to the explicit field/dungeon Boss profile")
assert(runtime_config.EnableExternalHUD == true, "external HUD should default to enabled")
assert(runtime_config.ExternalHUDAutoLaunch == true, "external HUD should auto-launch by default")
assert(runtime_config.HUDMaxSourceGroups == 3,
    "live HUD should keep only the three highest-damage source groups")
assert(runtime_config.HUDDetailMode == "compact", "HUD should default to compact combat bars")
assert(runtime_config.HUDShowInternalSkillCode == false,
    "internal skill code should default to hidden")
assert(runtime_config.DumpDamageSchema == false, "schema dump should default to disabled after field discovery")
assert(runtime_config.SkillDiagnosticLogCasts == true,
    "per-cast diagnostic log should default to enabled")
assert(runtime_config.SkillActionMaxEntries >= 128,
    "action lifecycle cache must be bounded")
assert(runtime_config.HUDMaxHitCastSamples == 6,
    "per-cast hit history should default to six visible casts")
assert(runtime_config.SkillPerCastHitMaxEntries == 4096,
    "per-cast hit timestamps should have a bounded diagnostic limit")
assert(type(runtime_config.SkillFullHitCaps) == "table"
    and next(runtime_config.SkillFullHitCaps) == nil,
    "full-hit baselines must start empty instead of guessing from observed hits")
assert(runtime_config.EnableExternalHUDSettings == false,
    "cross-process WPF settings must stay disabled")
assert(runtime_config.EnableNativeCommonUISettings == true,
    "F3 native CommonUI settings should default to enabled")
assert(key_callbacks[Key.F1] == nil, "F1 must remain free for other mods")
assert(type(key_callbacks[Key.F3]) == "function", "F3 HUD settings key was not registered")
assert(type(key_callbacks[Key.F2]) == "function", "F2 damage-test reset key was not registered")
assert(key_callbacks[Key.UP_ARROW] == nil and key_callbacks[Key.DOWN_ARROW] == nil
    and key_callbacks[Key.LEFT_ARROW] == nil and key_callbacks[Key.RIGHT_ARROW] == nil
    and key_callbacks[Key.RETURN] == nil,
    "native mouse settings must not install the obsolete keyboard navigation layer")
assert(type(console_command_callbacks.psdps) == "function",
    "native settings command bridge was not registered")

do
    local casts = {
        { key = "cast-1", started_at = 10, ended_at = 12, damage = 0, hits = 0 },
        { key = "cast-2", started_at = 20, ended_at = 22, damage = 0, hits = 0 },
        { key = "cast-3", started_at = 30, ended_at = 32, damage = 0, hits = 0 },
    }
    local grouped, unassigned =
        BossDPSBroadcastTestApi.group_unlinked_hits_by_cast_window(casts, {
            { at = 5, damage = 7, hits = 1 },
            { at = 11, damage = 20, hits = 2 },
            { at = 21, damage = 30, hits = 3 },
        })
    assert(grouped == 5 and unassigned == 1,
        "same-skill cast windows did not conserve grouped and unassigned hits")
    assert(casts[1].hits == 2 and casts[1].damage == 20,
        "first cast window did not retain its own hits and damage")
    assert(casts[2].hits == 3 and casts[2].damage == 30,
        "second cast window did not retain its own hits and damage")
    assert(casts[3].hits == 0,
        "zero-damage cast must remain distinguishable from a hit cast")

    local quality = BossDPSBroadcastTestApi.cast_hit_quality(casts, 50, true, 4)
    assert(quality.hit_casts == 2 and quality.zero_damage_casts == 1,
        "cast quality did not count effective and zero-damage casts")
    assert(quality.per_cast_hits == "2/3/0" and quality.observed_max_hits == 3,
        "cast quality did not preserve each cast's hit count")
    assert(quality.per_cast_sample_count == 3 and quality.per_cast_total_samples == 3
        and quality.per_cast_samples_truncated == false,
        "cast quality did not expose its settled sample window")
    assert(quality.minimum_hits == 0 and math.abs(quality.average_hits - (5 / 3)) < 0.001
        and quality.maximum_hits == 3,
        "cast quality did not preserve settled min/average/max hits")
    assert(math.abs(quality.hit_completion - (5 / 12 * 100)) < 0.001,
        "calibrated full-hit percentage used the wrong denominator")

    local active = BossDPSBroadcastTestApi.cast_hit_quality({
        { key = "active", started_at = 45, ended_at = nil, damage = 9, hits = 2 },
    }, 50, false, 4)
    assert(active.hit_casts == 1 and active.pending_casts == 1
        and active.per_cast_hits == "" and active.per_cast_total_samples == 0
        and active.hit_completion == nil,
        "active casts must remain visibly unsettled instead of reporting a false miss/full-hit rate")

    local many_casts = {}
    for index = 1, 10 do
        many_casts[#many_casts + 1] = {
            key = "many-" .. tostring(index),
            started_at = index,
            ended_at = index + 0.5,
            damage = index,
            hits = index,
        }
    end
    local recent = BossDPSBroadcastTestApi.cast_hit_quality(many_casts, 50, true, nil)
    assert(recent.per_cast_hits == "5/6/7/8/9/10"
        and recent.per_cast_sample_count == 6 and recent.per_cast_total_samples == 10
        and recent.per_cast_samples_truncated == true,
        "long cast history did not expose an unambiguous recent-sample window")
end

do
    hud_test_phase = phase
    phase = "game"
    runtime_config.Language = "zh-TW"
    assert(runtime_config.HUDUseExperimentalUMG == false,
        "unsafe dynamic UMG backend must be disabled by default")
    assert(runtime_config.HUDUseScreenTextFallback == false,
        "unsafe PrintString backend must be disabled by default")
    local snapshot = {
        state = "active",
        boss = "測試 Boss",
        duration = 20,
        total_damage = 2000,
        encounter_dps = 100,
        include_player = false,
        language = "zh-TW",
        sources = {
            {
                name = "測試帕魯",
                damage = 2000,
                dps = 100,
                hits = 4,
                skills = {
                    {
                        name = "切割龍息",
                        internal_code = "BeamSlicer",
                        damage = 2000,
                        encounter_dps = 100,
                        hits = 4,
                        casts = 2,
                        hit_casts = 2,
                        zero_damage_casts = 0,
                        pending_casts = 0,
                        per_cast_hits = "2/2",
                        per_cast_sample_count = 2,
                        per_cast_total_samples = 2,
                        per_cast_samples_truncated = false,
                        observed_max_hits = 2,
                        minimum_hits = 2,
                        average_hits = 2,
                        maximum_hits = 2,
                        historical_max_hits = 2,
                        full_hit_cap = nil,
                        per_cast_grouping_approximate = false,
                        damage_per_cast = 1000,
                        panel_cd = 16,
                        actual_interval = 20.5,
                        action_duration = 2.5,
                        action_dps = 400,
                        reuse_gap = 18,
                        lifecycle_complete = 2,
                    },
                },
            },
        },
    }
    local hud_header, hud_summary, hud_body, hud_footer =
        BossDPSBroadcastTestApi.skill_hud:format_snapshot(snapshot)
    local original_create_widget = BossDPSBroadcastTestApi.skill_hud.create_widget
    BossDPSBroadcastTestApi.skill_hud.create_widget = function()
        error("experimental UMG path must not run")
    end
    local previous_phase = phase
    phase = "game"
    BossDPSBroadcastTestApi.skill_hud:render_text(hud_header, hud_summary, hud_body, hud_footer)
    phase = previous_phase
    BossDPSBroadcastTestApi.skill_hud.create_widget = original_create_widget
    assert(BossDPSBroadcastTestApi.skill_hud.backend == "external-file",
        "external file-backed HUD was not selected")
    assert(BossDPSBroadcastTestApi.skill_hud.last_external_state.visible == true,
        "external HUD state should be visible after rendering")
    assert(string.find(BossDPSBroadcastTestApi.skill_hud.last_external_state.text,
        "切割龍息", 1, true) ~= nil, "external HUD state did not receive localized text")
    assert(string.find(hud_header, "帕魯技能 DPS", 1, true) ~= nil, "HUD title missing")
    assert(string.find(hud_summary, "總傷害 2,000", 1, true) ~= nil, "HUD encounter summary missing")
    assert(string.find(hud_body, "切割龍息", 1, true) ~= nil,
        "HUD localized skill name missing")
    assert(string.find(hud_body, "BeamSlicer", 1, true) == nil,
        "HUD should hide the internal skill code by default")
    assert(string.find(hud_body, "施放DPS", 1, true) == nil,
        "compact HUD should not show timing diagnostics")
    assert(string.find(hud_footer, "人物傷害 關", 1, true) ~= nil,
        "HUD player-damage state missing")
    BossDPSBroadcastTestApi.skill_hud:publish(snapshot)
    assert(BossDPSBroadcastTestApi.skill_hud.last_external_state.protocol == "PAL_SKILL_DPS_HUD_V2",
        "meter publish should use the structured HUD protocol")
    assert(BossDPSBroadcastTestApi.skill_hud.last_external_state.view == "meter",
        "structured HUD state should select the meter view")
    assert(string.find(BossDPSBroadcastTestApi.skill_hud.last_external_state.text,
        "detail=compact", 1, true) ~= nil, "structured HUD should keep the compact mode")
    assert(string.find(BossDPSBroadcastTestApi.skill_hud.last_external_state.text,
        "\nR\t1\t1\t切割龍息\tBeamSlicer\t", 1, true) ~= nil,
        "structured HUD row did not receive localized skill data")
    assert(string.find(BossDPSBroadcastTestApi.skill_hud.last_external_state.text,
        "\t100.0000\t100.0000\t4\t2\t", 1, true) ~= nil,
        "structured HUD row did not preserve the skill's independent DPS")
    assert(string.find(BossDPSBroadcastTestApi.skill_hud.last_external_state.text,
        "有效 2/2 · 0傷 0", 1, true) ~= nil,
        "structured HUD row did not expose effective and zero-damage casts")
    assert(string.find(BossDPSBroadcastTestApi.skill_hud.last_external_state.text,
        "Hit 4 · 逐次 2/2 · 滿Hit 待校準", 1, true) ~= nil,
        "structured HUD row did not expose per-cast hit counts")

    snapshot.sources[1].skills[#snapshot.sources[1].skills + 1] = {
        name = "暗能彈",
        internal_code = "GravityShot",
        category = "basic",
        damage = 200,
        encounter_dps = 10,
        hits = 2,
        casts = 1,
        hit_casts = 1,
        zero_damage_casts = 0,
        pending_casts = 0,
        per_cast_hits = "2",
        observed_max_hits = 2,
        damage_per_cast = 200,
        panel_cd = 2,
        actual_interval = 3,
        action_duration = 1,
        action_dps = 200,
        reuse_gap = 2,
        lifecycle_complete = 1,
    }
    BossDPSBroadcastTestApi.skill_hud:publish(snapshot)
    assert(string.find(BossDPSBroadcastTestApi.skill_hud.last_external_state.text,
        "\nR\t1\t2\t普攻｜暗能彈\tGravityShot\t200.0000\t10.0000\t", 1, true) ~= nil,
        "basic attack row did not preserve its independent DPS")
    assert(string.find(BossDPSBroadcastTestApi.skill_hud.last_external_state.text,
        "\tbasic\n", 1, true) ~= nil,
        "structured HUD row did not expose the basic-attack category")

    local detail_model = BossDPSBroadcastTestApi.skill_hud:detail_skill({
        casts = 11,
        hit_casts = 5,
        zero_damage_casts = 5,
        pending_casts = 1,
        hits = 5,
        per_cast_hits = "0/0/0/1/1/1",
        per_cast_sample_count = 6,
        per_cast_total_samples = 10,
        per_cast_samples_truncated = true,
        per_cast_grouping_approximate = true,
        minimum_hits = 0,
        average_hits = 0.5,
        maximum_hits = 1,
        historical_max_hits = 1,
    })
    assert(string.find(detail_model.casts_text,
        "施放 11 次｜有傷施放 5｜無傷施放 5｜統計中 1", 1, true) ~= nil
        and string.find(detail_model.hits_text,
            "最近 6 次施放命中段數（估算）：0, 0, 0, 1, 1, 1（共 10 次已結算）", 1, true) ~= nil
        and string.find(detail_model.hits_text, "~", 1, true) == nil
        and string.find(detail_model.range_text, "含無傷施放", 1, true) ~= nil,
        "detail model did not explain pending, estimated, truncated, and zero-damage casts")

    runtime_config.HUDDetailMode = "full"
    local _, _, detailed_body = BossDPSBroadcastTestApi.skill_hud:format_snapshot(snapshot)
    assert(string.find(detailed_body, "施放DPS 400.0", 1, true) ~= nil,
        "full HUD action DPS missing")
    assert(string.find(detailed_body, "實際間隔 20.5秒", 1, true) ~= nil,
        "full HUD observed interval missing")
    BossDPSBroadcastTestApi.skill_hud:publish(snapshot)
    assert(string.find(BossDPSBroadcastTestApi.skill_hud.last_external_state.text,
        "detail=full", 1, true) ~= nil, "structured HUD should expose full diagnostics mode")
    runtime_config.HUDDetailMode = "compact"
    runtime_config.HUDShowInternalSkillCode = true
    local _, _, diagnostic_body = BossDPSBroadcastTestApi.skill_hud:format_snapshot(snapshot)
    assert(string.find(diagnostic_body, "切割龍息 (BeamSlicer)", 1, true) ~= nil,
        "HUD internal skill code toggle is ineffective")
    runtime_config.HUDShowInternalSkillCode = false

    runtime_config.Language = "en"
    local english_header, english_summary, english_body =
        BossDPSBroadcastTestApi.skill_hud:format_snapshot(snapshot)
    assert(string.find(english_header, "PAL SKILL DPS", 1, true) ~= nil,
        "HUD did not switch its interface to English")
    assert(string.find(english_summary, "damage 2,000", 1, true) ~= nil,
        "HUD English summary did not refresh")
    assert(string.find(english_body, "Beam Slicer", 1, true) ~= nil,
        "HUD did not switch the skill name to English")
    assert(string.find(english_body, "切割龍息", 1, true) == nil,
        "HUD retained the previous language's skill name")

    runtime_config.Language = "ja"
    local japanese_lines = BossDPSBroadcastTestApi.skill_hud:settings_lines()
    local _, _, japanese_body = BossDPSBroadcastTestApi.skill_hud:format_snapshot(snapshot)
    assert(string.find(table.concat(japanese_lines, "\n"), "表示言語", 1, true) ~= nil,
        "HUD settings did not switch to Japanese")
    assert(string.find(japanese_body, "ビームスライサー", 1, true) ~= nil,
        "HUD did not switch the skill name to Japanese")
    assert(BossDPSBroadcastTestApi.skill_hud.setting_keys[1] == "reset",
        "Start new test must be the first settings action")
    runtime_config.Language = "zh-TW"
    previous_phase = phase
    phase = "game"
    native_ui.event_count = function(expected)
        local count = 0
        for _, event in ipairs(native_settings_events) do
            if event == expected then count = count + 1 end
        end
        return count
    end
    assert(BossDPSBroadcastTestApi.skill_hud:toggle_settings() == true
        and BossDPSBroadcastTestApi.skill_hud.settings_open == true
        and BossDPSBroadcastTestApi.skill_hud.settings_page == 0,
        "F3 did not open the settings page")
    assert(native_ui.asset_load_count == 1
        and native_settings_creation_count == 1
        and native_ui.event_count("add") == 1
        and native_ui.event_count("activate") == 1
        and native_ui.event_count("focus") == 1,
        "F3 did not create and activate one native settings widget")
    assert(native_settings_page == 0,
        "native settings widget did not select its first page")
    assert(input_mode_events[#input_mode_events] == "ui"
        and input_cursor_events[#input_cursor_events] == true
        and local_player_controller_fields.bShowMouseCursor == true,
        "native settings widget did not acquire UI-only input and a visible cursor")
    assert(BossDPSBroadcastTestApi.skill_hud.last_external_state.visible == false,
        "opening native settings did not hide the display-only DPS meter")
    assert(native_settings_text.PSDPS_Title ~= nil
        and native_settings_text.PSDPS_Title ~= "",
        "native settings title was not populated")
    assert(console_command_callbacks.psdps("psdps", { "ui", "tab", "groups" }) == true,
        "native grouped-percentage tab button command was not accepted")
    run_game_tasks()
    assert(BossDPSBroadcastTestApi.skill_hud.settings_open == true
        and BossDPSBroadcastTestApi.skill_hud.settings_page == 1
        and native_settings_page == 1
        and string.find(native_settings_text.PSDPS_Title or "", "分組百分比", 1, true) ~= nil,
        "native grouped-percentage tab did not switch the existing widget")
    assert(string.find(native_settings_text.PSDPS_GroupRows or "",
        "累計傷害 2,000", 1, true) ~= nil
        and string.find(native_settings_text.PSDPS_GroupRows or "", "個目標", 1, true) == nil
        and string.find(native_settings_text.PSDPS_GroupRows or "",
            "1. 測試帕魯", 1, true) ~= nil
        and string.find(native_settings_text.PSDPS_GroupRows or "",
            "切割龍息  ·  100.0%", 1, true) ~= nil
        and string.find(native_settings_text.PSDPS_GroupRows or "",
            "總命中段數", 1, true) == nil,
        "native grouped-percentage page did not retain the grouped report")

    phase = "game"
    assert(console_command_callbacks.psdps("psdps", { "ui", "tab", "details" }) == true,
        "native details-tab button command was not accepted")
    run_game_tasks()
    assert(BossDPSBroadcastTestApi.skill_hud.settings_open == true
        and BossDPSBroadcastTestApi.skill_hud.settings_page == 2
        and native_settings_page == 2
        and string.find(native_settings_text.PSDPS_Title or "", "本次測試詳情", 1, true) ~= nil,
        "native details-tab button did not switch the existing widget")
    assert(string.find(native_settings_text.PSDPS_DetailRows or "",
            "總命中段數 4｜每次施放命中段數：2, 2", 1, true) ~= nil
        and string.find(native_settings_text.PSDPS_DetailRows or "",
            "每次施放命中段數（含無傷施放）：最低 2.0｜平均 2.0｜最高 2.0", 1, true) ~= nil
        and string.find(native_settings_text.PSDPS_DetailRows or "",
            "本次遊戲最高單次施放 2.0 段｜理論最高命中段數 尚無資料", 1, true) ~= nil,
        "native third page did not retain the original per-Pal hit statistics")

    native_ui.frozen_creation_count = native_settings_creation_count
    native_ui.frozen_add_count = native_ui.event_count("add")
    phase = "game"
    BossDPSBroadcastTestApi.skill_hud:publish(snapshot)
    assert(native_settings_creation_count == native_ui.frozen_creation_count
        and native_ui.event_count("add") == native_ui.frozen_add_count,
        "periodic snapshots rebuilt or re-added the native settings widget")

    native_ui.previous_scale = runtime_config.HUDScale
    native_ui.previous_scale_text = native_settings_text.PSDPS_HUDScale_Value
    phase = "game"
    assert(console_command_callbacks.psdps("psdps", { "ui", "cycle", "HUDScale", "1" }) == true,
        "native setting arrow command was not accepted")
    run_game_tasks()
    assert(runtime_config.HUDScale ~= native_ui.previous_scale
        and native_settings_text.PSDPS_HUDScale_Value ~= nil
        and native_settings_text.PSDPS_HUDScale_Value ~= native_ui.previous_scale_text
        and native_settings_text.PSDPS_HUDScale_Value
            == BossDPSBroadcastTestApi.skill_hud:setting_value_text("HUDScale")
        and native_ftext_set_count > 0,
        "native setting arrow did not update its setting and visible value")

    native_ui.original_reset = BossDPSBroadcastTestApi.skill_hud.on_reset
    BossDPSBroadcastTestApi.skill_hud.on_reset = function()
        native_ui.reset_count = native_ui.reset_count + 1
    end
    phase = "game"
    assert(console_command_callbacks.psdps("psdps", { "ui", "reset" }) == true,
        "native reset button command was not accepted")
    run_game_tasks()
    assert(native_ui.reset_count == 1 and BossDPSBroadcastTestApi.skill_hud.reset_notice ~= "",
        "native reset button did not reset the current test exactly once")
    BossDPSBroadcastTestApi.skill_hud.on_reset = native_ui.original_reset

    phase = "game"
    assert(console_command_callbacks.psdps("psdps", { "ui", "close" }) == true,
        "native close button command was not accepted")
    run_game_tasks()
    assert(BossDPSBroadcastTestApi.skill_hud.settings_open == false
        and native_ui.event_count("deactivate") == 1
        and native_ui.event_count("remove") == 1,
        "native close button did not deactivate and remove the settings widget")
    assert(input_mode_events[#input_mode_events] == "game"
        and input_cursor_events[#input_cursor_events] == false
        and local_player_controller_fields.bShowMouseCursor == false,
        "closing native settings did not restore GameOnly input and hide the cursor")
    assert(#input_look_events == 0 and #input_move_events == 0
        and #input_controller_action_events == 0 and #input_pawn_action_events == 0
        and #input_cursor_events == 2,
        "native settings must not disable the pawn/controller or suppress movement manually")

    local original_hotkey_reset = BossDPSBroadcastTestApi.skill_hud.on_reset
    local hotkey_reset_count = 0
    BossDPSBroadcastTestApi.skill_hud.on_reset = function()
        hotkey_reset_count = hotkey_reset_count + 1
    end
    phase = "game"
    key_callbacks[Key.F2]()
    run_game_tasks()
    assert(hotkey_reset_count == 1,
        "F2 must reset the damage test exactly once without opening an external window")
    -- F2 key auto-repeat (held key) inside the debounce window must not
    -- create/clear the test a second time.
    phase = "game"
    key_callbacks[Key.F2]()
    phase = previous_phase
    run_game_tasks()
    assert(hotkey_reset_count == 1,
        "F2 key auto-repeat was not debounced to a single reset")
    assert(BossDPSBroadcastTestApi.skill_hud.settings_open == false,
        "F2 reset must not open the F3 settings workspace")
    BossDPSBroadcastTestApi.skill_hud.on_reset = original_hotkey_reset

    phase = "game"
    key_callbacks[Key.F3]()
    run_game_tasks()
    assert(BossDPSBroadcastTestApi.skill_hud.settings_open == true
        and native_settings_creation_count == 1
        and native_ui.event_count("add") == 2,
        "F3 did not reopen the same native settings widget")
    phase = "game"
    key_callbacks[Key.F3]()
    run_game_tasks()
    assert(BossDPSBroadcastTestApi.skill_hud.settings_open == false
        and native_ui.event_count("remove") == 2,
        "second F3 press did not close the native settings widget")

    -- Palworld stays the foreground process on its own pause/options screen.
    -- The overlay must use gameplay state rather than process foreground alone.
    game_paused = true
    BossDPSBroadcastTestApi.skill_hud:publish(snapshot)
    assert(BossDPSBroadcastTestApi.skill_hud.last_external_state.visible == false,
        "native pause/options menu did not hide the DPS overlay")
    assert(BossDPSBroadcastTestApi.skill_hud:toggle_settings() == false
        and BossDPSBroadcastTestApi.skill_hud.settings_open == false,
        "F3 workspace opened on a native menu instead of gameplay")
    game_paused = false
    phase = "game"
    local_player_controller.bShowMouseCursor = true
    BossDPSBroadcastTestApi.skill_hud:publish(snapshot)
    assert(BossDPSBroadcastTestApi.skill_hud.last_external_state.visible == false,
        "native cursor menu did not hide the DPS overlay")
    local_player_controller.bShowMouseCursor = false
    BossDPSBroadcastTestApi.skill_hud.gameplay_available = false
    phase = "game"
    BossDPSBroadcastTestApi.skill_hud:sync_gameplay_visibility()
    phase = previous_phase
    assert(BossDPSBroadcastTestApi.skill_hud.last_external_state.visible == true,
        "returning from a native menu did not restore the latest DPS overlay")
    phase = previous_phase
    runtime_config.Language = "auto"
    phase = hud_test_phase
end


-- The strongest link is the DamageInfo object returned by Waza construction
-- and later embedded in the final damage result. It must beat a different
-- current action and support overlapping Waza markers for the same pair.
do
    local info_parameter = object({
        SaveParameter = { EquipWaza = { 602, 501, 502 } },
    })
    local info_component = object({ IndividualParameter = info_parameter })
    local info_current_action = nil
    local info_action_component = object({}, {
        GetCurrentAction = function() return info_current_action end,
    })
    local info_pal = actor("BP_CatVampire_C_5190", {
        CharacterParameterComponent = info_component,
        ActionComponent = info_action_component,
    })
    trainer_by_actor[info_pal] = player_two
    local info_boss = boss_actor("BP_RaidBoss_DamageInfoIdentity_C_5191")
    -- Same primitive fields, different returned DamageInfo instances: a
    -- BasePower/element heuristic cannot distinguish these overlapping casts.
    local diamond_info = { BasePower = 600, AttackElementType = 6 }
    local dark_info = { BasePower = 600, AttackElementType = 6 }
    waza(info_pal, info_boss, 602, diamond_info)
    waza(info_pal, info_boss, 501, dark_info)
    run_game_tasks()
    info_current_action = actor("BP_ActionGravityShot_C_2147005192", {
        GetWazaID = function() return 137 end,
        GetActionCharacter = function() return info_pal end,
    })
    damage(info_pal, info_boss, 88, { DamageInfo = diamond_info })
    run_game_tasks()
    phase = "game"
    BossDPSBroadcastTestApi.publish_current_skill_hud()
    phase = "idle"
    local info_state = BossDPSBroadcastTestApi.skill_hud.last_external_state.text
    assert(string.find(info_state, "晶鑽之雨", 1, true) ~= nil
        or string.find(info_state, "晶钻之雨", 1, true) ~= nil,
        "DamageInfo identity did not return delayed damage to DiamondFall")
    assert(string.find(info_state, "88.0000", 1, true) ~= nil,
        "DamageInfo identity-linked damage amount was not recorded")
    death(info_boss)
    run_game_tasks()
    run_delayed_tasks()
end
-- Most existing scenarios also exercise the enabled commentary branches.
-- They verify the inherited BossDPS core, so opt back into legacy output for
-- those scenarios. Dedicated diagnostics cases below test the new defaults.
runtime_config.SkillDiagnosticsOnly = false
runtime_config.IncludePlayerDamage = true
runtime_config.EnableFunComments = true
runtime_config.BroadcastStart = true
runtime_config.EnableProgressReports = true
runtime_config.ProgressIntervalSeconds = 10
runtime_config.ProgressMaxRows = 4
runtime_config.EnableDetailedAwards = true
runtime_config.EnableTeamDetails = true
runtime_config.MaxResultRows = 10
runtime_config.TeamDetailMaxRows = 12
runtime_config.ShowDPS = true
runtime_config.MarkTopAsMVP = true
runtime_config.MeasurementMode = "target"
runtime_config.TargetScope = "field"
phase = "game"
BossDPSBroadcastTestApi.reset_skill_diagnostics()
phase = "idle"

local commentary = require("commentary")
local commentary_base = {
    key = "template-test",
    guild = "测试公会",
    player = "测试玩家",
    runnerup = "追榜玩家",
    pal = "测试帕鲁",
    boss = "测试Boss",
    total = 50000,
    previous_total = 40000,
    window_damage = 10000,
    current_dps = 1000,
    previous_dps = 1000,
    top_share = 50,
    second_share = 40,
    team_dps = 1000,
    duration = 10,
    window_index = 1,
    reason = "defeated",
}
local function commentary_case(overrides, final)
    local stats = {}
    for key, value in pairs(commentary_base) do
        stats[key] = value
    end
    for key, value in pairs(overrides) do
        stats[key] = value
    end
    local result = final and commentary.final(stats) or commentary.progress(stats)
    assert(result ~= nil, "commentary branch did not produce text")
    assert(string.find(result, "{", 1, true) == nil, "unrendered commentary placeholder")
    assert(string.find(result, "测试公会", 1, true) ~= nil
        or string.find(result, "测试玩家", 1, true) ~= nil,
        "commentary did not use live guild/player data")
end

commentary_case({ current_dps = 1000000 }, false)
commentary_case({ total = 1000000, previous_total = 900000 }, false)
commentary_case({ current_dps = 100000 }, false)
commentary_case({ current_dps = 20000, previous_dps = 5000 }, false)
commentary_case({ total = 20000, top_share = 90 }, false)
commentary_case({ reason = "timeout" }, true)
commentary_case({ reason = "captured" }, true)
commentary_case({ duration = 2 }, true)
commentary_case({ total = 1000000 }, true)
commentary_case({ team_dps = 100000 }, true)
commentary_case({ top_share = 51, second_share = 49 }, true)
commentary_case({ total = 20000, top_share = 90, second_share = 0 }, true)
commentary_case({}, true)

local damage_hook = callbacks["/Script/Pal.PalCharacterParameterComponent:OnDamage"]
    or callbacks["/Script/Pal.PalEventNotify_Character:OnCharacterDamaged_ServerInternal"]
local waza_hook = callbacks["/Script/Pal.PalUtility:MakeDamageInfoByWazaType"]
local death_hook = callbacks["/Script/Pal.PalEventNotify_Character:OnCharacterDead_ServerInternal"]
local captured_hook = callbacks["/Script/Pal.PalUtility:PalCaptureSuccess"]
assert(damage_hook ~= nil, "damage hook was not registered")
assert(callbacks["/Script/Pal.PalCharacterParameterComponent:OnDamage"] ~= nil,
    "Palworld final-damage hook was not selected")
assert(waza_hook ~= nil, "Waza attribution hook was not registered")
assert(post_callbacks["/Script/Pal.PalUtility:MakeDamageInfoByWazaType"] ~= nil,
    "Waza attribution post-hook with ReturnValue was not registered")
assert(callbacks["/Script/Pal.PalActionBase:OnBeginAction"] ~= nil
    and callbacks["/Script/Pal.PalActionBase:OnEndAction"] ~= nil,
    "action lifecycle hooks were not registered")
assert(death_hook ~= nil, "death hook was not registered")
assert(captured_hook ~= nil, "capture hook was not registered")
assert(#loop_tasks == 2, "cleanup and HUD loops were not configured")
local loop_delays = {
    [loop_tasks[1].delay] = true,
    [loop_tasks[2].delay] = true,
}
assert(loop_delays[10000] and loop_delays[500], "unexpected loop delays")

-- The master DPS switch must suppress event capture, sessions, and messages.
local disabled_boss = boss_actor("BP_RaidBoss_Disabled_C_30")
runtime_config.EnableDPSRecording = false
local accepted_before_disabled = BossDPSBroadcastTestApi.metrics.accepted
local delivered_before_disabled = #delivered
damage(player_one, disabled_boss, 999)
death(disabled_boss)
captured(disabled_boss, player_one)
assert(BossDPSBroadcastTestApi.metrics.accepted == accepted_before_disabled,
    "disabled DPS recording still accepted events")
assert(BossDPSBroadcastTestApi.queue_size() == 0,
    "disabled DPS recording queued events")
assert(#game_tasks == 0, "disabled DPS recording scheduled game-thread work")
run_delayed_tasks()
assert(#delivered == delivered_before_disabled,
    "disabled DPS recording sent a report")
runtime_config.EnableDPSRecording = true

-- Thread-affinity and event-struct lifetime: hook phase may only copy fields.
local accesses_before_hook = object_accesses
damage(player_one, boss, 600)
assert(object_accesses == accesses_before_hook, "damage hook touched a UObject")
assert(#game_tasks == 1, "damage drain was not coalesced")
assert(#delivered == 0, "damage hook broadcast synchronously")
assert(BossDPSBroadcastTestApi.queue_size() == 1)

damage(player_two_pal, boss, 400)
damage(player_one, normal_target, 999)
damage(player_one, boss, -12)
damage(player_one, boss, 0 / 0)
death(boss)
assert(#game_tasks == 1, "multiple hits should share one scheduled drain")
run_game_tasks()
assert(BossDPSBroadcastTestApi.queue_size() == 0)
assert(#delivered == 0, "participant messages must use the delayed message pump")
run_delayed_tasks()

local joined = table.concat(delivered, "\n")
assert(string.find(joined, "团队伤害 1,000", 1, true) ~= nil, "team total missing")
assert(string.find(joined, "Alice｜伤害 600｜60.0%", 1, true) ~= nil, "Alice result missing")
assert(string.find(joined, "Bob｜伤害 400｜40.0%", 1, true) ~= nil, "Pal owner attribution missing")
assert(string.find(joined, "最高伤害队伍：红队｜伤害 600", 1, true) ~= nil, "team MVP missing")
assert(string.find(joined, "最高伤害玩家角色：Alice｜伤害 600", 1, true) ~= nil, "player MVP missing")
assert(string.find(joined, "最高伤害帕鲁：棉花糖（捣蛋猫）｜训练家 Bob｜伤害 400", 1, true) ~= nil, "Pal MVP or nickname priority missing")
assert(string.find(joined, "战斗点评：", 1, true) ~= nil, "mandatory final comment missing")
assert(string.find(joined, "队内私报：红队｜伤害 600", 1, true) ~= nil, "red team private detail missing")
assert(string.find(joined, "Alice（玩家角色）｜伤害 600｜100.0%", 1, true) ~= nil)
local bob_first_joined = table.concat(delivered_by_uid[test_guid_key(uid_two)], "\n")
assert(string.find(bob_first_joined, "开始统计", 1, true) == nil, "late participant received the start line")
assert(string.find(bob_first_joined, "队内私报：蓝队｜伤害 400", 1, true) ~= nil)
assert(string.find(bob_first_joined, "棉花糖（捣蛋猫）［Bob］｜伤害 400｜100.0%", 1, true) ~= nil)
assert(#delivered_by_uid[test_guid_key(uid_spectator)] == 0, "spectator received a battle message")

local function count_plain(haystack, needle)
    local count = 0
    local offset = 1
    while true do
        local found = string.find(haystack, needle, offset, true)
        if found == nil then
            return count
        end
        count = count + 1
        offset = found + #needle
    end
end

assert(count_plain(joined, "#1 Alice｜伤害 600｜60.0%") == 1,
    "Alice received a shared ranking line more than once")
assert(count_plain(bob_first_joined, "#1 Alice｜伤害 600｜60.0%") == 1,
    "Bob received a shared ranking line more than once")
assert(chat_call_count > 0, "private chat UFunction was never called")

-- Duplicate deaths must be idempotent.
local delivered_before_duplicate = #delivered
death(boss)
run_game_tasks()
run_delayed_tasks()
assert(#delivered == delivered_before_duplicate, "duplicate death published another result")

-- Capture is a completion path distinct from death. PalCaptureSuccess passes
-- the player first and the captured monster second; the latter may become
-- invalid before the queued finish event reaches the game thread.
local captured_boss = boss_actor("BP_Suzaku_BOSS_C_10")
damage(player_one, captured_boss, 700)
damage(player_two_pal, captured_boss, 300)
run_game_tasks()
local accesses_before_capture = object_accesses
captured(captured_boss, player_one)
assert(object_accesses == accesses_before_capture, "capture hook touched a UObject")
phase = "game"
captured_boss:__invalidate()
phase = "idle"
run_game_tasks()
run_delayed_tasks()
joined = table.concat(delivered, "\n")
assert(string.find(joined, "朱雀 已捕捉！团队伤害 1,000", 1, true) ~= nil, "capture result missing")
assert(string.find(joined, "Alice｜伤害 700｜70.0%", 1, true) ~= nil)
assert(string.find(joined, "Bob｜伤害 300｜30.0%", 1, true) ~= nil)

-- Live reports use a rolling 10-second window while totals and percentages
-- remain encounter-wide. Only contributors receive either line.
local progress_boss = boss_actor("BP_DarkScorpion_BOSS_C_17")
local alice_before_progress = #delivered
local bob_inbox = delivered_by_uid[test_guid_key(uid_two)]
local bob_before_progress = #bob_inbox
damage(player_one, progress_boss, 600)
damage(player_two_pal, progress_boss, 400)
run_game_tasks()
run_delayed_tasks()
fake_time = fake_time + 10
phase = "game"
BossDPSBroadcastTestApi.publish_progress()
phase = "idle"
run_delayed_tasks()
local progress_messages = {}
for index = alice_before_progress + 1, #delivered do
    progress_messages[#progress_messages + 1] = delivered[index]
end
local progress_joined = table.concat(progress_messages, "\n")
assert(string.find(progress_joined, "实时战况：冥铠蝎｜总伤害 1,000｜当前DPS 100", 1, true) ~= nil)
assert(string.find(progress_joined, "Alice 600(60.0%/60DPS)", 1, true) ~= nil)
assert(string.find(progress_joined, "Bob 400(40.0%/40DPS)", 1, true) ~= nil)
assert(#bob_inbox > bob_before_progress, "participant Bob did not receive live progress")
assert(#delivered_by_uid[test_guid_key(uid_spectator)] == 0, "spectator received live progress")

local alice_before_second_window = #delivered
damage(player_two_pal, progress_boss, 500)
run_game_tasks()
fake_time = fake_time + 10
phase = "game"
BossDPSBroadcastTestApi.publish_progress()
phase = "idle"
run_delayed_tasks()
local second_window = {}
for index = alice_before_second_window + 1, #delivered do
    second_window[#second_window + 1] = delivered[index]
end
local second_joined = table.concat(second_window, "\n")
assert(string.find(second_joined, "总伤害 1,500｜当前DPS 50", 1, true) ~= nil)
assert(string.find(second_joined, "Bob 900(60.0%/50DPS)", 1, true) ~= nil)
assert(string.find(second_joined, "Alice 600(40.0%/0DPS)", 1, true) ~= nil)
death(progress_boss)
run_game_tasks()
run_delayed_tasks()

-- Mounted Pal skills can report the player as Attacker. DamageCauser ownership
-- must recover the concrete Pal, while a player-owned weapon stays direct.
local mounted_boss = boss_actor("BP_RaidBoss_Mounted_C_18")
local pal_skill_projectile = actor("BP_PalSkillProjectile_C_19", { Owner = player_two_pal })
local player_weapon = actor("BP_PlayerWeapon_C_20", { Owner = player_two })
local mounted_before = #bob_inbox
damage(player_two, mounted_boss, 500, { DamageCauser = pal_skill_projectile })
damage(player_two, mounted_boss, 200, { DamageCauser = player_weapon })
death(mounted_boss)
run_game_tasks()
run_delayed_tasks()
local mounted_messages = {}
for index = mounted_before + 1, #bob_inbox do
    mounted_messages[#mounted_messages + 1] = bob_inbox[index]
end
local mounted_joined = table.concat(mounted_messages, "\n")
assert(string.find(mounted_joined, "最高伤害帕鲁：棉花糖（捣蛋猫）｜训练家 Bob｜伤害 500", 1, true) ~= nil, "mounted Pal skill was attributed to player")
assert(string.find(mounted_joined, "最高伤害玩家角色：Bob｜伤害 200", 1, true) ~= nil, "mounted player weapon was attributed to Pal")
assert(string.find(mounted_joined, "棉花糖（捣蛋猫）［Bob］｜伤害 500｜71.4%", 1, true) ~= nil)
assert(string.find(mounted_joined, "Bob（玩家角色）｜伤害 200｜28.6%", 1, true) ~= nil)
assert(string.find(mounted_joined, "最高伤害队伍", 1, true) == nil, "single-team fight printed a redundant team winner")
assert(string.find(mounted_joined, "击杀播报：Bob 击败了 RaidBoss_Mounted", 1, true) ~= nil, "player final blow announcement missing")

-- Standalone diagnostics mode treats each Pal or optional player character as
-- an independent verification source. Player damage is off by default; raw
-- candidate metadata separates skill/weapon buckets without inventing names.
runtime_config.SkillDiagnosticsOnly = true
runtime_config.IncludePlayerDamage = false
runtime_config.BroadcastStart = false
runtime_config.SkillDiagnosticChatMode = "full"
local diagnostic_boss = boss_actor("BP_RaidBoss_Diagnostic_C_180")
local poison_projectile = actor("BP_PoisonFogProjectile_C_181", { Owner = player_two_pal })
local rifle_projectile = actor("BP_AssaultRifleBullet_C_182", { Owner = player_one })
local ignored_before = BossDPSBroadcastTestApi.metrics.ignored_player_damage
damage(player_one, diagnostic_boss, 200, {
    DamageCauser = rifle_projectile,
    DamageInfo = { WeaponType = "AssaultRifle" },
})
waza(player_two_pal, diagnostic_boss, 501)
damage(player_two_pal, diagnostic_boss, 250, {
    BasePower = 80,
    AttackElementType = 8,
})
waza(player_two_pal, diagnostic_boss, 501)
damage(player_two_pal, diagnostic_boss, 350, {
    BasePower = 80,
    AttackElementType = 8,
})
waza(player_two_pal, diagnostic_boss, 502)
damage(player_two_pal, diagnostic_boss, 300, {
    BasePower = 100,
    AttackElementType = 8,
})
run_game_tasks()
fake_time = fake_time + runtime_config.SkillMarkerTTLSeconds + 1
damage(player_two_pal, diagnostic_boss, 100, {
    BasePower = 30,
    AttackElementType = 1,
})
run_game_tasks()
local diagnostic_session
for _, candidate in pairs(BossDPSBroadcastTestApi.sessions) do
    if candidate.name == "RaidBoss_Diagnostic" then
        diagnostic_session = candidate
        break
    end
end
assert(diagnostic_session ~= nil, "Pal diagnostic session was not created")
assert(diagnostic_session.total_damage == 1000, "disabled player damage entered diagnostic total")
assert(BossDPSBroadcastTestApi.metrics.ignored_player_damage - ignored_before == 1,
    "disabled player damage was not counted as ignored")
local diagnostic_source
local diagnostic_source_count = 0
for _, source in pairs(diagnostic_session.diagnostic_sources) do
    diagnostic_source = source
    diagnostic_source_count = diagnostic_source_count + 1
end
assert(diagnostic_source_count == 1 and diagnostic_source.kind == "pal",
    "Pal-only diagnostics created an unexpected source")
local diagnostic_candidate_count = 0
local unresolved_dark_ball_candidate
for _, candidate in pairs(diagnostic_source.skill_candidates) do
    diagnostic_candidate_count = diagnostic_candidate_count + 1
    if candidate.name == "UNRESOLVED_PAL_ATTACK_BP_80_ELEMENT_8" then
        unresolved_dark_ball_candidate = candidate
    end
end
assert(diagnostic_candidate_count == 3, "Pal skill candidates were not separated")
assert(unresolved_dark_ball_candidate ~= nil
        and unresolved_dark_ball_candidate.damage == 600
        and unresolved_dark_ball_candidate.hits == 2,
    "weak Waza markers did not fail closed into one unresolved signature")
local bob_before_diagnostic_finish = #bob_inbox
death(diagnostic_boss)
run_game_tasks()
run_delayed_tasks()
assert(#bob_inbox == bob_before_diagnostic_finish,
    "diagnostic-only mode must not emit in-game chat")

-- Real Palworld action Blueprints append a new UObject instance number to
-- every cast. Repeated casts must share one stable skill bucket. A generic
-- ActionDamage tick may join a skill only when BasePower+element identifies
-- exactly one concrete skill in the completed encounter.
local current_action = nil
local action_component = object({}, {
    GetCurrentAction = function()
        return current_action
    end,
})
local action_pal = actor("BP_PinkCat_C_184", {
    CharacterParameterComponent = player_two_pal_component,
    ActionComponent = action_component,
})
trainer_by_actor[action_pal] = player_two
local action_boss = boss_actor("BP_RaidBoss_ActionDiagnostic_C_185")
local action_before = #bob_inbox

fake_game_time = 2000
current_action = actor("BP_ActionBeamSlicer_C_2147000001", {
    GetWazaID = function() return 601 end,
    GetActionCharacter = function() return action_pal end,
})
action_begin(current_action)
run_game_tasks()
fake_game_time = 2001
damage(action_pal, action_boss, 300, { BasePower = 350, AttackElementType = 9 })
run_game_tasks()
fake_game_time = 2002
action_end(current_action)
run_game_tasks()

fake_game_time = 2020
current_action = actor("BP_ActionBeamSlicer_C_2147000002", {
    GetWazaID = function() return 601 end,
    GetActionCharacter = function() return action_pal end,
})
action_begin(current_action)
run_game_tasks()
fake_game_time = 2021
damage(action_pal, action_boss, 200, { BasePower = 350, AttackElementType = 9 })
run_game_tasks()
fake_game_time = 2022
action_end(current_action)
run_game_tasks()

-- A cast can be fully swallowed by boss invulnerability/HP lock or miss every
-- projectile. It must remain visible as an observed equipped skill with DMG 0
-- instead of disappearing from the three-skill comparison.
fake_game_time = 2025
current_action = actor("BP_ActionDarkBall_C_2147000005", {
    GetWazaID = function() return 501 end,
    GetActionCharacter = function() return action_pal end,
})
action_begin(current_action)
run_game_tasks()
fake_game_time = 2026
action_end(current_action)
run_game_tasks()

current_action = actor("BP_ActionFlareTornado_C_2147000003")
damage(action_pal, action_boss, 100, { BasePower = 200, AttackElementType = 2 })
run_game_tasks()
current_action = actor("BP_ActionDamage_C_2147000004")
damage(action_pal, action_boss, 50, { BasePower = 200, AttackElementType = 2 })
run_game_tasks()
current_action = nil
fake_game_time = 2040
damage(action_pal, action_boss, 25, { BasePower = 350, AttackElementType = 9 })
run_game_tasks()
damage(action_pal, action_boss, 25, { BasePower = 200, AttackElementType = 9 })
run_game_tasks()

local action_session
for _, candidate in pairs(BossDPSBroadcastTestApi.sessions) do
    if candidate.name == "RaidBoss_ActionDiagnostic" then
        action_session = candidate
        break
    end
end
assert(action_session ~= nil and action_session.total_damage == 700,
    "action diagnostic session total is incorrect")
local action_source
for _, source in pairs(action_session.diagnostic_sources) do
    action_source = source
end
local action_candidate_count = 0
local inferred_beam_candidate
for _, candidate in pairs(action_source.skill_candidates) do
    action_candidate_count = action_candidate_count + 1
    if candidate.name == "BeamSlicer" then
        inferred_beam_candidate = candidate
    end
end
assert(action_candidate_count == 4,
    "bounded action evidence produced an unexpected candidate count")
assert(inferred_beam_candidate ~= nil
        and inferred_beam_candidate.damage == 500
        and inferred_beam_candidate.hits == 2
        and inferred_beam_candidate.confidence == "inferred"
        and inferred_beam_candidate.exact_damage == 0
        and inferred_beam_candidate.inferred_damage == 500,
    "active equipped casts were not kept in one inferred skill bucket")
assert(action_source.skill_candidates["UNRESOLVED_PAL_ATTACK_BP_350_ELEMENT_9"] ~= nil
        and action_source.skill_candidates["UNRESOLVED_PAL_ATTACK_BP_350_ELEMENT_9"].damage == 25,
    "an out-of-window hit was guessed from stale action timing")

do
    phase = "game"
    BossDPSBroadcastTestApi.publish_current_skill_hud()
    phase = "idle"
    local live_action_state = BossDPSBroadcastTestApi.skill_hud.last_external_state
    assert(live_action_state ~= nil and live_action_state.text ~= nil,
        "live HUD state was not published")
    assert(string.find(live_action_state.text, "切割龙息", 1, true) ~= nil,
        "live HUD did not show the inferred active equipped skill")
    assert(string.find(live_action_state.text,
        "\tDarkBall\t0.0000\t0.0000\t0.0000\t0\t1\t", 1, true) ~= nil,
        "an observed equipped cast with zero effective damage disappeared from the HUD")
    assert(string.find(live_action_state.text,
        "\t未归属伤害\tUNRESOLVED_PAL_ATTACK_BP_200_ELEMENT_9\t", 1, true) ~= nil,
        "ambiguous damage did not hide its internal identifier from the visible label")
end

death(action_boss)
run_game_tasks()
run_delayed_tasks()
assert(#bob_inbox == action_before,
    "action diagnostics must remain HUD/F3-only")

-- Many Pal skills deal their first damage only after the action has ended.
-- Action timing alone is diagnostic context and must fail closed; only the
-- later asset-backed hits may enter the confirmed DiamondFall bucket.
do
    local delayed_parameter = object({
        SaveParameter = { EquipWaza = { 602, 501, 502 } },
    })
    local delayed_component = object({ IndividualParameter = delayed_parameter })
    local delayed_current_action = nil
    local delayed_action_component = object({}, {
        GetCurrentAction = function() return delayed_current_action end,
    })
    local delayed_pal = actor("BP_CatVampire_C_190", {
        CharacterParameterComponent = delayed_component,
        ActionComponent = delayed_action_component,
    })
    trainer_by_actor[delayed_pal] = player_two
    local delayed_boss = boss_actor("BP_RaidBoss_DelayedRain_C_191")
    fake_game_time = 2060
    delayed_current_action = actor("BP_ActionDiamondFall_C_2147000006", {
        GetWazaID = function() return 602 end,
        GetActionCharacter = function() return delayed_pal end,
    })
    action_begin(delayed_current_action)
    run_game_tasks()
    fake_game_time = 2062
    action_end(delayed_current_action)
    run_game_tasks()
    -- Recorded regression: GravityShot may already be current when a
    -- DiamondFall shard lands. Because GravityShot is not one of this Pal's
    -- three equipped skills, it must not steal the delayed equipped-skill hit.
    delayed_current_action = actor("BP_ActionGravityShot_C_2147000098", {
        GetWazaID = function() return 137 end,
        GetActionCharacter = function() return delayed_pal end,
    })
    fake_game_time = 2064
    damage(delayed_pal, delayed_boss, 40, { BasePower = 600, AttackElementType = 6 })
    run_game_tasks()
    -- A movement action is also timing context rather than a damage skill.
    delayed_current_action = actor("BP_PalAction_AnimationStepRight_C_2147000099", {
        GetWazaID = function() return 0 end,
        GetActionCharacter = function() return delayed_pal end,
    })
    fake_game_time = 2064.8
    damage(delayed_pal, delayed_boss, 36, { BasePower = 600, AttackElementType = 6 })
    run_game_tasks()
    phase = "game"
    BossDPSBroadcastTestApi.publish_current_skill_hud()
    phase = "idle"
    local delayed_state = BossDPSBroadcastTestApi.skill_hud.last_external_state
    assert(string.find(delayed_state.text, "晶钻之雨", 1, true) ~= nil
        and string.find(delayed_state.text, "76.0000", 1, true) ~= nil,
        "unique equipped signature did not recover delayed DiamondFall hits")
    assert(string.find(delayed_state.text, "AnimationStep", 1, true) == nil,
        "a movement action was exposed as a damage skill")

    fake_game_time = 2070
    delayed_current_action = actor("BP_ActionDarkBall_C_2147000007", {
        GetWazaID = function() return 501 end,
        GetActionCharacter = function() return delayed_pal end,
    })
    action_begin(delayed_current_action)
    run_game_tasks()
    fake_game_time = 2071
    action_end(delayed_current_action)
    run_game_tasks()
    fake_game_time = 2071.2
    delayed_current_action = actor("BP_ActionPoisonFog_C_2147000008", {
        GetWazaID = function() return 502 end,
        GetActionCharacter = function() return delayed_pal end,
    })
    action_begin(delayed_current_action)
    run_game_tasks()
    fake_game_time = 2071.5
    action_end(delayed_current_action)
    run_game_tasks()
    delayed_current_action = nil
    fake_game_time = 2072
    damage(delayed_pal, delayed_boss, 10, { BasePower = 999, AttackElementType = 8 })
    run_game_tasks()
    phase = "game"
    BossDPSBroadcastTestApi.publish_current_skill_hud()
    phase = "idle"
    assert(string.find(BossDPSBroadcastTestApi.skill_hud.last_external_state.text,
        "未归属伤害", 1, true) ~= nil,
        "two equally plausible recent actions should remain unattributed")

    -- Cooked Blueprint evidence is stronger than the Pal's current action:
    -- DiamondFall_Fall and DiamondFall_Explode both declare DiamondFall at
    -- power rate 0.05, and the Fall actor spawns Explode with the same Owner.
    fake_game_time = 2073
    delayed_current_action = actor("BP_ActionDarkBall_C_2147000009", {
        GetWazaID = function() return 501 end,
        GetActionCharacter = function() return delayed_pal end,
    })
    local diamond_fall_causer = actor("BP_SkillEffect_DiamondFall_Fall_C_2147000100")
    local diamond_explode_causer = actor("BP_SkillEffect_DiamondFall_Explode_C_2147000101")
    damage(delayed_pal, delayed_boss, 31, {
        DamageCauser = diamond_fall_causer,
        BasePower = 600,
        AttackElementType = 6,
    })
    damage(delayed_pal, delayed_boss, 29, {
        DamageCauser = diamond_explode_causer,
        BasePower = 600,
        AttackElementType = 6,
    })
    run_game_tasks()
    phase = "game"
    BossDPSBroadcastTestApi.publish_current_skill_hud()
    phase = "idle"
    local asset_state = BossDPSBroadcastTestApi.skill_hud.last_external_state.text
    assert(string.find(asset_state, "晶钻之雨", 1, true) ~= nil
        and string.find(asset_state, "136.0000", 1, true) ~= nil,
        "asset-backed DiamondFall phases did not share one confirmed skill bucket")
    assert(string.find(asset_state, "SkillEffect_DiamondFall", 1, true) == nil,
        "DiamondFall phases leaked into separate visible skill rows")
    death(delayed_boss)
    run_game_tasks()
    run_delayed_tasks()
end

-- Fire regression: verified signatures unique among the live three slots are
-- useful bounded evidence, while the non-equipped filler becomes a basic hit.
do
    local fire_parameter = object({
        SaveParameter = { EquipWaza = { 42, 54, 46 } },
    }, {
        GetAddress = function() return 9401 end,
        GetCharacterID = function() return "CatVampire" end,
        GetNickname = function(_, out_name)
            out_name.outName = "火系測試帕魯"
        end,
    })
    local fire_component = object({ IndividualParameter = fire_parameter })
    local fire_current_action = nil
    local fire_action_component = object({}, {
        GetCurrentAction = function() return fire_current_action end,
    })
    local fire_pal = actor("BP_CatVampire_C_194", {
        CharacterParameterComponent = fire_component,
        ActionComponent = fire_action_component,
    })
    trainer_by_actor[fire_pal] = player_two
    local fire_boss = boss_actor("BP_RaidBoss_FireSignature_C_195")

    -- First accepted hit opens the session and captures the current loadout.
    -- The following omitted-Waza events must then classify immediately.
    fake_game_time = 2080
    fire_current_action = actor("BP_ActionFireBall_C_2147000100", {
        GetWazaID = function() return 42 end,
        GetActionCharacter = function() return fire_pal end,
    })
    damage(fire_pal, fire_boss, 600, { BasePower = 600, AttackElementType = 2 })
    run_game_tasks()
    fire_current_action = nil
    damage(fire_pal, fire_boss, 300, { BasePower = 300, AttackElementType = 2 })
    damage(fire_pal, fire_boss, 200, { BasePower = 200, AttackElementType = 2 })
    run_game_tasks()

    fake_game_time = 2085
    fire_current_action = actor("BP_ActionFlareTornado_C_2147000102", {
        GetWazaID = function() return 46 end,
        GetActionCharacter = function() return fire_pal end,
    })
    action_begin(fire_current_action)
    run_game_tasks()
    fake_game_time = 2086
    action_end(fire_current_action)
    run_game_tasks()
    fire_current_action = actor("BP_ActionGravityShot_C_2147000103", {
        GetWazaID = function() return 137 end,
        GetActionCharacter = function() return fire_pal end,
    })
    fake_game_time = 2087
    damage(fire_pal, fire_boss, 40, { BasePower = 40, AttackElementType = 8 })
    run_game_tasks()

    local fire_session
    for _, candidate_session in pairs(BossDPSBroadcastTestApi.sessions) do
        if candidate_session.name == "RaidBoss_FireSignature" then
            fire_session = candidate_session
            break
        end
    end
    assert(fire_session ~= nil and fire_session.total_damage == 1140,
        "fire signature fixture total is incorrect")
    local fire_source = fire_session.diagnostic_sources["pal:9401"]
    assert(fire_source ~= nil, "fire signature Pal source missing")
    for signature, expected in pairs({
        ["skill:FireBall"] = 600,
        ["skill:FlameFunnel"] = 300,
        ["skill:FlareTornado"] = 200,
        ["skill:GravityShot"] = 40,
    }) do
        assert(fire_source.skill_candidates[signature] ~= nil
            and fire_source.skill_candidates[signature].damage == expected
            and fire_source.skill_candidates[signature].confidence == "inferred",
            "bounded fire/current-action inference failed: " .. signature)
    end
    death(fire_boss)
    run_game_tasks()
    run_delayed_tasks()
    fire_current_action = nil
end

-- Dark regression: each equipped skill has a distinct verified signature;
-- GravityShot remains a non-equipped basic attack.
do
    local dark_parameter = object({
        SaveParameter = { EquipWaza = { 131, 161, 135 } },
    }, {
        GetAddress = function() return 9501 end,
        GetCharacterID = function() return "CatVampire" end,
        GetNickname = function(_, out_name)
            out_name.outName = "暗系測試帕魯"
        end,
    })
    local dark_component = object({ IndividualParameter = dark_parameter })
    local dark_current_action = nil
    local dark_action_component = object({}, {
        GetCurrentAction = function() return dark_current_action end,
    })
    local dark_pal = actor("BP_CatVampire_C_196", {
        CharacterParameterComponent = dark_component,
        ActionComponent = dark_action_component,
    })
    trainer_by_actor[dark_pal] = player_two
    local dark_boss = boss_actor("BP_WorldTreeDragon_DarkSignature_C_197")

    fake_game_time = 2090
    dark_current_action = actor("BP_ActionDarkLaser_C_2147000104", {
        GetWazaID = function() return 131 end,
        GetActionCharacter = function() return dark_pal end,
    })
    damage(dark_pal, dark_boss, 450, { BasePower = 450, AttackElementType = 8 })
    run_game_tasks()

    -- Reproduce the live concurrent-action conflict: PoisonShot is current
    -- while delayed DarkLegion damage arrives. The signature is unique among
    -- the three equipped slots, so timing conflict must not make it unknown.
    dark_current_action = actor("BP_ActionPoisonShot_C_2147000105", {
        GetWazaID = function() return 135 end,
        GetActionCharacter = function() return dark_pal end,
    })
    damage(dark_pal, dark_boss, 600, { BasePower = 600, AttackElementType = 8 })
    damage(dark_pal, dark_boss, 30, { BasePower = 30, AttackElementType = 8 })
    run_game_tasks()

    dark_current_action = actor("BP_ActionGravityShot_C_2147000106", {
        GetWazaID = function() return 137 end,
        GetActionCharacter = function() return dark_pal end,
    })
    damage(dark_pal, dark_boss, 40, { BasePower = 40, AttackElementType = 8 })
    run_game_tasks()

    local dark_session
    for _, candidate_session in pairs(BossDPSBroadcastTestApi.sessions) do
        if candidate_session.name == "WorldTreeDragon_DarkSignature" then
            dark_session = candidate_session
            break
        end
    end
    assert(dark_session ~= nil and dark_session.total_damage == 1120,
        "dark signature fixture total is incorrect")
    local dark_source = dark_session.diagnostic_sources["pal:9501"]
    assert(dark_source ~= nil, "dark signature Pal source missing")
    for signature, expected in pairs({
        ["skill:DarkLaser"] = 450,
        ["skill:DarkLegion"] = 600,
        ["skill:PoisonShot"] = 30,
        ["skill:GravityShot"] = 40,
    }) do
        assert(dark_source.skill_candidates[signature] ~= nil
            and dark_source.skill_candidates[signature].damage == expected
            and dark_source.skill_candidates[signature].confidence == "inferred",
            "bounded dark/current-action inference failed: " .. signature)
    end
    death(dark_boss)
    run_game_tasks()
    run_delayed_tasks()
    dark_current_action = nil
end

-- The three EquipWaza slots are active skills. A Waza emitted outside those
-- slots is Palworld's default/filler attack and must be labelled as such.
do
    local basic_boss = boss_actor("BP_RaidBoss_BasicAttackDiagnostic_C_186")
    fake_game_time = 2100
    current_action = actor("BP_ActionGravityShot_C_2147000005", {
        GetWazaID = function() return 137 end,
        GetActionCharacter = function() return action_pal end,
    })
    action_begin(current_action)
    run_game_tasks()
    fake_game_time = 2101
    damage(action_pal, basic_boss, 40, { BasePower = 40, AttackElementType = 8 })
    run_game_tasks()
    fake_game_time = 2102
    action_end(current_action)
    run_game_tasks()
    phase = "game"
    BossDPSBroadcastTestApi.publish_current_skill_hud()
    phase = "idle"
    local basic_state = BossDPSBroadcastTestApi.skill_hud.last_external_state
    assert(string.find(basic_state.text, "普攻", 1, true) ~= nil
            and string.find(basic_state.text, "暗能弹", 1, true) ~= nil,
        "non-equipped GravityShot was not presented as a basic attack")
    death(basic_boss)
    run_game_tasks()
    run_delayed_tasks()
    current_action = nil
end

-- Regression: swapping a Pal's equipped skills mid-test must re-read the
-- three-slot list. The old code cached the first snapshot forever, so a newly
-- equipped skill (e.g. DiamondFall) kept the "basic" prefix until a restart.
do
    local swap_parameter = object({
        SaveParameter = {
            EquipWaza = { 501, 502, 601 },
        },
    }, {
        GetAddress = function() return 9501 end,
        GetCharacterID = function() return "PinkCat" end,
        GetNickname = function(_, out_name)
            out_name.outName = "夜幕魔蝠"
        end,
    })
    local swap_component = object({
        IndividualParameter = swap_parameter,
    })
    local swap_action_component = object({}, {
        GetCurrentAction = function() return current_action end,
    })
    local swap_pal = actor("BP_PinkCat_C_187", {
        CharacterParameterComponent = swap_component,
        ActionComponent = swap_action_component,
    })
    trainer_by_actor[swap_pal] = player_two
    local swap_boss = boss_actor("BP_RaidBoss_EquipSwapDiagnostic_C_188")

    -- First cast: an equipped skill (BeamSlicer 601) appears without prefix.
    fake_game_time = 2500
    current_action = actor("BP_ActionBeamSlicer_C_2147000020", {
        GetWazaID = function() return 601 end,
        GetActionCharacter = function() return swap_pal end,
    })
    action_begin(current_action)
    run_game_tasks()
    fake_game_time = 2501
    damage(swap_pal, swap_boss, 300, { BasePower = 350, AttackElementType = 9 })
    run_game_tasks()
    fake_game_time = 2502
    action_end(current_action)
    run_game_tasks()

    -- Swap DiamondFall (602) into the third slot, replacing BeamSlicer.
    phase = "game"
    swap_parameter.SaveParameter.EquipWaza = { 501, 502, 602 }
    phase = "idle"

    -- Second cast starts well after the first cast's delayed-hit window, so
    -- only the action-begin invalidation + re-read decides the classification.
    fake_game_time = 2610
    current_action = actor("BP_ActionDiamondFall_C_2147000021", {
        GetWazaID = function() return 602 end,
        GetActionCharacter = function() return swap_pal end,
    })
    action_begin(current_action)
    run_game_tasks()
    fake_game_time = 2611
    damage(swap_pal, swap_boss, 400, { BasePower = 150, AttackElementType = 1 })
    run_game_tasks()
    fake_game_time = 2612
    action_end(current_action)
    run_game_tasks()

    phase = "game"
    BossDPSBroadcastTestApi.publish_current_skill_hud()
    phase = "idle"
    local swap_state = BossDPSBroadcastTestApi.skill_hud.last_external_state
    assert(string.find(swap_state.text, "晶钻之雨", 1, true) ~= nil,
        "swapped-in DiamondFall was not detected from the refreshed loadout")
    assert(string.find(swap_state.text, "切割龙息", 1, true) ~= nil,
        "pre-swap BeamSlicer result disappeared after the loadout changed")

    -- Loadout and action signatures remain diagnostic only; neither cast may
    -- seed an authoritative signature mapping.
    local swap_session
    for _, candidate_session in pairs(BossDPSBroadcastTestApi.sessions) do
        if candidate_session.name == "RaidBoss_EquipSwapDiagnostic" then
            swap_session = candidate_session
            break
        end
    end
    assert(swap_session ~= nil, "equip-swap session missing")
    local swap_source = swap_session.diagnostic_sources["pal:9501"]
    assert(swap_source ~= nil, "equip-swap pal source missing")
    assert(swap_source.skill_signatures == nil
            or swap_source.skill_signatures["bp:350|element:9"] == nil,
        "pre-swap current action seeded a reliable signature")
    assert(swap_source.skill_signatures == nil
            or swap_source.skill_signatures["bp:150|element:1"] == nil,
        "the swapped-in current action seeded a reliable signature")

    death(swap_boss)
    run_game_tasks()
    run_delayed_tasks()
    current_action = nil
end

-- A unique asset-backed signature from one of the Pal's three equipped slots
-- may identify delayed damage. Timing-only evidence must still be unable to
-- invent a mapping for a signature absent from the equipped asset metadata.
do
    local weak_parameter = object({
        SaveParameter = { EquipWaza = { 501, 502, 602 } },
    }, {
        GetAddress = function() return 9601 end,
        GetCharacterID = function() return "PinkCat" end,
        GetNickname = function(_, out_name)
            out_name.outName = "弱證帕魯"
        end,
    })
    local weak_component = object({
        IndividualParameter = weak_parameter,
    })
    local weak_action_component = object({}, {
        GetCurrentAction = function() return current_action end,
    })
    local weak_pal = actor("BP_PinkCat_C_189", {
        CharacterParameterComponent = weak_component,
        ActionComponent = weak_action_component,
    })
    trainer_by_actor[weak_pal] = player_two
    local weak_boss = boss_actor("BP_RaidBoss_WeakSignature_C_190")

    -- DiamondFall completes; the next delayed hit is attributed only through
    -- the completed-cast timing rule, with no Waza marker or DamageInfo.
    fake_game_time = 2800
    local recent_action = actor("BP_ActionDiamondFall_C_2147000030", {
        GetWazaID = function() return 602 end,
        GetActionCharacter = function() return weak_pal end,
    })
    action_begin(recent_action)
    run_game_tasks()
    fake_game_time = 2801
    action_end(recent_action)
    run_game_tasks()

    -- GravityShot (basic) is current when the ice shard lands.
    fake_game_time = 2810
    current_action = actor("BP_ActionGravityShot_C_2147000031", {
        GetWazaID = function() return 137 end,
        GetActionCharacter = function() return weak_pal end,
    })
    action_begin(current_action)
    run_game_tasks()
    fake_game_time = 2811
    damage(weak_pal, weak_boss, 50, { BasePower = 600, AttackElementType = 6 })
    run_game_tasks()
    fake_game_time = 2812
    action_end(current_action)
    run_game_tasks()

    local weak_session
    for _, candidate_session in pairs(BossDPSBroadcastTestApi.sessions) do
        if candidate_session.name == "RaidBoss_WeakSignature" then
            weak_session = candidate_session
            break
        end
    end
    assert(weak_session ~= nil, "weak-signature session missing")
    local weak_source = weak_session.diagnostic_sources["pal:9601"]
    assert(weak_source ~= nil, "weak-signature pal source missing")
    assert(weak_source.skill_candidates["skill:DiamondFall"] ~= nil
            and weak_source.skill_candidates["skill:DiamondFall"].damage == 50
            and weak_source.skill_candidates["skill:DiamondFall"].confidence == "inferred",
        "unique equipped signature did not recover delayed DiamondFall damage")

    -- Record one genuinely unknown signature, then begin another action. The
    -- old implementation deleted this bucket on every action begin, so source
    -- damage remained 60 while visible skill rows summed to only 50.
    current_action = nil
    fake_game_time = 2900
    damage(weak_pal, weak_boss, 10, { BasePower = 999, AttackElementType = 3 })
    run_game_tasks()
    local unknown_key = "UNRESOLVED_PAL_ATTACK_BP_999_ELEMENT_3"
    assert(weak_source.skill_candidates[unknown_key] ~= nil,
        "unknown signature fixture did not create an unresolved bucket")
    fake_game_time = 2901
    local movement_action = actor("BP_PalAction_AnimationStepRight_C_2147000032", {
        GetWazaID = function() return 0 end,
        GetActionCharacter = function() return weak_pal end,
    })
    action_begin(movement_action)
    run_game_tasks()
    assert(weak_source.skill_candidates[unknown_key] ~= nil,
        "action begin deleted accumulated unresolved damage")
    assert(weak_source.skill_signatures == nil
            or weak_source.skill_signatures["bp:999|element:3"] == nil,
        "timing-only evidence invented an unknown signature mapping")
    local visible_damage = 0
    for _, candidate in pairs(weak_source.skill_candidates) do
        visible_damage = visible_damage + (candidate.damage or 0)
    end
    assert(visible_damage == weak_source.damage,
        "source total no longer equals the sum of its skill candidates")

    death(weak_boss)
    run_game_tasks()
    run_delayed_tasks()
    current_action = nil
end

-- Enabling player verification creates one player source and separates a
-- weapon/projectile candidate. A one-weapon-per-fight workflow remains valid
-- even when Palworld exposes no richer weapon identifier.
runtime_config.IncludePlayerDamage = true
local weapon_boss = boss_actor("BP_RaidBoss_WeaponDiagnostic_C_183")
damage(player_one, weapon_boss, 200, {
    DamageCauser = rifle_projectile,
    DamageInfo = { WeaponType = "AssaultRifle" },
})
damage(player_one, weapon_boss, 300, {
    DamageCauser = rifle_projectile,
    DamageInfo = { WeaponType = "AssaultRifle" },
})
run_game_tasks()
local weapon_session
for _, candidate in pairs(BossDPSBroadcastTestApi.sessions) do
    if candidate.name == "RaidBoss_WeaponDiagnostic" then
        weapon_session = candidate
        break
    end
end
assert(weapon_session ~= nil and weapon_session.total_damage == 500,
    "enabled player damage was not recorded")
local player_diagnostic_source
for _, source in pairs(weapon_session.diagnostic_sources) do
    player_diagnostic_source = source
end
assert(player_diagnostic_source ~= nil and player_diagnostic_source.kind == "player"
    and player_diagnostic_source.damage == 500,
    "player diagnostic source was not isolated from Pal damage")
local weapon_candidate_count = 0
for _, candidate in pairs(player_diagnostic_source.skill_candidates) do
    weapon_candidate_count = weapon_candidate_count + 1
    assert(candidate.damage == 500 and candidate.hits == 2,
        "weapon candidate totals are incorrect")
end
assert(weapon_candidate_count == 1, "one weapon produced multiple diagnostic buckets")
death(weapon_boss)
run_game_tasks()
run_delayed_tasks()

runtime_config.SkillDiagnosticsOnly = false
runtime_config.IncludePlayerDamage = true
runtime_config.BroadcastStart = true

-- Regression for the real 1.0 failure: byte-based truncation could split a
-- Chinese Pal nickname and make SendSystemToPlayerChat raise "bad conversion".
local long_pal_parameter = object({}, {
    GetAddress = function()
        return 9103
    end,
    GetCharacterID = function()
        return "PinkCat"
    end,
    GetNickname = function(_, out_name)
        out_name.outName = "思冬拳思如泉涌!念冬剑念念不忘!浩冬掌生生世世!"
    end,
})
local long_pal = actor("BP_PinkCat_C_22", {
    CharacterParameterComponent = object({ IndividualParameter = long_pal_parameter }),
})
trainer_by_actor[long_pal] = player_two
local encoding_boss = boss_actor("BP_RaidBoss_Encoding_C_23")
local encoding_before = #bob_inbox
damage(long_pal, encoding_boss, 2865)
death(encoding_boss)
run_game_tasks()
run_delayed_tasks()
local encoding_messages = {}
for index = encoding_before + 1, #bob_inbox do
    encoding_messages[#encoding_messages + 1] = bob_inbox[index]
    assert(utf8.len(bob_inbox[index]) ~= nil, "delivered message contains invalid UTF-8")
end
local encoding_joined = table.concat(encoding_messages, "\n")
assert(string.find(encoding_joined, "最高伤害帕鲁：思冬拳思如泉涌!念冬剑念念不忘!浩冬掌生生世世!（捣蛋猫）", 1, true) ~= nil, "long Pal name swallowed MVP row")
assert(string.find(encoding_joined, "队内 #1 思冬拳思如泉涌!念冬剑念念不忘!浩冬掌生生世世!（捣蛋猫）", 1, true) ~= nil, "long Pal name swallowed private row")
assert(string.find(encoding_joined, "击杀播报：Bob 的 思冬拳思如泉涌!念冬剑念念不忘!浩冬掌生生世世!（捣蛋猫） 击败了 RaidBoss_Encoding", 1, true) ~= nil, "Pal final blow announcement missing")

-- A high-output 10-second window gets an optional triggered comment.
local comment_boss = boss_actor("BP_RaidBoss_Comment_C_21")
local comment_before = #delivered
damage(player_one, comment_boss, 1200000)
run_game_tasks()
run_delayed_tasks()
fake_time = fake_time + 10
phase = "game"
BossDPSBroadcastTestApi.publish_progress()
phase = "idle"
run_delayed_tasks()
local comment_messages = {}
for index = comment_before + 1, #delivered do
    comment_messages[#comment_messages + 1] = delivered[index]
end
local comment_joined = table.concat(comment_messages, "\n")
assert(string.find(comment_joined, "实时战况", 1, true) ~= nil)
assert(string.find(comment_joined, "战况点评：", 1, true) ~= nil, "triggered progress comment missing")
assert(string.find(comment_joined, "红队", 1, true) ~= nil or string.find(comment_joined, "Alice", 1, true) ~= nil, "progress comment did not render live names")
assert(string.find(comment_joined, "{guild}", 1, true) == nil, "comment template was not rendered")
death(comment_boss)
run_game_tasks()
run_delayed_tasks()

-- Commentary can be disabled independently while damage reports stay active.
runtime_config.EnableFunComments = false
local silent_comment_boss = boss_actor("BP_RaidBoss_NoComment_C_31")
local silent_before = #delivered
damage(player_one, silent_comment_boss, 50000)
run_game_tasks()
run_delayed_tasks()
fake_time = fake_time + 10
phase = "game"
BossDPSBroadcastTestApi.publish_progress()
phase = "idle"
death(silent_comment_boss)
run_game_tasks()
run_delayed_tasks()
local silent_messages = {}
for index = silent_before + 1, #delivered do
    silent_messages[#silent_messages + 1] = delivered[index]
end
local silent_joined = table.concat(silent_messages, "\n")
assert(string.find(silent_joined, "实时战况", 1, true) ~= nil,
    "disabling comments also disabled DPS reports")
assert(string.find(silent_joined, "战况点评：", 1, true) == nil,
    "progress commentary was sent while disabled")
assert(string.find(silent_joined, "战斗点评：", 1, true) == nil,
    "final commentary was sent while disabled")
runtime_config.EnableFunComments = true

-- Public defaults produce only the result summary and aggregate player ranks.
runtime_config.BroadcastStart = false
runtime_config.EnableProgressReports = false
runtime_config.EnableDetailedAwards = false
runtime_config.EnableTeamDetails = false
runtime_config.EnableFunComments = false
local compact_boss = boss_actor("BP_RaidBoss_Compact_C_32")
local compact_before = #delivered
damage(player_one, compact_boss, 700)
damage(player_two_pal, compact_boss, 300)
run_game_tasks()
run_delayed_tasks()
fake_time = fake_time + 10
phase = "game"
BossDPSBroadcastTestApi.publish_progress()
phase = "idle"
death(compact_boss)
run_game_tasks()
run_delayed_tasks()
local compact_messages = {}
for index = compact_before + 1, #delivered do
    compact_messages[#compact_messages + 1] = delivered[index]
end
local compact_joined = table.concat(compact_messages, "\n")
assert(#compact_messages == 3, "two-player compact result should contain exactly three lines")
assert(string.find(compact_joined, "MVP #1 Alice｜伤害 700｜70.0%", 1, true) ~= nil,
    "compact result has no MVP row")
assert(string.find(compact_joined, "#2 Bob｜伤害 300｜30.0%", 1, true) ~= nil,
    "compact result has no runner-up row")
for _, forbidden in ipairs({ "开始统计", "实时战况", "点评：", "最高伤害", "队内" }) do
    assert(string.find(compact_joined, forbidden, 1, true) == nil,
        "compact result contains disabled component: " .. forbidden)
end
runtime_config.BroadcastStart = true
runtime_config.EnableProgressReports = true
runtime_config.EnableDetailedAwards = true
runtime_config.EnableTeamDetails = true
runtime_config.EnableFunComments = true

-- UObject can disappear between hook capture and the next game-thread drain.
local stale_boss = boss_actor("BP_RaidBoss_Stale_C_16")
local invalid_before = BossDPSBroadcastTestApi.metrics.invalid
damage(player_one, stale_boss, 100)
phase = "game"
stale_boss:__invalidate()
phase = "idle"
run_game_tasks()
assert(BossDPSBroadcastTestApi.metrics.invalid == invalid_before + 1, "stale actor was not rejected")

-- Timeout produces a partial ranking and closes the session.
local timeout_boss = boss_actor("BP_RaidBoss_Timeout_C_11")
damage(player_one, timeout_boss, 250)
run_game_tasks()
fake_time = fake_time + 61
phase = "game"
BossDPSBroadcastTestApi.cleanup_sessions()
phase = "idle"
run_delayed_tasks()
joined = table.concat(delivered, "\n")
assert(string.find(joined, "挑战中断（长时间无伤害）", 1, true) ~= nil, "timeout result missing")
assert(string.find(joined, "团队伤害 250", 1, true) ~= nil, "timeout damage missing")
assert(string.find(joined, "战斗点评：", 1, true) ~= nil, "failure comment missing")

-- Simultaneous bosses must keep independent totals and rankings.
local multi_a = boss_actor("BP_RaidBoss_MultiA_C_12")
local multi_b = boss_actor("BP_RaidBoss_MultiB_C_13")
local delivered_before_multi = #delivered
damage(player_one, multi_a, 100)
damage(player_two_pal, multi_b, 300)
damage(player_one, multi_b, 50)
death(multi_b)
death(multi_a)
run_game_tasks()
run_delayed_tasks()
local multi_messages = {}
for index = delivered_before_multi + 1, #delivered do
    multi_messages[#multi_messages + 1] = delivered[index]
end
local multi_joined = table.concat(multi_messages, "\n")
assert(string.find(multi_joined, "击败了 RaidBoss_MultiA｜用时 1秒｜团队DPS 100｜团队伤害 100", 1, true) ~= nil, "boss A total mixed")
assert(string.find(multi_joined, "击败了 RaidBoss_MultiB｜用时 1秒｜团队DPS 350｜团队伤害 350", 1, true) ~= nil, "boss B total mixed")

-- A composite boss uses several damageable actors. All body parts must share
-- one report, and destroying a non-terminal hand/head must not end the fight.
local moon_anchor = actor("BP_YakushimaBoss002_Controller_C_1")
local moon_body = boss_actor("BP_YakushimaBoss002_B_C_101", { Owner = moon_anchor })
local moon_head = boss_actor("BP_YakushimaBoss002_Head_C_102", { Owner = moon_anchor })
local moon_left = boss_actor("BP_YakushimaBoss002_L_C_103", { Owner = moon_anchor })
local moon_right = boss_actor("BP_YakushimaBoss002_R_C_104", { Owner = moon_anchor })
local delivered_before_composite = #delivered
local composite_joins_before = BossDPSBroadcastTestApi.metrics.composite_joins
local pal_cache_hits_before = BossDPSBroadcastTestApi.metrics.pal_metadata_cache_hits
local source_cache_hits_before = BossDPSBroadcastTestApi.metrics.source_owner_cache_hits
local contributor_cache_hits_before = BossDPSBroadcastTestApi.metrics.contributor_cache_hits
local nickname_calls_before = nickname_calls
damage(player_one, moon_body, 100)
damage(player_two_pal, moon_head, 200)
damage(player_one, moon_left, 300)
damage(player_two_pal, moon_right, 400)
run_game_tasks()
run_delayed_tasks()
assert(BossDPSBroadcastTestApi.metrics.composite_joins - composite_joins_before == 3,
    "Moon Lord parts did not join one encounter")
assert(BossDPSBroadcastTestApi.metrics.pal_metadata_cache_hits - pal_cache_hits_before == 1,
    "repeated Pal hits did not reuse per-encounter metadata")
assert(BossDPSBroadcastTestApi.metrics.source_owner_cache_hits - source_cache_hits_before >= 1,
    "repeated damage source did not reuse ownership resolution")
assert(BossDPSBroadcastTestApi.metrics.contributor_cache_hits - contributor_cache_hits_before == 2,
    "repeated PlayerState did not reuse contributor identity")
assert(nickname_calls - nickname_calls_before == 1,
    "Pal nickname was queried more than once inside one encounter")

local delivered_before_nonterminal_death = #delivered
death(moon_head)
run_game_tasks()
run_delayed_tasks()
assert(#delivered == delivered_before_nonterminal_death,
    "non-terminal composite part ended the whole encounter")

death(moon_body)
run_game_tasks()
run_delayed_tasks()
local composite_messages = {}
for index = delivered_before_composite + 1, #delivered do
    composite_messages[#composite_messages + 1] = delivered[index]
end
local composite_joined = table.concat(composite_messages, "\n")
assert(count_plain(composite_joined, "开始统计：月亮领主 已进入战斗") == 0,
    "removed start-chat announcement returned")
assert(string.find(composite_joined, "团队伤害 1,000", 1, true) ~= nil,
    "composite part damage was not aggregated")
assert(count_plain(composite_joined, "击败了 月亮领主") == 1,
    "composite encounter produced multiple final reports")

-- Two simultaneous composite encounters stay isolated when their common
-- owner/controller anchors differ.
local anchor_a = actor("BP_YakushimaBoss002_Controller_C_2")
local anchor_b = actor("BP_YakushimaBoss002_Controller_C_3")
local body_a = boss_actor("BP_YakushimaBoss002_B_C_201", { Owner = anchor_a })
local head_a = boss_actor("BP_YakushimaBoss002_Head_C_202", { Owner = anchor_a })
local body_b = boss_actor("BP_YakushimaBoss002_B_C_301", { Owner = anchor_b })
local head_b = boss_actor("BP_YakushimaBoss002_Head_C_302", { Owner = anchor_b })
local delivered_before_parallel_composite = #delivered
damage(player_one, body_a, 111)
damage(player_one, body_b, 444)
damage(player_one, head_a, 222)
damage(player_one, head_b, 555)
death(body_a)
death(body_b)
run_game_tasks()
run_delayed_tasks()
local parallel_messages = {}
for index = delivered_before_parallel_composite + 1, #delivered do
    parallel_messages[#parallel_messages + 1] = delivered[index]
end
local parallel_joined = table.concat(parallel_messages, "\n")
assert(string.find(parallel_joined, "团队伤害 333", 1, true) ~= nil,
    "first composite encounter mixed with another instance")
assert(string.find(parallel_joined, "团队伤害 999", 1, true) ~= nil,
    "second composite encounter mixed with another instance")

-- Workshop/single-player mode sends reports only to the local participant,
-- even if a listen-server encounter also contains a remote contributor.
local local_only_boss = boss_actor("BP_RaidBoss_LocalOnly_C_350")
local alice_before_local_only = #delivered
local bob_inbox = delivered_by_uid[test_guid_key(uid_two)]
local bob_before_local_only = #bob_inbox
local previous_fun_comments = runtime_config.EnableFunComments
local previous_progress = runtime_config.EnableProgressReports
local previous_pal_breakdown = runtime_config.EnablePalDamageBreakdown
local previous_details = runtime_config.EnableTeamDetails
runtime_config.LocalOnlyMessages = true
runtime_config.EnableFunComments = false
runtime_config.EnableProgressReports = false
runtime_config.EnablePalDamageBreakdown = true
runtime_config.EnableTeamDetails = false
damage(player_one, local_only_boss, 600)
damage(player_two_pal, local_only_boss, 400)
death(local_only_boss)
run_game_tasks()
run_delayed_tasks()
local local_only_messages = {}
for index = alice_before_local_only + 1, #delivered do
    local_only_messages[#local_only_messages + 1] = delivered[index]
end
assert(string.find(table.concat(local_only_messages, "\n"), "团队伤害 1,000", 1, true) ~= nil,
    "local player did not receive single-player result")
assert(#bob_inbox == bob_before_local_only,
    "remote contributor received a local-only single-player result")
runtime_config.LocalOnlyMessages = false

-- The clearer v3.4 setting must enable the same per-Pal report without the
-- legacy EnableTeamDetails alias.
local canonical_switch_boss = boss_actor("BP_RaidBoss_CanonicalSwitch_C_351")
local bob_before_canonical_switch = #bob_inbox
damage(player_two_pal, canonical_switch_boss, 400)
death(canonical_switch_boss)
run_game_tasks()
run_delayed_tasks()
local canonical_switch_messages = {}
for index = bob_before_canonical_switch + 1, #bob_inbox do
    canonical_switch_messages[#canonical_switch_messages + 1] = bob_inbox[index]
end
assert(string.find(table.concat(canonical_switch_messages, "\n"), "棉花糖（捣蛋猫）［Bob］｜伤害 400", 1, true) ~= nil,
    "new Pal damage breakdown switch did not publish individual Pal damage")

runtime_config.EnableFunComments = previous_fun_comments
runtime_config.EnableProgressReports = previous_progress
runtime_config.EnablePalDamageBreakdown = previous_pal_breakdown
runtime_config.EnableTeamDetails = previous_details

-- Repeated multi-hit Pal damage should reuse ownership, contributor, and Pal
-- metadata instead of calling the full reflected lookup chain for every hit.
local performance_boss = boss_actor("BP_RaidBoss_Performance_C_401")
local source_hits_before_burst = BossDPSBroadcastTestApi.metrics.source_owner_cache_hits
local contributor_hits_before_burst = BossDPSBroadcastTestApi.metrics.contributor_cache_hits
local pal_hits_before_burst = BossDPSBroadcastTestApi.metrics.pal_metadata_cache_hits
local nickname_before_burst = nickname_calls
for _ = 1, 1000 do
    damage(player_two_pal, performance_boss, 1)
end
death(performance_boss)
run_game_tasks()
run_delayed_tasks()
assert(BossDPSBroadcastTestApi.metrics.source_owner_cache_hits - source_hits_before_burst >= 999,
    "multi-hit burst repeated source-owner traversal")
assert(BossDPSBroadcastTestApi.metrics.contributor_cache_hits - contributor_hits_before_burst >= 999,
    "multi-hit burst repeated contributor identity lookup")
assert(BossDPSBroadcastTestApi.metrics.pal_metadata_cache_hits - pal_hits_before_burst >= 999,
    "multi-hit burst repeated Pal metadata lookup")
assert(nickname_calls - nickname_before_burst == 1,
    "multi-hit burst queried the same Pal nickname repeatedly")

-- A captured/owned boss variant must not start a PvE boss session.
local owned_boss = boss_actor("BP_RaidBoss_Owned_C_14")
trainer_by_actor[owned_boss] = player_one
local delivered_before_owned = #delivered
damage(player_two, owned_boss, 500)
run_game_tasks()
run_delayed_tasks()
assert(#delivered == delivered_before_owned, "player-owned Pal was treated as a world boss")

-- Back-pressure: a 10k-hit burst must cap memory. A death event is retained
-- beyond the damage cap so an already-running boss session can still close.
local stress_boss = boss_actor("BP_RaidBoss_Stress_C_15")
damage(player_one, stress_boss, 1)
run_game_tasks()
local accepted_before = BossDPSBroadcastTestApi.metrics.accepted
local dropped_before = BossDPSBroadcastTestApi.metrics.dropped
local non_boss_cache_hits_before = BossDPSBroadcastTestApi.metrics.non_boss_cache_hits
accesses_before_hook = object_accesses
for _ = 1, 10000 do
    damage(player_one, normal_target, 1)
end
death(stress_boss)
assert(object_accesses == accesses_before_hook, "stress hooks touched UObjects")
assert(BossDPSBroadcastTestApi.queue_size() == 8193, "damage cap or retained death event is incorrect")
assert(BossDPSBroadcastTestApi.metrics.accepted - accepted_before == 8193)
assert(BossDPSBroadcastTestApi.metrics.dropped - dropped_before == 1808)
assert(#game_tasks == 1, "stress burst scheduled more than one initial drain")
local accesses_before_normal_drain = object_accesses
local drain_count = run_game_tasks()
local normal_drain_accesses = object_accesses - accesses_before_normal_drain
assert(drain_count == 33, "8192 damage events plus death should drain in 33 batches")
assert(BossDPSBroadcastTestApi.queue_size() == 0, "stress queue did not fully drain")
assert(BossDPSBroadcastTestApi.metrics.non_boss_cache_hits - non_boss_cache_hits_before >= 8191,
    "ordinary-target fast cache did not bypass repeated ownership resolution")
assert(normal_drain_accesses < 20000,
    "ordinary-target fast path performed too many reflected UObject accesses")
run_delayed_tasks()
joined = table.concat(delivered, "\n")
assert(string.find(joined, "击败了 RaidBoss_Stress｜用时 1秒｜团队DPS 1｜团队伤害 1", 1, true) ~= nil, "death was lost behind burst traffic")

-- A Boss actor can expose its reflected database flags one or more callbacks
-- after damage starts. An inconclusive first read must remain retryable; the
-- old negative cache treated the missing fields as an ordinary Pal and could
-- suppress the same target until its runtime object/phase changed.
do
runtime_config.MeasurementMode = "manual"
runtime_config.TargetScope = "field"
runtime_config.IncludePlayerDamage = false
runtime_config.SkillDiagnosticsOnly = true
phase = "game"
BossDPSBroadcastTestApi.reset_skill_diagnostics()
phase = "idle"
local transient_flags = {
    IsBoss_Database = false,
    IsTowerBoss_Database = false,
}
local transient_boss = actor("BP_GrassPanda_Electric_C_402", {
    StaticCharacterParameterComponent = object(transient_flags),
})
local unknown_classifications_before =
    BossDPSBroadcastTestApi.metrics.target_classification_unknown
damage(player_two_pal, transient_boss, 100)
run_game_tasks()
local transient_session =
    BossDPSBroadcastTestApi.sessions["__PAL_SKILL_DPS_MANUAL_TEST__"]
assert(transient_session ~= nil and transient_session.total_damage == 0
        and transient_session.manual_armed == true
        and BossDPSBroadcastTestApi.metrics.target_classification_unknown
            == unknown_classifications_before + 1,
    "pre-initialized false Boss flags were accepted before the encounter settled")
transient_flags.IsTowerBoss_Database = true
damage(player_two_pal, transient_boss, 200)
run_game_tasks()
assert(transient_session.total_damage == 200
        and transient_session.manual_armed == false
        and transient_session.target_count == 1,
    "an early false Boss read poisoned later target locking")
phase = "game"
BossDPSBroadcastTestApi.reset_skill_diagnostics()
phase = "idle"
runtime_config.MeasurementMode = "target"
runtime_config.IncludePlayerDamage = true
runtime_config.SkillDiagnosticsOnly = false
end

-- Tablet mode accepts same-guild base workers. The main HUD groups only Pals
-- with both the same species and the same three-skill loadout; F3 keeps every
-- worker as an individual damage/DPS source.
function run_manual_damage_lab_test()
runtime_config.MeasurementMode = "manual"
runtime_config.TargetScope = "field"
runtime_config.IncludePlayerDamage = false
runtime_config.SkillDiagnosticsOnly = true
phase = "game"
BossDPSBroadcastTestApi.reset_skill_diagnostics()
phase = "idle"
local base_pal_parameter = object({
    SaveParameter = { EquipWaza = { 501, 502, 601 } },
}, {
    GetAddress = function() return 9199 end,
    GetCharacterID = function() return "PinkCat" end,
    GetNickname = function(_, out_name) out_name.outName = "基地帕魯甲" end,
    GetBaseCampId = function() return base_camp_one_id end,
    GetGroupId = function() return guild_one_id end,
})
local base_pal = actor("BP_PinkCat_Base_C_44", {
    CharacterParameterComponent = object({ IndividualParameter = base_pal_parameter }),
})
assert(trainer_by_actor[base_pal] == nil,
    "base Pal regression must not provide an ordinary trainer")
local base_pal_two_parameter = object({
    SaveParameter = { EquipWaza = { 501, 502, 601 } },
}, {
    GetAddress = function() return 9200 end,
    GetCharacterID = function() return "PinkCat" end,
    GetNickname = function(_, out_name) out_name.outName = "基地帕魯乙" end,
    GetBaseCampId = function() return base_camp_one_id end,
    GetGroupId = function() return guild_one_id end,
})
local base_pal_two = actor("BP_PinkCat_Base_C_45", {
    CharacterParameterComponent = object({ IndividualParameter = base_pal_two_parameter }),
})
local alternate_base_parameter = object({
    SaveParameter = { EquipWaza = { 501, 602, 701 } },
}, {
    GetAddress = function() return 9201 end,
    GetCharacterID = function() return "PinkCat" end,
    GetNickname = function(_, out_name) out_name.outName = "異配帕魯" end,
    GetBaseCampId = function() return base_camp_one_id end,
    GetGroupId = function() return guild_one_id end,
})
local alternate_base_pal = actor("BP_PinkCat_Base_C_46", {
    CharacterParameterComponent = object({ IndividualParameter = alternate_base_parameter }),
})
local alpha_target = boss_actor("BP_RaidBoss_Tablet_C_49")
local field_info = { BasePower = 50, AttackElementType = 8 }
waza(base_pal, alpha_target, 502, field_info)
damage(base_pal, alpha_target, 50, { DamageInfo = field_info })
run_game_tasks()
local field_session = BossDPSBroadcastTestApi.sessions["__PAL_SKILL_DPS_MANUAL_TEST__"]
assert(field_session ~= nil and field_session.total_damage == 0,
    "field/dungeon profile accepted a trainerless base worker")
runtime_config.TargetScope = "tablet"
phase = "game"
BossDPSBroadcastTestApi.reset_skill_diagnostics()
phase = "idle"
local active_info = { BasePower = 301, AttackElementType = 8 }
local base_one_info = { BasePower = 502, AttackElementType = 8 }
local base_two_info = { BasePower = 601, AttackElementType = 8 }
local alternate_info = { BasePower = 701, AttackElementType = 6 }
waza(player_two_pal, alpha_target, 501, active_info)
damage(player_two_pal, alpha_target, 300, { DamageInfo = active_info })
waza(base_pal, alpha_target, 502, base_one_info)
damage(base_pal, alpha_target, 500, { DamageInfo = base_one_info })
waza(base_pal_two, alpha_target, 601, base_two_info)
damage(base_pal_two, alpha_target, 200, { DamageInfo = base_two_info })
waza(alternate_base_pal, alpha_target, 701, alternate_info)
damage(alternate_base_pal, alpha_target, 100, { DamageInfo = alternate_info })
local foreign_base_parameter = object({}, {
    GetAddress = function() return 9299 end,
    GetCharacterID = function() return "PinkCat" end,
    GetBaseCampId = function() return base_camp_one_id end,
    GetGroupId = function() return guild_two_id end,
})
local foreign_base_pal = actor("BP_PinkCat_ForeignBase_C_47", {
    CharacterParameterComponent = object({ IndividualParameter = foreign_base_parameter }),
})
local wild_parameter = object({}, {
    GetAddress = function() return 9399 end,
    GetCharacterID = function() return "PinkCat" end,
    GetBaseCampId = function() return zero_guid end,
    GetGroupId = function() return guild_one_id end,
})
local wild_pal = actor("BP_PinkCat_Wild_C_48", {
    CharacterParameterComponent = object({ IndividualParameter = wild_parameter }),
})
waza(foreign_base_pal, alpha_target, 501)
damage(foreign_base_pal, alpha_target, 900)
waza(wild_pal, alpha_target, 501)
damage(wild_pal, alpha_target, 700)
run_game_tasks()
local manual_session = BossDPSBroadcastTestApi.sessions["__PAL_SKILL_DPS_MANUAL_TEST__"]
assert(manual_session ~= nil and manual_session.finished ~= true,
    "tablet test did not remain active before the Boss terminal event")
assert(manual_session.total_damage == 1100 and manual_session.target_count == 1,
    "tablet test did not aggregate local sources or accepted wild/foreign base Pals")
assert(BossDPSBroadcastTestApi.metrics.base_pal_owner_resolutions >= 1,
    "trainerless local-guild base Pal did not use the base ownership path")
local manual_pal_count = 0
for _ in pairs(manual_session.pal_sources) do manual_pal_count = manual_pal_count + 1 end
assert(manual_pal_count == 4, "tablet test merged individual Pal accounting sources")
phase = "game"
BossDPSBroadcastTestApi.publish_current_skill_hud()
phase = "idle"
local tablet_snapshot = BossDPSBroadcastTestApi.skill_hud.latest_snapshot
assert(tablet_snapshot ~= nil and tablet_snapshot.test_profile == "tablet"
    and #tablet_snapshot.sources == 2 and #tablet_snapshot.detail_sources == 4,
    "tablet snapshot did not separate compact loadout groups from individual details")
assert(tablet_snapshot.sources[1].count == 3
    and tablet_snapshot.sources[1].damage == 1000
    and #tablet_snapshot.sources[1].skills == 3
    and tablet_snapshot.sources[2].count == 1
    and tablet_snapshot.sources[2].damage == 100
    and #tablet_snapshot.sources[2].skills == 3,
    "same-loadout workers were not grouped or different loadouts were mixed")
assert(string.find(tablet_snapshot.sources[1].name, " A", 1, true) ~= nil
    and string.find(tablet_snapshot.sources[2].name, " B", 1, true) ~= nil,
    "same-species loadout variants were not labelled separately")
local uncertain_groups = BossDPSBroadcastTestApi.hooks.aggregate_tablet_sources({
    {
        kind = "pal", name = "讀取不完整甲", species = "棉花糖",
        species_id = "PinkCat", damage = 20, hits = 1, skills = {},
    },
    {
        kind = "pal", name = "讀取不完整乙", species = "棉花糖",
        species_id = "PinkCat", damage = 10, hits = 1, skills = {},
    },
}, 1, 30)
assert(#uncertain_groups == 2
    and uncertain_groups[1].count == 1 and uncertain_groups[2].count == 1,
    "Pals without a complete three-skill fingerprint were unsafely merged")
local tablet_meter = BossDPSBroadcastTestApi.skill_hud.last_external_state.text
assert(string.find(tablet_meter, "test_profile=tablet", 1, true) ~= nil
    and string.find(tablet_meter, "\t3\t", 1, true) ~= nil,
    "tablet meter did not publish the group count/profile needed by the percentage HUD")
local capped_meter = BossDPSBroadcastTestApi.skill_hud:build_external_meter_document({
    state = "active", boss = "分組上限測試", duration = 10,
    total_damage = 1000, encounter_dps = 100, test_profile = "tablet",
    sources = {
        { name = "第一組", damage = 400, dps = 40, damage_share = 40, count = 2,
            skills = { { name = "技能甲", internal_code = "A", damage = 400 } } },
        { name = "第二組", damage = 300, dps = 30, damage_share = 30, count = 1,
            skills = { { name = "技能乙", internal_code = "B", damage = 300 } } },
        { name = "第三組", damage = 200, dps = 20, damage_share = 20, count = 1,
            skills = { { name = "技能丙", internal_code = "C", damage = 200 } } },
        { name = "第四組", damage = 100, dps = 10, damage_share = 10, count = 1,
            skills = { { name = "技能丁", internal_code = "D", damage = 100 } } },
    },
}, 999)
assert(string.find(capped_meter, "\nsource_count=3\n", 1, true) ~= nil
    and string.find(capped_meter, "\nhidden_source_count=1\n", 1, true) ~= nil
    and string.find(capped_meter, "\nmore_details_hint=", 1, true) ~= nil
    and string.match(capped_meter, "more_details_hint=[^\n]*1") ~= nil
    and string.find(capped_meter, "第四組", 1, true) == nil,
    "live HUD did not cap the damage-ranked source groups at three with an F3 hint")
phase = "game"
assert(BossDPSBroadcastTestApi.skill_hud:toggle_settings() == true
    and BossDPSBroadcastTestApi.skill_hud.settings_open == true,
    "manual mode did not expose the F3 settings workspace")
assert(console_command_callbacks.psdps(
    "psdps", { "ui", "tab", "groups" }) == true,
    "tablet grouped-percentage tab button command was not accepted")
run_game_tasks()
assert(BossDPSBroadcastTestApi.skill_hud.settings_page == 1
    and native_settings_page == 1
    and string.find(native_settings_text.PSDPS_GroupRows or "", " A ×3", 1, true) ~= nil
    and string.find(native_settings_text.PSDPS_GroupRows or "", " B", 1, true) ~= nil
    and string.find(native_settings_text.PSDPS_GroupRows or "", "%", 1, true) ~= nil
    and string.find(native_settings_text.PSDPS_GroupRows or "", "基地帕魯甲", 1, true) == nil,
    "F3 grouped report did not mirror the complete main-HUD percentage model")
phase = "game"
assert(console_command_callbacks.psdps(
    "psdps", { "ui", "tab", "details" }) == true,
    "tablet per-Pal detail tab button command was not accepted")
run_game_tasks()
assert(BossDPSBroadcastTestApi.skill_hud.settings_page == 2
    and native_settings_page == 2
    and string.find(native_settings_text.PSDPS_DetailRows or "", "基地帕魯甲", 1, true) ~= nil
    and string.find(native_settings_text.PSDPS_DetailRows or "", "基地帕魯乙", 1, true) ~= nil
    and string.find(native_settings_text.PSDPS_DetailRows or "", "異配帕魯", 1, true) ~= nil
    and string.find(native_settings_text.PSDPS_DetailRows or "", "500", 1, true) ~= nil
    and string.find(native_settings_text.PSDPS_DetailRows or "", "DPS", 1, true) ~= nil,
    "F3 did not retain per-worker damage and DPS details")
phase = "game"
BossDPSBroadcastTestApi.skill_hud:close_settings()
BossDPSBroadcastTestApi.reset_skill_diagnostics()
phase = "idle"
manual_session = BossDPSBroadcastTestApi.sessions["__PAL_SKILL_DPS_MANUAL_TEST__"]
assert(manual_session ~= nil and manual_session.total_damage == 0 and manual_session.manual_armed == true,
    "Start new test did not reset and re-arm the manual window")
runtime_config.MeasurementMode = "target"
runtime_config.TargetScope = "field"
runtime_config.IncludePlayerDamage = true
runtime_config.SkillDiagnosticsOnly = false
end
run_manual_damage_lab_test()
run_manual_damage_lab_test = nil

-- Manual tests are operator-controlled windows. Death/capture only removes the
-- ended target binding; composite phases and multiple world-spawn Bosses must
-- leave the same test active until F2 resets it. Hard-tower adds are different:
-- only the GYM/TowerBoss actor owns the encounter health bar and may contribute.
function run_manual_boss_continuous_test()
runtime_config.MeasurementMode = "manual"
runtime_config.TargetScope = "field"
runtime_config.IncludePlayerDamage = false
runtime_config.SkillDiagnosticsOnly = true
phase = "game"
BossDPSBroadcastTestApi.reset_skill_diagnostics()
phase = "idle"

local phase_anchor = actor("BP_YakushimaBoss002_Controller_C_901")
local phase_head = boss_actor("BP_YakushimaBoss002_Head_C_902", { Owner = phase_anchor })
local phase_body = boss_actor("BP_YakushimaBoss002_B_C_903", { Owner = phase_anchor })
fake_game_time = 3000
waza(player_two_pal, phase_head, 501)
damage(player_two_pal, phase_head, 100)
run_game_tasks()
fake_game_time = 3005
death(phase_head)
run_game_tasks()
local boss_session = BossDPSBroadcastTestApi.sessions["__PAL_SKILL_DPS_MANUAL_TEST__"]
assert(boss_session ~= nil and boss_session.finished ~= true,
    "non-terminal Boss phase froze the manual Boss snapshot")

waza(player_two_pal, phase_body, 501)
damage(player_two_pal, phase_body, 200)
run_game_tasks()
fake_game_time = 3012
death(phase_body)
run_game_tasks()
assert(BossDPSBroadcastTestApi.sessions["__PAL_SKILL_DPS_MANUAL_TEST__"] == boss_session
    and boss_session.finished ~= true
    and boss_session.total_damage == 300,
    "Boss death froze an operator-controlled manual test")
-- Real multi-hit effects can deliver their last segments after a death hook.
-- They remain in the same manual test without a settlement snapshot.
waza(player_two_pal, phase_body, 501)
damage(player_two_pal, phase_body, 40)
damage(player_two_pal, phase_body, 60)
run_game_tasks()
assert(boss_session.total_damage == 400 and boss_session.finished ~= true,
    "post-death multi-hit segments were not retained in the manual test")

local world_boss_a = boss_actor("BP_RaidBoss_WorldMultiplier_A_C_905")
local world_boss_b = boss_actor("BP_RaidBoss_WorldMultiplier_B_C_906")
waza(player_two_pal, world_boss_a, 501)
damage(player_two_pal, world_boss_a, 50)
waza(player_two_pal, world_boss_b, 501)
damage(player_two_pal, world_boss_b, 70)
run_game_tasks()
death(world_boss_a)
run_game_tasks()
assert(boss_session.total_damage == 520 and boss_session.finished ~= true,
    "the first Boss death ended a multi-Boss manual test")
waza(player_two_pal, world_boss_b, 501)
damage(player_two_pal, world_boss_b, 30)
run_game_tasks()
death(world_boss_b)
run_game_tasks()
assert(BossDPSBroadcastTestApi.sessions["__PAL_SKILL_DPS_MANUAL_TEST__"] == boss_session
    and boss_session.total_damage == 550 and boss_session.finished ~= true,
    "the final bound Boss death auto-snapshotted a manual test")

fake_game_time = 3060
phase = "game"
BossDPSBroadcastTestApi.publish_current_skill_hud()
phase = "idle"
local active_snapshot = BossDPSBroadcastTestApi.skill_hud.latest_snapshot
assert(active_snapshot ~= nil and active_snapshot.state == "active"
    and active_snapshot.total_damage == 550,
    "manual HUD did not retain the active cumulative result")

phase = "game"
BossDPSBroadcastTestApi.reset_skill_diagnostics()
phase = "idle"

-- Hard-tower adds can expose both the Boss and TowerBoss database flags. If one is hit before the
-- tower main, its tentative damage must be discarded as soon as the GYM actor
-- appears; later add damage must stay excluded. This must not affect the world
-- multiplier case above, where every real Boss remains part of the test.
local tower_add_a = actor("BP_LazyDragon_Electric_C_920", {
    StaticCharacterParameterComponent = object({
        IsBoss_Database = true,
        IsTowerBoss_Database = true,
    }),
})
local tower_add_b = actor("BP_GrassPanda_Electric_C_921", {
    StaticCharacterParameterComponent = object({
        IsBoss_Database = true,
        IsTowerBoss_Database = true,
    }),
})
local tower_main = actor("BP_ThunderDragonMan_GYM_Hard_C_922", {
    StaticCharacterParameterComponent = object({
        IsBoss_Database = true,
        IsTowerBoss_Database = true,
    }),
})
fake_game_time = 3070
waza(player_two_pal, tower_add_a, 501)
damage(player_two_pal, tower_add_a, 125)
run_game_tasks()
local tower_session = BossDPSBroadcastTestApi.sessions["__PAL_SKILL_DPS_MANUAL_TEST__"]
assert(tower_session ~= nil and tower_session.total_damage == 125,
    "pre-main tower add did not enter the tentative manual result")
waza(player_two_pal, tower_main, 501)
damage(player_two_pal, tower_main, 200)
run_game_tasks()
assert(tower_session.tower_boss_locked == true
    and tower_session.total_damage == 200,
    "tower main did not discard earlier add damage and restart the measurement")
waza(player_two_pal, tower_add_a, 501)
damage(player_two_pal, tower_add_a, 300)
waza(player_two_pal, tower_add_b, 501)
damage(player_two_pal, tower_add_b, 400)
run_game_tasks()
assert(tower_session.total_damage == 200,
    "tower adds were counted after the tower main lock")
waza(player_two_pal, tower_main, 501)
damage(player_two_pal, tower_main, 50)
run_game_tasks()
assert(tower_session.total_damage == 250 and tower_session.target_count == 1,
    "tower-main damage or target binding was lost while excluding adds")

phase = "game"
BossDPSBroadcastTestApi.reset_skill_diagnostics()
phase = "idle"
local captured_boss = boss_actor("BP_RaidBoss_ManualCapture_C_904")
fake_game_time = 3100
waza(player_two_pal, captured_boss, 501)
damage(player_two_pal, captured_boss, 90)
run_game_tasks()
fake_game_time = 3109
captured(captured_boss, player_two_pal)
run_game_tasks()
run_delayed_tasks()
local captured_session = BossDPSBroadcastTestApi.sessions["__PAL_SKILL_DPS_MANUAL_TEST__"]
assert(captured_session ~= nil and captured_session.finished ~= true
    and captured_session.total_damage == 90,
    "captured Boss froze an operator-controlled manual test")

runtime_config.MeasurementMode = "target"
runtime_config.TargetScope = "field"
runtime_config.IncludePlayerDamage = true
runtime_config.SkillDiagnosticsOnly = false
phase = "game"
BossDPSBroadcastTestApi.reset_skill_diagnostics()
phase = "idle"
end
run_manual_boss_continuous_test()
run_manual_boss_continuous_test = nil

-- Native event API v2: every final hit arrives separately with a stable
-- sequence and object-token diagnostics. It must be preferred by the runtime
-- and preserve total/hit conservation without going through aggregation.
do
local native_event_boss = boss_actor("BP_RaidBoss_NativeEvent_C_500")
local native_event_index = 0
BossDPSNativeDrainEventOne = function()
    native_event_index = native_event_index + 1
    if native_event_index <= 3 then
        return true, {
            api_version = 2,
            kind = "damage",
            sequence = native_event_index,
            captured_ns = native_event_index * 100,
            attacker = player_one,
            defender = native_event_boss,
            damage = 100 + native_event_index,
            hits = 1,
            target_key = "0xDEF",
            attacker_id = "1:1",
            defender_id = "2:1",
            evidence_kind = "unresolved",
        }
    end
    return false
end
BossDPSBroadcastTestApi.hooks.damage_mode = "native-event"
local native_events_before = BossDPSBroadcastTestApi.metrics.native_events
local native_event_hits_before = BossDPSBroadcastTestApi.metrics.native_hits
phase = "game"
BossDPSBroadcastTestApi.drain_native_damage()
phase = "bootstrap"
local native_event_session
for _, candidate in pairs(BossDPSBroadcastTestApi.sessions) do
    if candidate.name == "RaidBoss_NativeEvent" then
        native_event_session = candidate
        break
    end
end
assert(native_event_session ~= nil, "native event stream did not start a boss session")
assert(native_event_session.total_damage == 306,
    "native event stream changed per-hit total damage")
assert(BossDPSBroadcastTestApi.metrics.native_events - native_events_before == 3,
    "native event metric is incorrect")
assert(BossDPSBroadcastTestApi.metrics.native_hits - native_event_hits_before == 3,
    "native event stream changed hit conservation")
death(native_event_boss)
run_game_tasks()
run_delayed_tasks()
end

-- Native event API v2 positional tuple: keep parity with the table payload
-- above. The bridge returns `true` followed by exactly 27 payload fields;
-- Lua must reconstruct one event table per hit without losing damage or hits.
do
local positional = {
    boss = boss_actor("BP_RaidBoss_NativePositionalEvent_C_501"),
    index = 0,
}
BossDPSNativeDrainEventOne = function()
    positional.index = positional.index + 1
    if positional.index <= 3 then
        return true,
            2,                                      -- api_version (1)
            "damage",                               -- kind (2)
            positional.index,                        -- sequence (3)
            positional.index * 1000,                 -- captured_ns (4)
            200 + positional.index,                  -- damage (5)
            1,                                       -- hits (6)
            "unresolved",                            -- evidence_kind (7)
            player_one,                              -- attacker (8)
            positional.boss,                         -- defender (9)
            nil,                                     -- damage_causer (10)
            nil,                                     -- override_network_owner (11)
            nil,                                     -- info_attacker (12)
            "1:1",                                   -- attacker_id (13)
            "3:1",                                   -- defender_id (14)
            "0:0",                                   -- damage_causer_id (15)
            "0:0",                                   -- override_network_owner_id (16)
            "0:0",                                   -- info_attacker_id (17)
            "damage-info:" .. positional.index,      -- damage_info_id (18)
            "action:" .. positional.index,           -- action_id (19)
            "cast:" .. positional.index,             -- cast_id (20)
            "effect:" .. positional.index,           -- effect_id (21)
            "filter:" .. positional.index,           -- filter_id (22)
            "0:0",                                   -- status_application_id (23)
            "0xPOS",                                 -- target_key (24)
            0,                                       -- waza_id (25)
            "",                                      -- skill_code (26)
            ""                                       -- status_code (27)
    end
    return false
end
BossDPSBroadcastTestApi.hooks.damage_mode = "native-event"
positional.events_before = BossDPSBroadcastTestApi.metrics.native_events
positional.hits_before = BossDPSBroadcastTestApi.metrics.native_hits
phase = "game"
BossDPSBroadcastTestApi.drain_native_damage()
phase = "bootstrap"
for _, candidate in pairs(BossDPSBroadcastTestApi.sessions) do
    if candidate.name == "RaidBoss_NativePositionalEvent" then
        positional.session = candidate
        break
    end
end
assert(positional.session ~= nil,
    "positional native event tuple did not start a boss session")
assert(positional.session.total_damage == 606,
    "positional native event tuple changed per-hit total damage")
positional.contributor_damage = 0
positional.contributor_hits = 0
for _, contributor in pairs(positional.session.contributors) do
    positional.contributor_damage = positional.contributor_damage + contributor.damage
    positional.contributor_hits = positional.contributor_hits + contributor.hits
end
assert(positional.contributor_damage == positional.session.total_damage,
    "positional native event tuple violated contributor/session damage conservation")
assert(positional.contributor_hits == 3,
    "positional native event tuple violated contributor hit conservation")
assert(BossDPSBroadcastTestApi.metrics.native_events - positional.events_before == 3,
    "positional native event tuple changed event conservation")
assert(BossDPSBroadcastTestApi.metrics.native_hits - positional.hits_before == 3,
    "positional native event tuple changed native hit conservation")
death(positional.boss)
run_game_tasks()
run_delayed_tasks()
end

-- Native exact source proof: when the C++ collector observes a Blueprint
-- attack delegate whose PalAttackFilter still carries its Waza ID, Lua must
-- put the final damage into that skill instead of the unresolved bucket.
do
local exact_native = {
    boss = boss_actor("BP_RaidBoss_NativeEffectWaza_C_502"),
    index = 0,
    parameter = object({ SaveParameter = { EquipWaza = { 501, 602, 601 } } }),
}
exact_native.pal = actor("BP_PinkCat_ExactNative_C_502", {
    CharacterParameterComponent = object({ IndividualParameter = exact_native.parameter }),
})
trainer_by_actor[exact_native.pal] = player_two
BossDPSNativeDrainEventOne = function()
    exact_native.index = exact_native.index + 1
    if exact_native.index == 1 then
        return true,
            2,                                      -- api_version (1)
            "damage",                              -- kind (2)
            7001,                                   -- sequence (3)
            7001000,                                -- captured_ns (4)
            777,                                    -- damage (5)
            2,                                      -- hits (6)
            "effect_waza",                         -- evidence_kind (7)
            exact_native.pal,                       -- attacker (8)
            exact_native.boss,                      -- defender (9)
            nil,                                    -- damage_causer (10)
            nil,                                    -- override_network_owner (11)
            nil,                                    -- info_attacker (12)
            "3:1",                                 -- attacker_id (13)
            "502:1",                               -- defender_id (14)
            "0:0",                                 -- damage_causer_id (15)
            "0:0",                                 -- override_network_owner_id (16)
            "0:0",                                 -- info_attacker_id (17)
            "",                                    -- damage_info_id (18)
            "",                                    -- action_id (19)
            "",                                    -- cast_id (20)
            "400:9",                               -- effect_id (21)
            "401:9",                               -- filter_id (22)
            "0:0",                                 -- status_application_id (23)
            "0xEXACT",                             -- target_key (24)
            602,                                    -- waza_id (25)
            "DiamondFall",                         -- skill_code (26)
            ""                                     -- status_code (27)
    elseif exact_native.index == 2 then
        return true,
            2, "damage", 7002, 7002000, 123, 1,
            "damage_info_fingerprint_candidate",
            exact_native.pal, exact_native.boss, nil, nil, nil,
            "3:1", "502:1", "0:0", "0:0", "0:0", "",
            "", "", "402:9", "403:9", "0:0", "0xEXACT",
            602, "DiamondFall", ""
    elseif exact_native.index == 3 then
        return true,
            2, "damage", 7003, 7003000, 222, 1,
            "effect_pair_single_link",
            exact_native.pal, exact_native.boss, nil, nil, nil,
            "3:1", "502:1", "0:0", "0:0", "0:0", "",
            "action:single", "cast:single", "404:9", "405:9", "0:0", "0xEXACT",
            602, "DiamondFall", ""
    elseif exact_native.index == 4 then
        return true,
            2, "damage", 7004, 7004000, 333, 1,
            "effect_pair_agreed_link",
            exact_native.pal, exact_native.boss, nil, nil, nil,
            "3:1", "502:1", "0:0", "0:0", "0:0", "",
            "action:agreed", "cast:agreed", "406:9", "407:9", "0:0", "0xEXACT",
            602, "DiamondFall", ""
    elseif exact_native.index == 5 then
        return true,
            2, "damage", 7005, 7005000, 111, 1,
            "unresolved_effect_pair_ambiguous",
            exact_native.pal, exact_native.boss, nil, nil, nil,
            "3:1", "502:1", "0:0", "0:0", "0:0", "",
            "", "", "", "", "0:0", "0xEXACT",
            602, "DiamondFall", ""
    elseif exact_native.index == 6 then
        return true,
            2, "damage", 7006, 7006000, 444, 1,
            "post_effect_pair_single_link",
            exact_native.pal, exact_native.boss, nil, nil, nil,
            "3:1", "502:1", "0:0", "0:0", "0:0", "",
            "action:reverse", "cast:reverse", "408:9", "409:9", "0:0", "0xEXACT",
            602, "DiamondFall", ""
    elseif exact_native.index == 7 then
        return true,
            2, "damage", 7007, 7007000, 222, 1,
            "post_effect_pair_batch_candidate",
            exact_native.pal, exact_native.boss, nil, nil, nil,
            "3:1", "502:1", "0:0", "0:0", "0:0", "",
            "action:batch", "cast:batch", "410:9", "411:9", "0:0", "0xEXACT",
            602, "DiamondFall", ""
    elseif exact_native.index == 8 then
        return true,
            2, "damage", 7008, 7008000, 4414, 1,
            "unresolved_post_effect_timeout",
            exact_native.pal, exact_native.boss, nil, nil, nil,
            "3:1", "502:1", "0:0", "0:0", "0:0", "",
            "", "", "", "", "0:0", "0xEXACT",
            0, "", ""
    end
    return false
end
BossDPSBroadcastTestApi.hooks.damage_mode = "native-event"
phase = "game"
BossDPSBroadcastTestApi.drain_native_damage()
phase = "bootstrap"
for _, candidate in pairs(BossDPSBroadcastTestApi.sessions) do
    if candidate.name == "RaidBoss_NativeEffectWaza" then
        exact_native.session = candidate
        break
    end
end
assert(exact_native.session ~= nil and exact_native.session.total_damage == 6646,
    "exact native effect/fingerprint events did not preserve final damage")
for _, source in pairs(exact_native.session.diagnostic_sources) do
    if source.kind == "pal" then
        exact_native.source = source
        break
    end
end
assert(exact_native.source ~= nil,
    "exact native effect/Waza event did not retain the Pal source")
exact_native.skill = exact_native.source.skill_candidates["skill:DiamondFall"]
assert(exact_native.skill ~= nil
        and exact_native.skill.damage == 6412
        and exact_native.skill.hits == 7
        and exact_native.skill.waza_id == 602
        and exact_native.skill.exact_damage == 1776
        and exact_native.skill.inferred_damage == 4636,
    "exact native effect/pair links did not enter the DiamondFall bucket")
exact_native.unresolved_damage = 0
for key in pairs(exact_native.source.skill_candidates) do
    if string.find(key, "UNRESOLVED", 1, true) ~= nil
        or string.find(key, "UNKNOWN", 1, true) ~= nil then
        exact_native.unresolved_damage = exact_native.unresolved_damage
            + exact_native.source.skill_candidates[key].damage
    end
end
assert(exact_native.unresolved_damage == 234,
    "fingerprint or ambiguous pair evidence was promoted instead of failing closed")
death(exact_native.boss)
run_game_tasks()
run_delayed_tasks()
end

-- A native unresolved direct impact may still be assigned when the
-- DamageInfo-backed marker for the same pair was already linked to one exact
-- cast and the Waza is in the complete equipped loadout. The old cast must keep
-- ownership after it ends and IcicleThrow begins; current-action timing remains
-- fail-closed and cannot steal the delayed DoubleIcicleThrow impact.
do
local active_pair_parameter = object({
    SaveParameter = { EquipWaza = { 156, 186, 116 } },
})
local active_pair_component = object({ IndividualParameter = active_pair_parameter })
local active_pair_action = nil
local active_pair_action_component = object({}, {
    GetCurrentAction = function() return active_pair_action end,
})
local active_pair_pal = actor("BP_CatVampire_ActivePair_C_504", {
    CharacterParameterComponent = active_pair_component,
    ActionComponent = active_pair_action_component,
})
trainer_by_actor[active_pair_pal] = player_two
local active_pair_boss = boss_actor("BP_RaidBoss_ActivePair_C_505")
local active_pair_session = {
    aoe_boss = boss_actor("BP_RaidBoss_ActivePairAOE_C_506"),
}
active_pair_action = actor("BP_ActionDoubleIcicleThrow_C_2147999504", {
    GetWazaID = function() return 186 end,
    GetActionCharacter = function() return active_pair_pal end,
})
fake_game_time = 3400
action_begin(active_pair_action)
run_game_tasks()
waza(active_pair_pal, active_pair_boss, 186, object({
    BasePower = 700,
    AttackElementType = 6,
    WazaID = 186,
}))
run_game_tasks()
fake_game_time = 3400.5
action_end(active_pair_action)
run_game_tasks()
active_pair_action = actor("BP_ActionIcicleThrow_C_2147999505", {
    GetWazaID = function() return 116 end,
    GetActionCharacter = function() return active_pair_pal end,
})
fake_game_time = 3400.6
action_begin(active_pair_action)
run_game_tasks()

local active_pair_index = 0
BossDPSNativeDrainEventOne = function()
    active_pair_index = active_pair_index + 1
    if active_pair_index == 1 then
        return true, {
            api_version = 2,
            kind = "damage",
            sequence = 7101,
            captured_ns = 7101000,
            damage = 48794,
            hits = 1,
            evidence_kind = "unresolved_post_effect_timeout",
            attacker = active_pair_pal,
            defender = active_pair_boss,
            target_key = "0xACTIVEPAIR",
            waza_id = 0,
            skill_code = "",
        }
    elseif active_pair_index == 2 then
        return true, {
            api_version = 2,
            kind = "damage",
            sequence = 7102,
            captured_ns = 7102000,
            damage = 50128,
            hits = 1,
            evidence_kind = "unresolved_post_effect_timeout",
            attacker = active_pair_pal,
            defender = active_pair_session.aoe_boss,
            target_key = "0xACTIVEPAIRAOE",
            waza_id = 0,
            skill_code = "",
        }
    end
    return false
end
BossDPSBroadcastTestApi.hooks.damage_mode = "native-event"
phase = "game"
BossDPSBroadcastTestApi.drain_native_damage()
phase = "bootstrap"

for _, candidate in pairs(BossDPSBroadcastTestApi.sessions) do
    if candidate.name == "RaidBoss_ActivePair" then
        active_pair_session.primary = candidate
    elseif candidate.name == "RaidBoss_ActivePairAOE" then
        active_pair_session.aoe_session = candidate
    end
end
local active_pair_source
for _, source in pairs(active_pair_session.primary
        and active_pair_session.primary.diagnostic_sources or {}) do
    if source.kind == "pal" then active_pair_source = source end
end
local active_pair_skill = active_pair_source
    and active_pair_source.skill_candidates["skill:DoubleIcicleThrow"] or nil
assert(active_pair_skill ~= nil
        and active_pair_skill.damage == 48794
        and active_pair_skill.inferred_damage == 48794,
    "ended cast did not retain its delayed DoubleIcicleThrow impact")
assert(active_pair_source.skill_candidates["skill:IcicleThrow"] == nil
        or active_pair_source.skill_candidates["skill:IcicleThrow"].damage == 0,
    "the newer IcicleThrow action stole delayed DoubleIcicleThrow damage")
active_pair_session.aoe_source = active_pair_session.aoe_session
    and select(2, next(active_pair_session.aoe_session.diagnostic_sources)) or nil
assert(active_pair_session.aoe_source ~= nil
        and active_pair_session.aoe_source.skill_candidates["skill:DoubleIcicleThrow"] ~= nil
        and active_pair_session.aoe_source.skill_candidates["skill:DoubleIcicleThrow"].damage == 50128,
    "one linked AOE cast did not cover its unmarked secondary target")
fake_game_time = 3401
action_end(active_pair_action)
run_game_tasks()
death(active_pair_boss)
death(active_pair_session.aoe_boss)
run_game_tasks()
run_delayed_tasks()
end

-- Real hard-tower captures show the final ice-projectile impact arriving about
-- 1.1 seconds after the linked batch. Preserve that same-skill link, but fail
-- closed when a different linked skill exists in the same window.
do
local trailing_pal = actor("BP_CatVampire_TrailingImpact_C_507")
local trailing_boss = boss_actor("BP_RaidBoss_TrailingImpact_C_508")
local trailing_profile = {
    equipped_waza_count = 3,
    equipped_waza_ids = { [156] = true, [186] = true, [116] = true },
    equipped_waza_codes = {
        DiamondFall = true,
        DoubleIcicleThrow = true,
        IcicleThrow = true,
    },
}
local linked_batch = {
    api_version = 2,
    attacker = trailing_pal,
    defender = trailing_boss,
    cast_key = "cast:trailing-double",
    diagnostic_fields = {
        ["waza.ID"] = 186,
        ["waza.Name"] = "DoubleIcicleThrow",
        ["waza.LocalizedName"] = "極寒雙星",
        ["attribution.Source"] = "inferred_post_effect_pair_batch",
    },
}
phase = "game"
BossDPSBroadcastTestApi.hooks.remember_exact_pair_hit(linked_batch, "pal")
for _, bucket in pairs(BossDPSBroadcastTestApi.hooks.recent_exact_hits_by_pair) do
    local marker = bucket[#bucket]
    if marker ~= nil and marker.cast_id == "cast:trailing-double" then
        marker.clock = os.clock() - 1.1
    end
end
local trailing_event = {
    api_version = 2,
    sequence = 7201,
    evidence_kind = "unresolved_post_effect_timeout",
    attacker = trailing_pal,
    defender = trailing_boss,
    diagnostic_fields = {},
}
assert(BossDPSBroadcastTestApi.hooks.infer_native_recent_exact_pair_hit(
        trailing_event, trailing_pal, "pal", trailing_profile)
        and trailing_event.diagnostic_fields["waza.Name"] == "DoubleIcicleThrow",
    "the 1.1-second trailing ice impact lost its linked batch skill")
phase = "idle"
end

-- CommetRain can emit four child Commet Waza markers before four large meteor
-- impacts. Each child marker must promote exactly one unresolved hit to the
-- equipped parent, in queue order, across repeated waves. The fourth impact
-- can arrive 4.08 seconds after the last exact parent hit while remaining only
-- about one second behind its own child marker.
do
local meteor_pal = actor("BP_WhiteMothDragon_CommetRain_C_511")
local meteor_boss = boss_actor("BP_RaidBoss_CommetRain_C_512")
phase = "game"
local meteor_profile = {
    equipped_waza_count = 3,
    equipped_waza_ids = { [177] = true, [202] = true, [203] = true },
    equipped_waza_codes = {
        CommetRain = true,
        ThunderStorm = true,
        ThunderSword = true,
    },
}
local meteor_sequence = 7300
for wave = 1, 3 do
    BossDPSBroadcastTestApi.hooks.remember_exact_pair_hit({
        api_version = 2,
        attacker = meteor_pal,
        defender = meteor_boss,
        cast_key = "cast:commet-rain-" .. tostring(wave),
        diagnostic_fields = {
            ["waza.ID"] = 177,
            ["waza.Name"] = "CommetRain",
            ["waza.LocalizedName"] = "隕星雨",
            ["attribution.Source"] = "effect_waza",
        },
    }, "pal")

    local markers = {}
    for index, age in ipairs({ 1.04, 0.60, 0.30, 0.10 }) do
        markers[index] = BossDPSBroadcastTestApi.process_waza_marker({
            attacker = meteor_pal,
            defender = meteor_boss,
            waza_id = 158,
            captured_at = os.time(),
            captured_clock = os.clock() - age,
        })
    end
    assert(markers[1] ~= nil and markers[1].id == 158
            and markers[1].name == "Commet",
        "Commet child marker was not captured")
    assert(BossDPSBroadcastTestApi.hooks.select_child_waza_parent_marker(
            { attacker = meteor_pal, defender = meteor_boss },
            BossDPSBroadcastTestApi.hooks.native_child_waza_parent_rules.Commet) ~= nil,
        "the oldest eligible Commet child marker was not selected")
    assert(BossDPSBroadcastTestApi.hooks.select_child_waza_parent_anchor(
            { attacker = meteor_pal, defender = meteor_boss },
            BossDPSBroadcastTestApi.hooks.native_child_waza_parent_rules.Commet) ~= nil,
        "the recent exact CommetRain parent anchor was not selected")

    local parent_anchor = BossDPSBroadcastTestApi.hooks.select_child_waza_parent_anchor(
        { attacker = meteor_pal, defender = meteor_boss },
        BossDPSBroadcastTestApi.hooks.native_child_waza_parent_rules.Commet)
    for impact = 1, 4 do
        if impact > 1 then
            markers[impact].clock = os.clock() - 1.02
        end
        parent_anchor.clock = os.clock() - (2.5 + ((impact - 1) * 0.5))
        meteor_sequence = meteor_sequence + 1
        local event = {
            api_version = 2,
            sequence = meteor_sequence,
            evidence_kind = "unresolved_post_effect_timeout",
            attacker = meteor_pal,
            defender = meteor_boss,
            diagnostic_fields = {},
        }
        assert(BossDPSBroadcastTestApi.hooks.infer_native_child_waza_parent(
                event, meteor_pal, "pal", meteor_profile),
            "CommetRain wave " .. tostring(wave) .. " impact "
                .. tostring(impact) .. " stayed unresolved")
        assert(event.diagnostic_fields["waza.ID"] == 177
                and event.diagnostic_fields["waza.Name"] == "CommetRain"
                and event.diagnostic_fields["inference.ChildWazaID"] == 158
                and event.diagnostic_fields["inference.ChildWazaName"] == "Commet"
                and markers[impact].matches == 1,
            "Commet child impact was not promoted exactly once to CommetRain")
    end
end
local extra_meteor = {
    api_version = 2,
    sequence = meteor_sequence + 1,
    evidence_kind = "unresolved_post_effect_timeout",
    attacker = meteor_pal,
    defender = meteor_boss,
    diagnostic_fields = {},
}
assert(not BossDPSBroadcastTestApi.hooks.infer_native_child_waza_parent(
        extra_meteor, meteor_pal, "pal", meteor_profile),
    "one consumed Commet marker attributed more than one meteor impact")
phase = "idle"
end

-- If the exact hit bridge is absent altogether, one unique recently completed
-- delayed ice action may own the native timeout. Two different eligible
-- delayed actions remain ambiguous and must not be guessed.
do
local delayed_parameter = object({ SaveParameter = { EquipWaza = { 156, 186, 116 } } })
local delayed_pal = actor("BP_CatVampire_UniqueDelayedAction_C_509", {
    CharacterParameterComponent = object({ IndividualParameter = delayed_parameter }),
})
local delayed_boss = boss_actor("BP_RaidBoss_UniqueDelayedAction_C_510")
local delayed_profile = {
    equipped_waza_count = 3,
    equipped_waza_ids = { [156] = true, [186] = true, [116] = true },
    equipped_waza_codes = {
        DiamondFall = true,
        DoubleIcicleThrow = true,
        IcicleThrow = true,
    },
}
local delayed_action = actor("BP_ActionIcicleThrow_C_2147999510", {
    GetWazaID = function() return 116 end,
    GetActionCharacter = function() return delayed_pal end,
})
fake_game_time = 3450
action_begin(delayed_action)
run_game_tasks()
fake_game_time = 3450.5
action_end(delayed_action)
run_game_tasks()
fake_game_time = 3451.6
local delayed_event = {
    api_version = 2,
    sequence = 7202,
    evidence_kind = "unresolved_post_effect_timeout",
    attacker = delayed_pal,
    defender = delayed_boss,
    diagnostic_fields = {},
}
phase = "game"
assert(BossDPSBroadcastTestApi.hooks.infer_native_unique_delayed_action(
        delayed_event, delayed_pal, "pal", delayed_profile)
        and delayed_event.diagnostic_fields["waza.Name"] == "IcicleThrow",
    "one unique completed delayed ice action did not own its final impact")
phase = "idle"

local conflicting_action = actor("BP_ActionDoubleIcicleThrow_C_2147999511", {
    GetWazaID = function() return 186 end,
    GetActionCharacter = function() return delayed_pal end,
})
fake_game_time = 3451.6
action_begin(conflicting_action)
run_game_tasks()
fake_game_time = 3451.7
action_end(conflicting_action)
run_game_tasks()
fake_game_time = 3451.8
local ambiguous_event = {
    api_version = 2,
    sequence = 7203,
    evidence_kind = "unresolved_post_effect_timeout",
    attacker = delayed_pal,
    defender = delayed_boss,
    diagnostic_fields = {},
}
phase = "game"
assert(not BossDPSBroadcastTestApi.hooks.infer_native_unique_delayed_action(
        ambiguous_event, delayed_pal, "pal", delayed_profile)
        and ambiguous_event.diagnostic_fields["waza.Name"] == nil,
    "two different delayed ice actions were guessed through")
phase = "idle"
end

-- Live regression: Twin Spears exposes its exact Action/cast, but seven native
-- final hits carry no Waza/effect identity. Hits observed while the action is
-- active establish one pair/cast binding; only that same binding may retain the
-- measured short tail after OnEndAction and a newer skill begins. The seventh
-- hit reproduces the 2026-08-20 live 20,244 tail, which arrived 0.847 seconds
-- after the preceding segment without another native damage sequence between.
do
local rush_parameter = object({ SaveParameter = { EquipWaza = { 165, 187, 205 } } })
local rush_pal = actor("BP_BlackCentaur_BoundAction_C_511", {
    CharacterParameterComponent = object({ IndividualParameter = rush_parameter }),
})
local rush_boss = boss_actor("BP_RaidBoss_BoundAction_C_512")
local rush_profile = {
    equipped_waza_count = 3,
    equipped_waza_ids = { [165] = true, [187] = true, [205] = true },
    equipped_waza_codes = {
        Apocalypse = true,
        IceAge = true,
        Unique_BlackCentaur_TwoSpearRushes = true,
    },
}
local rush_damage = { 38168, 40992, 37749, 38446, 40450, 644, 20244 }
local rush_total = 0
local rush_cast_keys = {}
local rush_sequence = 7300
local function infer_rush_hit(amount)
    rush_sequence = rush_sequence + 1
    local event = {
        api_version = 2,
        sequence = rush_sequence,
        evidence_kind = "unresolved_post_effect_timeout",
        attacker = rush_pal,
        defender = rush_boss,
        diagnostic_fields = {},
    }
    phase = "game"
    local inferred = BossDPSBroadcastTestApi.hooks.infer_native_bound_action(
        event, rush_pal, "pal", rush_profile)
    phase = "idle"
    assert(inferred,
        "Twin Spears native hit did not bind to its exact active cast")
    assert(event.diagnostic_fields["waza.Name"]
            == "Unique_BlackCentaur_TwoSpearRushes",
        "Twin Spears native hit entered the wrong skill")
    rush_total = rush_total + amount
    rush_cast_keys[#rush_cast_keys + 1] = event.diagnostic_fields["inference.CastKey"]
end

local rush_action_one = actor(
    "BP_ActionUnique_BlackCentaur_TwoSpearRushes_C_2147999512", {
        GetWazaID = function() return 205 end,
        GetActionCharacter = function() return rush_pal end,
    })
fake_game_time = 3500
action_begin(rush_action_one)
run_game_tasks()
fake_game_time = 3503.45
infer_rush_hit(rush_damage[1])
fake_game_time = 3503.65
infer_rush_hit(rush_damage[2])
fake_game_time = 3503.80
action_end(rush_action_one)
run_game_tasks()
local rush_next_action = actor("BP_ActionIceAge_C_2147999513", {
    GetWazaID = function() return 187 end,
    GetActionCharacter = function() return rush_pal end,
})
fake_game_time = 3503.83
action_begin(rush_next_action)
run_game_tasks()
fake_game_time = 3503.85
infer_rush_hit(rush_damage[3])
fake_game_time = 3504.00
infer_rush_hit(rush_damage[4])
fake_game_time = 3504.50
action_end(rush_next_action)
run_game_tasks()
fake_game_time = 3504.847
infer_rush_hit(rush_damage[7])

local rush_action_two = actor(
    "BP_ActionUnique_BlackCentaur_TwoSpearRushes_C_2147999514", {
        GetWazaID = function() return 205 end,
        GetActionCharacter = function() return rush_pal end,
    })
fake_game_time = 3535
action_begin(rush_action_two)
run_game_tasks()
fake_game_time = 3538.20
infer_rush_hit(rush_damage[5])
fake_game_time = 3538.37
infer_rush_hit(rush_damage[6])
fake_game_time = 3538.50
action_end(rush_action_two)
run_game_tasks()

assert(rush_total == 216693, "Twin Spears seven-hit live regression total changed")
assert(rush_cast_keys[1] == rush_cast_keys[2]
        and rush_cast_keys[2] == rush_cast_keys[3]
        and rush_cast_keys[3] == rush_cast_keys[4]
        and rush_cast_keys[4] == rush_cast_keys[5],
    "Twin Spears first cast lost its short-tail binding")
assert(rush_cast_keys[6] == rush_cast_keys[7]
        and rush_cast_keys[6] ~= rush_cast_keys[1],
    "Twin Spears second cast reused the wrong binding")

fake_game_time = 3539.75
local stale_rush_event = {
    api_version = 2,
    sequence = 7308,
    evidence_kind = "unresolved_post_effect_timeout",
    attacker = rush_pal,
    defender = rush_boss,
    diagnostic_fields = {},
}
phase = "game"
local stale_rush_inferred = BossDPSBroadcastTestApi.hooks.infer_native_bound_action(
    stale_rush_event, rush_pal, "pal", rush_profile)
phase = "idle"
assert(not stale_rush_inferred
        and stale_rush_event.diagnostic_fields["waza.Name"] == nil,
    "expired Twin Spears binding guessed a later unrelated hit")

;(function()
local rush_action_guard = actor(
    "BP_ActionUnique_BlackCentaur_TwoSpearRushes_C_2147999515", {
        GetWazaID = function() return 205 end,
        GetActionCharacter = function() return rush_pal end,
    })
fake_game_time = 3570
action_begin(rush_action_guard)
run_game_tasks()
local guard_seed_event = {
    api_version = 2,
    sequence = 7401,
    evidence_kind = "unresolved_post_effect_timeout",
    attacker = rush_pal,
    defender = rush_boss,
    diagnostic_fields = {},
}
phase = "game"
assert(BossDPSBroadcastTestApi.hooks.infer_native_bound_action(
        guard_seed_event, rush_pal, "pal", rush_profile),
    "Twin Spears guard binding was not established")
phase = "idle"
fake_game_time = 3570.2
action_end(rush_action_guard)
run_game_tasks()
fake_game_time = 3571.1
local interleaved_rush_event = {
    api_version = 2,
    sequence = 7403,
    evidence_kind = "unresolved_post_effect_timeout",
    attacker = rush_pal,
    defender = rush_boss,
    diagnostic_fields = {},
}
phase = "game"
local interleaved_rush_inferred =
    BossDPSBroadcastTestApi.hooks.infer_native_bound_action(
        interleaved_rush_event, rush_pal, "pal", rush_profile)
phase = "idle"
assert(not interleaved_rush_inferred
        and interleaved_rush_event.diagnostic_fields["waza.Name"] == nil,
    "Twin Spears extended tail guessed through another native damage sequence")
end)()
end

-- Live regression: Flash Charge produces one source-less native hit while its
-- exact equipped Action is still active. Three consecutive live casts dealt
-- 5,928, 5,429 and 5,270 damage at 2.189-2.550 seconds after OnBeginAction.
-- Attribute only that single in-action hit; do not accept an early callback, a
-- second unresolved hit in the same cast, or any callback after OnEndAction.
;(function()
local tossin_parameter = object({ SaveParameter = { EquipWaza = { 181, 257, 300 } } })
local tossin_pal = actor("BP_BlueThunderHorse_BoundAction_C_513", {
    CharacterParameterComponent = object({ IndividualParameter = tossin_parameter }),
})
local tossin_boss = boss_actor("BP_RaidBoss_BlueThunderHorse_C_514")
local tossin_profile = {
    equipped_waza_count = 3,
    equipped_waza_ids = { [181] = true, [257] = true, [300] = true },
    equipped_waza_codes = {
        Railbolt = true,
        Unique_BlueThunderHorse_FlashDash = true,
        Unique_BlueThunderHorse_Tossin = true,
    },
}
local tossin_damage = { 5928, 5429, 5270 }
local tossin_hit_age = { 2.189, 2.550, 2.202 }
local tossin_total = 0
local tossin_sequence = 7500

local function tossin_event()
    tossin_sequence = tossin_sequence + 1
    return {
        api_version = 2,
        sequence = tossin_sequence,
        evidence_kind = "unresolved_post_effect_timeout",
        attacker = tossin_pal,
        defender = tossin_boss,
        diagnostic_fields = {},
    }
end

for index, amount in ipairs(tossin_damage) do
    local started_at = 3600 + ((index - 1) * 30)
    local action = actor(
        "BP_ActionUnique_BlueThunderHorse_Tossin_C_214799952" .. tostring(index), {
            GetWazaID = function() return 300 end,
            GetActionCharacter = function() return tossin_pal end,
        })
    fake_game_time = started_at
    action_begin(action)
    run_game_tasks()

    if index == 1 then
        fake_game_time = started_at + 1.4
        local early_event = tossin_event()
        phase = "game"
        local early_inferred = BossDPSBroadcastTestApi.hooks.infer_native_bound_action(
            early_event, tossin_pal, "pal", tossin_profile)
        phase = "idle"
        assert(not early_inferred and early_event.diagnostic_fields["waza.Name"] == nil,
            "Flash Charge guessed an unresolved hit before its verified impact window")
    end

    fake_game_time = started_at + tossin_hit_age[index]
    local event = tossin_event()
    phase = "game"
    local inferred = BossDPSBroadcastTestApi.hooks.infer_native_bound_action(
        event, tossin_pal, "pal", tossin_profile)
    phase = "idle"
    assert(inferred
            and event.diagnostic_fields["waza.Name"]
                == "Unique_BlueThunderHorse_Tossin",
        "Flash Charge live hit did not bind to its exact active cast")
    tossin_total = tossin_total + amount

    if index == 1 then
        fake_game_time = started_at + tossin_hit_age[index] + 0.1
        local duplicate_event = tossin_event()
        phase = "game"
        local duplicate_inferred =
            BossDPSBroadcastTestApi.hooks.infer_native_bound_action(
                duplicate_event, tossin_pal, "pal", tossin_profile)
        phase = "idle"
        assert(not duplicate_inferred
                and duplicate_event.diagnostic_fields["waza.Name"] == nil,
            "Flash Charge accepted a second unresolved hit in one cast")
    end

    fake_game_time = started_at + 3.85
    action_end(action)
    run_game_tasks()
end

assert(tossin_total == 16627,
    "Flash Charge three-cast live regression total changed")
fake_game_time = 3663.90
local post_action_event = tossin_event()
phase = "game"
local post_action_inferred = BossDPSBroadcastTestApi.hooks.infer_native_bound_action(
    post_action_event, tossin_pal, "pal", tossin_profile)
phase = "idle"
assert(not post_action_inferred
        and post_action_event.diagnostic_fields["waza.Name"] == nil,
    "Flash Charge guessed an unresolved hit after OnEndAction")
end)()

-- Live regression: Mummy Rush is one 500-power cast split across four final
-- hits. Two observed full casts produced four consecutive source-less native
-- hits, with the last swings landing no more than 0.323 seconds after
-- OnEndAction. A third cast missed its opening swings and produced only two
-- callbacks, 0.014 and 0.341 seconds after OnEndAction. Bind those verified
-- patterns to the exact cast and reject early, interleaved, fifth, and stale
-- callbacks.
;(function()
local mummy_parameter = object({ SaveParameter = { EquipWaza = { 165, 174, 307 } } })
local mummy_pal = actor("BP_MummyPal_BoundAction_C_515", {
    CharacterParameterComponent = object({ IndividualParameter = mummy_parameter }),
})
local mummy_boss = boss_actor("BP_RaidBoss_MummyPal_C_516")
local mummy_profile = {
    equipped_waza_count = 3,
    equipped_waza_ids = { [165] = true, [174] = true, [307] = true },
    equipped_waza_codes = {
        Apocalypse = true,
        SandTwister = true,
        Unique_MummyPal_MummyAttack = true,
    },
}
local mummy_sequence = 7600
local function mummy_event(sequence_step)
    mummy_sequence = mummy_sequence + (sequence_step or 1)
    return {
        api_version = 2,
        sequence = mummy_sequence,
        evidence_kind = "unresolved_post_effect_timeout",
        attacker = mummy_pal,
        defender = mummy_boss,
        diagnostic_fields = {},
    }
end
local function infer_mummy_hit(sequence_step)
    local event = mummy_event(sequence_step)
    phase = "game"
    local inferred = BossDPSBroadcastTestApi.hooks.infer_native_bound_action(
        event, mummy_pal, "pal", mummy_profile)
    phase = "idle"
    return inferred, event
end

local live_casts = {
    {
        started_at = 3700,
        ended_at = 3704.201,
        hit_ages = { 2.148, 3.186, 4.242, 4.508 },
        damage = { 1439, 1628, 1430, 1518 },
    },
    {
        started_at = 3730,
        ended_at = 3734.195,
        hit_ages = { 2.160, 3.128, 4.195, 4.518 },
        damage = { 1746, 1537, 1577, 1465 },
    },
}
local live_totals = {}
for cast_index, capture in ipairs(live_casts) do
    local action = actor(
        "BP_ActionUnique_MummyPal_MummyAttack_C_214799953" .. tostring(cast_index), {
            GetWazaID = function() return 307 end,
            GetActionCharacter = function() return mummy_pal end,
        })
    fake_game_time = capture.started_at
    action_begin(action)
    run_game_tasks()

    if cast_index == 1 then
        fake_game_time = capture.started_at + 1.95
        local early_inferred, early_event = infer_mummy_hit()
        assert(not early_inferred
                and early_event.diagnostic_fields["waza.Name"] == nil,
            "Mummy Rush guessed a hit before its verified impact window")
    end

    local total = 0
    local cast_key = nil
    for hit_index, age in ipairs(capture.hit_ages) do
        if hit_index == 3 then
            fake_game_time = capture.ended_at
            action_end(action)
            run_game_tasks()
        end
        fake_game_time = capture.started_at + age
        local inferred, event = infer_mummy_hit()
        assert(inferred
                and event.diagnostic_fields["waza.Name"]
                    == "Unique_MummyPal_MummyAttack",
            "Mummy Rush live hit did not bind to its exact cast")
        cast_key = cast_key or event.diagnostic_fields["inference.CastKey"]
        assert(event.diagnostic_fields["inference.CastKey"] == cast_key,
            "Mummy Rush four-hit cast split across cast keys")
        total = total + capture.damage[hit_index]
    end
    live_totals[cast_index] = total

    -- Leave the completed four-hit binding intact after cast one. The first
    -- hit of cast two must replace that stale binding immediately rather than
    -- being sacrificed while the old binding is cleared.
    if cast_index == 2 then
        fake_game_time = capture.started_at + 4.53
        local fifth_inferred, fifth_event = infer_mummy_hit()
        assert(not fifth_inferred
                and fifth_event.diagnostic_fields["waza.Name"] == nil,
            "Mummy Rush accepted a fifth unresolved hit")
    end
end
assert(live_totals[1] == 6015 and live_totals[2] == 6325,
    "Mummy Rush four-hit live regression totals changed")

local guard_action = actor(
    "BP_ActionUnique_MummyPal_MummyAttack_C_2147999533", {
        GetWazaID = function() return 307 end,
        GetActionCharacter = function() return mummy_pal end,
    })
fake_game_time = 3760
action_begin(guard_action)
run_game_tasks()
fake_game_time = 3762.15
local guard_seeded = infer_mummy_hit()
assert(guard_seeded, "Mummy Rush guard binding was not established")
-- A middle swing may miss. The later landed swing still belongs to the same
-- four-swing Action even when the previous landed hit was over 1.15 seconds
-- ago and unrelated global native events advanced the sequence.
fake_game_time = 3764.19
local interleaved_inferred, interleaved_event = infer_mummy_hit(2)
assert(interleaved_inferred
        and interleaved_event.diagnostic_fields["waza.Name"]
            == "Unique_MummyPal_MummyAttack",
    "Mummy Rush rejected a later swing after a missed middle swing")
fake_game_time = 3764.195
local duplicate_inferred, duplicate_event = infer_mummy_hit(0)
assert(not duplicate_inferred
        and duplicate_event.diagnostic_fields["waza.Name"] == nil,
    "Mummy Rush accepted a duplicate native damage sequence")
fake_game_time = 3764.2
action_end(guard_action)
run_game_tasks()
fake_game_time = 3764.56
local stale_inferred, stale_event = infer_mummy_hit()
assert(not stale_inferred and stale_event.diagnostic_fields["waza.Name"] == nil,
    "Mummy Rush accepted a callback beyond its verified action tail")

local tail_only_action = actor(
    "BP_ActionUnique_MummyPal_MummyAttack_C_2147999534", {
        GetWazaID = function() return 307 end,
        GetActionCharacter = function() return mummy_pal end,
    })
fake_game_time = 3790
action_begin(tail_only_action)
run_game_tasks()
fake_game_time = 3794.178
action_end(tail_only_action)
run_game_tasks()
local tail_only_cast_key = nil
local tail_only_hits = {
    { at = 3794.192, damage = 1885 },
    { at = 3794.519, damage = 1994 },
}
local tail_only_total = 0
for _, hit in ipairs(tail_only_hits) do
    fake_game_time = hit.at
    local inferred, event = infer_mummy_hit()
    assert(inferred
            and event.diagnostic_fields["waza.Name"]
                == "Unique_MummyPal_MummyAttack",
        "Mummy Rush failed to bind a verified tail-only hit")
    tail_only_cast_key = tail_only_cast_key
        or event.diagnostic_fields["inference.CastKey"]
    assert(event.diagnostic_fields["inference.CastKey"] == tail_only_cast_key,
        "Mummy Rush tail-only hits split across cast keys")
    tail_only_total = tail_only_total + hit.damage
end
assert(tail_only_total == 3879,
    "Mummy Rush tail-only live regression total changed")
end)()

-- Native exact overlap proof: final hits from sustained skills may arrive
-- after newer casts have started. The collector's per-hit exact Waza/effect
-- source must survive the positional Lua bridge without being rewritten by
-- event order. A hit without that exact source must stay unresolved.
do
local exact_parameter = object({
    SaveParameter = { EquipWaza = { 701, 702, 703 } },
})
local exact_current_action = actor("BP_ActionApocalypse_C_2147999503", {
    GetWazaID = function() return 702 end,
    GetSimpleName = function() return "BP_ActionApocalypse_C_2147999503" end,
})
local exact_action_component = object({}, {
    GetCurrentAction = function() return exact_current_action end,
})
local exact_pal = actor("BP_CatVampire_C_502", {
    CharacterParameterComponent = object({ IndividualParameter = exact_parameter }),
    ActionComponent = exact_action_component,
})
trainer_by_actor[exact_pal] = player_two
local exact_overlap = {
    boss = boss_actor("BP_RaidBoss_NativeExactOverlap_C_503"),
    index = 0,
    events = {
        -- IceAge lands after Apocalypse begins.
        { damage = 80, code = "IceAge", waza = 701, cast = "ice:1", effect = "ice-effect:1" },
        { damage = 101, code = "Apocalypse", waza = 702, cast = "apocalypse:1", effect = "apocalypse-effect:1" },
        { damage = 40, code = "GravityShot", waza = 137, cast = "gravity:1", effect = "gravity-effect:1" },
        -- Apocalypse tail lands after GravityShot begins.
        { damage = 103, code = "Apocalypse", waza = 702, cast = "apocalypse:1", effect = "apocalypse-effect:1" },
        { damage = 55, code = "SandTwister", waza = 703, cast = "sand:1", effect = "sand-effect:1" },
        -- Both sustained skills keep landing after SandTwister begins.
        { damage = 82, code = "IceAge", waza = 701, cast = "ice:1", effect = "ice-effect:1" },
        { damage = 107, code = "Apocalypse", waza = 702, cast = "apocalypse:1", effect = "apocalypse-effect:1" },
        -- Same encounter/signature timing but no exact token.
        { damage = 17, code = "", waza = 0, cast = "", effect = "", unresolved = true },
    },
    expected = {
        IceAge = { damage = 162, hits = 2 },
        Apocalypse = { damage = 311, hits = 3 },
        GravityShot = { damage = 40, hits = 1 },
        SandTwister = { damage = 55, hits = 1 },
    },
}
BossDPSNativeDrainEventOne = function()
    exact_overlap.index = exact_overlap.index + 1
    local event = exact_overlap.events[exact_overlap.index]
    if event == nil then return false end
    return true,
        2,                                          -- api_version (1)
        "damage",                                   -- kind (2)
        8000 + exact_overlap.index,                  -- sequence (3)
        8000000 + exact_overlap.index,               -- captured_ns (4)
        event.damage,                                -- damage (5)
        1,                                           -- hits (6)
        event.unresolved and "unresolved" or "effect_waza", -- evidence_kind (7)
        exact_pal,                                   -- attacker (8)
        exact_overlap.boss,                          -- defender (9)
        nil,                                         -- damage_causer (10)
        nil,                                         -- override_network_owner (11)
        nil,                                         -- info_attacker (12)
        "3:1",                                       -- attacker_id (13)
        "503:1",                                     -- defender_id (14)
        "0:0",                                       -- damage_causer_id (15)
        "0:0",                                       -- override_network_owner_id (16)
        "0:0",                                       -- info_attacker_id (17)
        "",                                          -- damage_info_id (18)
        "",                                          -- action_id (19)
        event.cast,                                  -- cast_id (20)
        event.effect,                                -- effect_id (21)
        event.unresolved and "" or ("filter:" .. event.code), -- filter_id (22)
        "0:0",                                       -- status_application_id (23)
        "0xEXACT-OVERLAP",                           -- target_key (24)
        event.waza,                                  -- waza_id (25)
        event.code,                                  -- skill_code (26)
        ""                                           -- status_code (27)
end
BossDPSBroadcastTestApi.hooks.damage_mode = "native-event"
exact_overlap.events_before = BossDPSBroadcastTestApi.metrics.native_events
exact_overlap.hits_before = BossDPSBroadcastTestApi.metrics.native_hits
phase = "game"
BossDPSBroadcastTestApi.drain_native_damage()
phase = "bootstrap"
for _, candidate in pairs(BossDPSBroadcastTestApi.sessions) do
    if candidate.name == "RaidBoss_NativeExactOverlap" then
        exact_overlap.session = candidate
        break
    end
end
assert(exact_overlap.session ~= nil and exact_overlap.session.total_damage == 585,
    "native exact overlap stream changed final damage total")
for _, source in pairs(exact_overlap.session.diagnostic_sources) do
    if source.kind == "pal" then
        exact_overlap.source = source
        break
    end
end
assert(exact_overlap.source ~= nil,
    "native exact overlap stream did not retain the Pal source")
exact_overlap.damage_sum = 0
exact_overlap.hit_sum = 0
exact_overlap.unresolved_damage = 0
exact_overlap.unresolved_hits = 0
for key, candidate in pairs(exact_overlap.source.skill_candidates) do
    exact_overlap.damage_sum = exact_overlap.damage_sum + candidate.damage
    exact_overlap.hit_sum = exact_overlap.hit_sum + candidate.hits
    if exact_overlap.expected[candidate.name] == nil then
        assert(string.find(key, "UNRESOLVED", 1, true) ~= nil
                or string.find(key, "UNKNOWN", 1, true) ~= nil,
            "native exact overlap created an unexpected skill bucket " .. tostring(key))
        exact_overlap.unresolved_damage = exact_overlap.unresolved_damage + candidate.damage
        exact_overlap.unresolved_hits = exact_overlap.unresolved_hits + candidate.hits
        assert(candidate.exact_damage == 0,
            "missing exact token entered a certain skill bucket")
    end
end
for code, expected in pairs(exact_overlap.expected) do
    local candidate = exact_overlap.source.skill_candidates["skill:" .. code]
    assert(candidate ~= nil
            and candidate.damage == expected.damage
            and candidate.hits == expected.hits,
        "native exact overlap changed " .. code .. " damage/hits")
end
assert(exact_overlap.unresolved_damage == 17 and exact_overlap.unresolved_hits == 1,
    "missing exact token did not remain unresolved")
assert(exact_overlap.damage_sum == exact_overlap.session.total_damage
        and exact_overlap.hit_sum == 8,
    "native exact overlap violated per-skill damage/hit conservation")
assert(BossDPSBroadcastTestApi.metrics.native_events - exact_overlap.events_before == 8,
    "native exact overlap changed event conservation")
assert(BossDPSBroadcastTestApi.metrics.native_hits - exact_overlap.hits_before == 8,
    "native exact overlap changed hit conservation")
death(exact_overlap.boss)
run_game_tasks()
run_delayed_tasks()
end

-- Native bridge simulation: one aggregated bucket represents many hits. Lua
-- must preserve the exact damage while carrying the hit count into tie-break
-- metadata, and it must classify the target for the C++ fast path.
local native_classifications = {}
BossDPSNativeClassifyTarget = function(target_key, state)
    native_classifications[#native_classifications + 1] = target_key .. ":" .. state
end

-- A negative native classification must expire with the Lua cache and must
-- also be released by F2. Previously only the Lua address entry expired while
-- the C++ collector kept suppressing that target indefinitely.
local native_nonboss_index = 0
BossDPSNativeDrainOne = function()
    native_nonboss_index = native_nonboss_index + 1
    if native_nonboss_index == 1 then
        return true, player_one, normal_target, 10, nil, nil, nil, 1, "0xSTALE"
    end
    return false
end
BossDPSBroadcastTestApi.hooks.damage_mode = "native"
phase = "game"
BossDPSBroadcastTestApi.drain_native_damage()
phase = "bootstrap"
assert(native_classifications[#native_classifications] == "0xSTALE:nonboss",
    "confirmed ordinary target was not classified for the native fast path")
fake_time = fake_time + runtime_config.NonBossCacheSeconds + 1
phase = "game"
BossDPSBroadcastTestApi.cleanup_sessions()
phase = "bootstrap"
assert(native_classifications[#native_classifications] == "0xSTALE:unknown",
    "expired Lua non-Boss cache did not release the native classification")
native_nonboss_index = 0
phase = "game"
BossDPSBroadcastTestApi.drain_native_damage()
phase = "bootstrap"
assert(native_classifications[#native_classifications] == "0xSTALE:nonboss",
    "ordinary target was not reclassified after expiry")
phase = "game"
BossDPSBroadcastTestApi.reset_skill_diagnostics()
phase = "bootstrap"
assert(native_classifications[#native_classifications] == "0xSTALE:unknown",
    "F2 reset retained a native non-Boss classification from the prior test")

local native_boss = boss_actor("BP_RaidBoss_Native_C_501")
local native_record_index = 0
BossDPSNativeDrainOne = function()
    native_record_index = native_record_index + 1
    if native_record_index == 1 then
        return true, player_one, native_boss, 777, nil, nil, nil, 123, "0xABC"
    end
    return false
end
BossDPSBroadcastTestApi.hooks.damage_mode = "native"
local native_hits_before = BossDPSBroadcastTestApi.metrics.native_hits
local native_boss_classification_before = #native_classifications
phase = "game"
BossDPSBroadcastTestApi.drain_native_damage()
phase = "bootstrap"
local native_session
for _, candidate in pairs(BossDPSBroadcastTestApi.sessions) do
    if candidate.name == "RaidBoss_Native" then
        native_session = candidate
        break
    end
end
assert(native_session ~= nil, "native aggregate did not start a boss session")
assert(native_session.total_damage == 777, "native aggregate changed total damage")
local native_contributor
for _, contributor in pairs(native_session.contributors) do
    native_contributor = contributor
end
assert(native_contributor ~= nil and native_contributor.hits == 123,
    "native aggregate did not preserve hit count")
assert(BossDPSBroadcastTestApi.metrics.native_hits - native_hits_before == 123,
    "native hit metric is incorrect")
assert(native_classifications[native_boss_classification_before + 1] == "0xABC:boss",
    "native target was not classified as a boss")
death(native_boss)
run_game_tasks()
run_delayed_tasks()
assert(native_classifications[#native_classifications] == "0xABC:unknown",
    "finished native target classification was not released")

-- A runtime failure must fail open by default, but fail closed when an
-- administrator explicitly requires the native collector.
BossDPSNativeDrainOne = function()
    return false, "faulted"
end
runtime_config.RequireNativeCollector = false
BossDPSBroadcastTestApi.hooks.damage = true
BossDPSBroadcastTestApi.hooks.damage_mode = "native"
phase = "game"
BossDPSBroadcastTestApi.drain_native_damage()
phase = "bootstrap"
assert(BossDPSBroadcastTestApi.hooks.damage_mode == "lua-fallback",
    "native runtime fault did not activate Lua fallback")
assert(BossDPSBroadcastTestApi.hooks.damage == true,
    "Lua fallback was not marked active after native runtime fault")

runtime_config.RequireNativeCollector = true
BossDPSBroadcastTestApi.hooks.damage = true
BossDPSBroadcastTestApi.hooks.damage_mode = "native"
phase = "game"
BossDPSBroadcastTestApi.drain_native_damage()
phase = "bootstrap"
assert(BossDPSBroadcastTestApi.hooks.damage_mode == "required-native-faulted",
    "required native runtime fault did not disable damage recording")
assert(BossDPSBroadcastTestApi.hooks.damage == false,
    "required native runtime fault left damage recording enabled")
runtime_config.RequireNativeCollector = false

assert(BossDPSBroadcastTestApi.metrics.errors == 0,
    "unexpected processing errors: " .. tostring(BossDPSBroadcastTestApi.metrics.errors))
assert(#delivered_by_uid[test_guid_key(uid_spectator)] == 0, "spectator received any participant-only report")

assert(#BossDPSBroadcastTestApi.sessions == 0, "sessions table must be map-like")
assert(original_os_time ~= nil)
print("PalSkillDPSAnalyzer v0.5.28 damage-lab/display/multitarget/source/thread/lifetime/stress tests passed")
