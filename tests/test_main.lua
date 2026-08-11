package.path = "../Scripts/?.lua;" .. package.path

local phase = "bootstrap"
local callbacks = {}
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
    })
end

local zero_guid = { A = 0, B = 0, C = 0, D = 0 }
local uid_one = { A = 1, B = 2, C = 3, D = 4 }
local uid_two = { A = 5, B = 6, C = 7, D = 8 }
local uid_spectator = { A = 9, B = 10, C = 11, D = 12 }

local function test_guid_key(uid)
    return table.concat({ uid.A, uid.B, uid.C, uid.D }, ":")
end

delivered_by_uid[test_guid_key(uid_one)] = delivered
delivered_by_uid[test_guid_key(uid_two)] = {}
delivered_by_uid[test_guid_key(uid_spectator)] = {}

local guild_one = object({ GuildName = "红队" }, { GetAddress = function() return 9001 end })
local guild_two = object({ GuildName = "蓝队" }, { GetAddress = function() return 9002 end })
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
local local_player_controller = object({ PlayerState = player_one_state })

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
local player_two_pal_parameter = object({}, {
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
    [501] = { localized = "暗黑球", cooldown = 4 },
    [502] = { localized = "毒雾", cooldown = 30 },
    [601] = { localized = "切割龙息", cooldown = 16 },
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

local internationalization_library = object({}, {
    GetCurrentLanguage = function()
        return "zh-Hans-CN"
    end,
    GetLocalizedLanguage = function()
        return "zh"
    end,
})

local waza_names = {
    [501] = "EPalWazaID::DarkBall",
    [502] = "EPalWazaID::PoisonFog",
    [601] = "EPalWazaID::BeamSlicer",
}
local waza_enum = object({}, {
    GetNameByValue = function(_, value)
        return waza_names[value] or ("EPalWazaID::TestWaza" .. tostring(value))
    end,
})

function StaticFindObject(path)
    require_game_thread("StaticFindObject")
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

function FindFirstOf(type_name)
    require_game_thread("FindFirstOf")
    assert(type_name == "PalGameStateInGame")
    return world
end

function RegisterHook(path, callback)
    assert(phase == "bootstrap" or phase == "game",
        "RegisterHook must run during bootstrap or on the game thread")
    local allowed = {
        ["/Script/Pal.PalEventNotify_Character:OnCharacterDamaged_ServerInternal"] = true,
        ["/Script/Pal.PalUtility:MakeDamageInfoByWazaType"] = true,
        ["/Script/Pal.PalActionBase:OnBeginAction"] = true,
        ["/Script/Pal.PalActionBase:OnEndAction"] = true,
        ["/Script/Pal.PalEventNotify_Character:OnCharacterDead_ServerInternal"] = true,
        ["/Script/Pal.PalUtility:PalCaptureSuccess"] = true,
    }
    if not allowed[path] then
        error("simulated Palworld 1.0: UFunction not found")
    end
    callbacks[path] = callback
end

EGameThreadMethod = { EngineTick = 1, ProcessEvent = 2 }
EngineTickAvailable = true
Key = {
    F1 = "F1",
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
    callbacks["/Script/Pal.PalEventNotify_Character:OnCharacterDamaged_ServerInternal"](nil, hook_param(payload))
    phase = "idle"
end

local function waza(attacker, defender, waza_id)
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

local runtime_config = BossDPSBroadcastTestApi.config
assert(runtime_config.EnableDPSRecording == true, "DPS recording should default to enabled")
assert(runtime_config.EnableFunComments == false, "fun comments should default to disabled")
assert(runtime_config.BroadcastStart == true, "start reports should default to enabled")
assert(runtime_config.EnableProgressReports == false, "progress reports should default to disabled")
assert(runtime_config.EnableDetailedAwards == false, "detailed awards should default to disabled")
assert(runtime_config.EnablePalDamageBreakdown == false, "Pal breakdown should default to disabled on servers")
assert(runtime_config.EnableTeamDetails == false, "team details should default to disabled")
assert(runtime_config.LocalOnlyMessages == false, "server package should not default to local-only messages")
assert(runtime_config.EnableSkillDiagnostics == true, "skill diagnostics should default to enabled")
assert(runtime_config.SkillDiagnosticsOnly == true, "diagnostic-only output should default to enabled")
assert(runtime_config.IncludePlayerDamage == false, "player damage should default to disabled")
assert(runtime_config.SkillDiagnosticChatMode == "off", "diagnostic chat should default to disabled")
assert(runtime_config.EnableSkillDPSHUD == true, "skill DPS HUD should default to enabled")
assert(runtime_config.HUDDetailMode == "full", "HUD should default to full timing details")
assert(runtime_config.HUDShowInternalSkillCode == false,
    "internal skill code should default to hidden")
assert(runtime_config.DumpDamageSchema == false, "schema dump should default to disabled after field discovery")
assert(runtime_config.SkillDiagnosticLogCasts == true,
    "per-cast diagnostic log should default to enabled")
assert(runtime_config.SkillActionMaxEntries >= 128,
    "action lifecycle cache must be bounded")
assert(type(key_callbacks[Key.F1]) == "function", "F1 HUD settings key was not registered")
assert(type(key_callbacks[Key.UP_ARROW]) == "function"
    and type(key_callbacks[Key.DOWN_ARROW]) == "function"
    and type(key_callbacks[Key.RETURN]) == "function",
    "HUD settings navigation keys were not registered")

do
    runtime_config.Language = "zh-TW"
    assert(runtime_config.HUDUseExperimentalUMG == false,
        "unsafe dynamic UMG backend must be disabled by default")
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
    assert(BossDPSBroadcastTestApi.skill_hud.backend == "screen-text",
        "safe screen-text backend was not selected")
    assert(string.find(hud_header, "帕魯技能 DPS", 1, true) ~= nil, "HUD title missing")
    assert(string.find(hud_summary, "總傷害 2,000", 1, true) ~= nil, "HUD encounter summary missing")
    assert(string.find(hud_body, "切割龍息", 1, true) ~= nil,
        "HUD localized skill name missing")
    assert(string.find(hud_body, "BeamSlicer", 1, true) == nil,
        "HUD should hide the internal skill code by default")
    assert(string.find(hud_body, "施放DPS 400.0", 1, true) ~= nil,
        "HUD action DPS missing")
    assert(string.find(hud_body, "實際間隔 20.5秒", 1, true) ~= nil,
        "HUD observed interval missing")
    assert(string.find(hud_footer, "人物傷害 關", 1, true) ~= nil,
        "HUD player-damage state missing")
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
    runtime_config.Language = "auto"
end
-- Most existing scenarios also exercise the enabled commentary branches.
-- They verify the inherited BossDPS core, so opt back into legacy output for
-- those scenarios. Dedicated diagnostics cases below test the new defaults.
runtime_config.SkillDiagnosticsOnly = false
runtime_config.IncludePlayerDamage = true
runtime_config.EnableFunComments = true
runtime_config.BroadcastStart = true
runtime_config.EnableProgressReports = true
runtime_config.EnableDetailedAwards = true
runtime_config.EnableTeamDetails = true

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

local damage_hook = callbacks["/Script/Pal.PalEventNotify_Character:OnCharacterDamaged_ServerInternal"]
local waza_hook = callbacks["/Script/Pal.PalUtility:MakeDamageInfoByWazaType"]
local death_hook = callbacks["/Script/Pal.PalEventNotify_Character:OnCharacterDead_ServerInternal"]
local captured_hook = callbacks["/Script/Pal.PalUtility:PalCaptureSuccess"]
assert(damage_hook ~= nil, "damage hook was not registered")
assert(waza_hook ~= nil, "Waza attribution hook was not registered")
assert(callbacks["/Script/Pal.PalActionBase:OnBeginAction"] ~= nil
    and callbacks["/Script/Pal.PalActionBase:OnEndAction"] ~= nil,
    "action lifecycle hooks were not registered")
assert(death_hook ~= nil, "death hook was not registered")
assert(captured_hook ~= nil, "capture hook was not registered")
assert(#loop_tasks == 3, "cleanup, progress, and HUD loops were not configured")
local loop_delays = {
    [loop_tasks[1].delay] = true,
    [loop_tasks[2].delay] = true,
    [loop_tasks[3].delay] = true,
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
assert(string.find(joined, "开始统计", 1, true) ~= nil, "start announcement missing")
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
local dark_ball_candidate
for _, candidate in pairs(diagnostic_source.skill_candidates) do
    diagnostic_candidate_count = diagnostic_candidate_count + 1
    if candidate.name == "DarkBall" then
        dark_ball_candidate = candidate
    end
end
assert(diagnostic_candidate_count == 3, "Pal skill candidates were not separated")
assert(dark_ball_candidate ~= nil and dark_ball_candidate.damage == 600 and dark_ball_candidate.hits == 2,
    "repeated Pal skill hits were not aggregated")
local bob_before_diagnostic_finish = #bob_inbox
death(diagnostic_boss)
run_game_tasks()
run_delayed_tasks()
local diagnostic_messages = {}
for index = bob_before_diagnostic_finish + 1, #bob_inbox do
    diagnostic_messages[#diagnostic_messages + 1] = bob_inbox[index]
end
local diagnostic_joined = table.concat(diagnostic_messages, "\n")
assert(string.find(diagnostic_joined, "伤害验证完成", 1, true) ~= nil,
    "diagnostic completion message missing")
assert(string.find(diagnostic_joined, "暗黑球（DarkBall）｜伤害 600｜占比 60.0%｜整场DPS 19", 1, true) ~= nil,
    "per-skill chat result missing")
assert(string.find(diagnostic_joined, "MVP", 1, true) == nil,
    "diagnostic-only mode emitted a player ranking")

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
current_action = actor("BP_ActionFlareTornado_C_2147000003")
damage(action_pal, action_boss, 100, { BasePower = 200, AttackElementType = 2 })
run_game_tasks()
current_action = actor("BP_ActionDamage_C_2147000004")
damage(action_pal, action_boss, 50, { BasePower = 200, AttackElementType = 2 })
run_game_tasks()
current_action = nil
damage(action_pal, action_boss, 25, { BasePower = 200, AttackElementType = 9 })
run_game_tasks()

local action_session
for _, candidate in pairs(BossDPSBroadcastTestApi.sessions) do
    if candidate.name == "RaidBoss_ActionDiagnostic" then
        action_session = candidate
        break
    end
end
assert(action_session ~= nil and action_session.total_damage == 675,
    "action diagnostic session total is incorrect")
local action_source
for _, source in pairs(action_session.diagnostic_sources) do
    action_source = source
end
local action_candidate_count = 0
local beam_candidate
for _, candidate in pairs(action_source.skill_candidates) do
    action_candidate_count = action_candidate_count + 1
    if candidate.name == "BeamSlicer" then
        beam_candidate = candidate
    end
end
assert(action_candidate_count == 4,
    "action diagnostic did not preserve pre-report unresolved signatures")
assert(beam_candidate ~= nil and beam_candidate.damage == 500 and beam_candidate.hits == 2,
    "per-cast action instance numbers split one Pal skill")

death(action_boss)
run_game_tasks()
run_delayed_tasks()
local action_messages = {}
for index = action_before + 1, #bob_inbox do
    action_messages[#action_messages + 1] = bob_inbox[index]
end
local action_joined = table.concat(action_messages, "\n")
assert(string.find(action_joined, "切割龙息（BeamSlicer）｜伤害 500", 1, true) ~= nil,
    "stable action skill total missing")
assert(string.find(action_joined,
    "观测施放 2次（命中2）｜每次伤害 250.0｜面板CD 16.0秒｜实际开始间隔 20.0秒｜较面板 +4.0秒",
    1, true) ~= nil, "actual cast interval and panel cooldown comparison missing")
assert(string.find(action_joined,
    "完整动作 2.0秒｜单次施放DPS 125.0｜再用空窗 18.0秒｜首末命中窗 0.0秒｜完整计时 2/2",
    1, true) ~= nil, "full action timing report missing")
assert(string.find(action_joined, "FlareTornado｜伤害 150", 1, true) ~= nil,
    "uniquely identified generic damage was not reconciled")
assert(string.find(action_joined, "UNRESOLVED_PAL_ATTACK_BP_200_ELEMENT_9｜伤害 25", 1, true) ~= nil,
    "ambiguous generic damage was assigned without proof")
assert(string.find(action_joined, "技能/武器候选 3个", 1, true) ~= nil,
    "post-reconciliation candidate count is incorrect")

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
assert(count_plain(composite_joined, "开始统计：月亮领主 已进入战斗") == 1,
    "composite encounter announced more than once")
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

-- Native bridge simulation: one aggregated bucket represents many hits. Lua
-- must preserve the exact damage while carrying the hit count into tie-break
-- metadata, and it must classify the target for the C++ fast path.
local native_boss = boss_actor("BP_RaidBoss_Native_C_501")
local native_record_index = 0
local native_classifications = {}
BossDPSNativeDrainOne = function()
    native_record_index = native_record_index + 1
    if native_record_index == 1 then
        return true, player_one, native_boss, 777, nil, nil, nil, 123, "0xABC"
    end
    return false
end
BossDPSNativeClassifyTarget = function(target_key, state)
    native_classifications[#native_classifications + 1] = target_key .. ":" .. state
end
BossDPSBroadcastTestApi.hooks.damage_mode = "native"
local native_hits_before = BossDPSBroadcastTestApi.metrics.native_hits
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
assert(native_classifications[1] == "0xABC:boss",
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

assert(BossDPSBroadcastTestApi.metrics.errors == 0, "unexpected processing errors")
assert(#delivered_by_uid[test_guid_key(uid_spectator)] == 0, "spectator received any participant-only report")

assert(#BossDPSBroadcastTestApi.sessions == 0, "sessions table must be map-like")
assert(original_os_time ~= nil)
print("PalSkillDPSAnalyzer v0.4.1 safe-overlay/multilingual/diagnostic/source/thread/lifetime/stress tests passed")
