local config = {}

-- Master switch for all boss damage recording and chat reports.
-- Changing this setting requires a server restart.
config.EnableDPSRecording = true

-- HUD, settings, skill-name, and chat-report language. "auto" follows
-- Palworld's current language when it can be detected. F1 can switch this at
-- runtime, or use en, zh-CN, zh-TW, ja, fr, it, de, es-ES, pt-BR, ru, ko,
-- id, es-419, th, tr, vi or pl here.
config.Language = "auto"

-- Prefer the optional C++ collector when it is installed and ABI-compatible.
-- API v2 emits every final hit in sequence and preserves exact source tokens;
-- older aggregate-only builds remain a compatibility fallback.
-- Keep RequireNativeCollector false so an incompatible/missing DLL falls back
-- to the proven Lua hook instead of silently disabling all damage recording.
-- Diagnostics require the unaggregated Lua event so candidate skill metadata
-- is not discarded by the native high-frequency collector.
config.PreferNativeCollector = true
-- Aggregate-only collector v1 discards per-hit source identities, so it is
-- disabled for the skill analyzer unless explicitly requested for total-only
-- compatibility testing.
config.AllowLegacyNativeAggregate = false
config.RequireNativeCollector = false
config.NativeDrainIntervalMilliseconds = 50
config.NativeMaxBucketsPerDrain = 512

-- Single-player/host distribution switch. When true, chat reports are sent
-- only to the local player. The dedicated-server package keeps this false.
config.LocalOnlyMessages = false

-- Prefix used for every participant-only system chat message.
config.MessagePrefix = "[PalSkillDPS]"

-- Standalone damage verification. Pal skills are the default lane; optional
-- player/weapon tests use the same source and candidate model. The diagnostic
-- release records evidence-backed candidates and never invents a name.
config.EnableSkillDiagnostics = true
config.SkillDiagnosticsOnly = true
-- Exact source-chain attribution. Each cast, spawned PalSkillEffect, bound
-- OnAttack callback and final OnDamage hit is linked by runtime object/call
-- identity. Disable only for compatibility diagnosis; without it, any final
-- hit lacking direct Waza/DamageCauser evidence stays unresolved.
config.EnableSkillSourceChain = true
-- When Palworld omits Waza/DamageCauser from final damage, combine the Pal's
-- live three EquipWaza slots with captured action begin/end events. Exact
-- source-chain evidence always wins. Bounded results are labelled inferred,
-- never teach the exact signature table, and ambiguous overlaps stay unresolved.
config.EnableBoundedSkillInference = true
-- A damage lab is more useful when the operator controls the sampling window.
-- "manual" keeps one test open across many targets until F1 -> Start new test;
-- "target" automatically creates a separate test for each damaged target.
config.MeasurementMode = "manual"
-- "boss" accepts arena/tower/raid/tablet Bosses and open-world Alpha/Boss
-- targets, while excluding ordinary wild Pals from the formal test totals.
-- Use "all" only for an explicit non-Boss diagnostic run.
config.TargetScope = "boss"
-- Off by default. Enable for a separate player-character test run. When the
-- damage causer exposes a weapon/projectile, the analyzer creates one bucket
-- per candidate; otherwise it falls back to a generic player source bucket.
config.IncludePlayerDamage = false
config.DumpDamageSchema = false
config.SkillDiagnosticMaxSamplesPerCandidate = 64
config.SkillDiagnosticMaxSchemaFields = 128
config.SkillDiagnosticChatMaxRows = 12
-- Diagnostic results use a dedicated in-game HUD by default. Chat output is
-- retained only as an optional compatibility mode: "off", "summary", or
-- "full". The F1 panel can change this without editing the file.
config.SkillDiagnosticChatMode = "off"

-- Dedicated skill-DPS HUD. F1 opens the settings panel; arrow keys and Enter
-- change values. User choices are persisted beside these scripts.
config.EnableSkillDPSHUD = true
config.HUDRefreshMilliseconds = 500
config.HUDSettingsVersion = 3
-- Compact is the public default: one proportional bar per skill with damage,
-- share, casts and encounter DPS. "full" reveals timing diagnostics below
-- every row when the user deliberately switches modes in F1.
config.HUDDetailMode = "compact"
-- Keep the panel compact: show the official localized skill name by default.
-- F1 can reveal the internal English Waza/action code when diagnosing a skill.
config.HUDShowInternalSkillCode = false
config.HUDAnchor = "left-center"
config.HUDScale = 0.85
config.HUDMaxSkillRows = 5
config.HUDKeepFinalResults = true
-- Final automatic-target results remain briefly, rather than covering loading
-- screens indefinitely. -1 keeps them until the next test; 0 hides at once.
config.HUDFinalResultSeconds = 15
-- Current Palworld/UE4SS builds crash when a Lua-only mod constructs UMG or
-- calls PrintString from the live damage path. The shipped HUD is therefore a
-- separate transparent Windows overlay fed by a local state file. It never
-- calls Unreal UI APIs and remains hidden while Palworld is not foreground.
config.EnableExternalHUD = true
config.ExternalHUDAutoLaunch = true
-- The external window is display-only. Interactive settings require a native
-- Palworld CommonUI surface; cross-process mouse/focus control is disabled.
config.EnableExternalHUDSettings = false
-- Retained as explicit compatibility guards for older user settings. Neither
-- unsafe backend is called by current releases, even if an old settings file says true.
config.HUDUseExperimentalUMG = false
config.HUDUseScreenTextFallback = false
-- The chat shows aggregate timing for every displayed skill. UE4SS.log can
-- additionally keep one row per observed cast for later comparison.
config.SkillDiagnosticLogCasts = true
config.SkillDiagnosticMaxCastLogRows = 128
config.SkillActionMaxEntries = 4096
-- Bounded inference may use these windows only after exact evidence fails.
-- Ambiguous overlapping recent casts remain unresolved.
config.SkillActionPostHitSeconds = 10
config.SkillActionConflictSeconds = 1.25
config.SkillEffectHitGapSeconds = 3
config.SkillEffectMaxLifetimeSeconds = 45
-- A Pal Waza marker is emitted on some damage paths. Only an exact matching
-- DamageInfo identity may use it for confirmed attribution.
config.SkillMarkerTTLSeconds = 30
config.SkillMarkerMaxEntries = 2048
-- The three equipped Waza slots can change while a manual test is open. Every
-- action begin invalidates the cached list, and this TTL additionally forces
-- a re-read so a newly equipped skill loses the "basic" prefix on the next
-- hit without restarting the game.
config.EquipWazaRefreshSeconds = 5
-- Waza construction markers are kept as a per-attacker/per-target queue. A
-- short conflict window prevents two overlapping skills from silently
-- overwriting each other; ambiguous hits stay unresolved for diagnostics.
config.SkillMarkerConflictSeconds = 0.35
config.SkillMarkerMaxPerPair = 24
-- Keep enough bounded trace evidence to reconstruct one full manual test.
config.SkillDiagnosticMaxTraceEvents = 256

-- Runtime metadata always takes priority: the analyzer asks Palworld for its
-- current localized Waza name and database cooldown. These entries only cover
-- known test skills when a particular game build does not expose that lookup.
config.SkillMetadataFallbacks = {
    BeamSlicer = {
        Name = { en = "Beam Slicer", ["zh-CN"] = "切割龙息", ["zh-TW"] = "切割龍息" },
        PanelCoolTime = 16,
    },
    ChargeCanon = {
        Name = { en = "Charge Cannon", ["zh-CN"] = "龙息炮", ["zh-TW"] = "龍息炮" },
        PanelCoolTime = 20,
    },
    BlastCanon = {
        Name = { en = "Blast Cannon", ["zh-CN"] = "绽裂龙息", ["zh-TW"] = "綻裂龍息" },
        PanelCoolTime = 12,
    },
    GravityShot = {
        Name = { en = "Dark Shot", ["zh-CN"] = "暗能弹", ["zh-TW"] = "暗能彈" },
        PanelCoolTime = 2,
        BasePower = 40,
        AttackElementType = 8,
    },
    -- Palworld 1.0 final-damage events from the 2026-08-13 World Tree
    -- Dragon test omit Waza and DamageCauser for many Dark multi-hits. These
    -- signatures are safe only while the matching Waza is in this Pal's
    -- current EquipWaza slots; PoisonShot status poison remains separate.
    DarkLaser = {
        Name = { en = "Dark Laser", ["zh-CN"] = "暗黑雷射", ["zh-TW"] = "暗黑雷射" },
        PanelCoolTime = 30,
        BasePower = 450,
        AttackElementType = 8,
    },
    DarkLegion = {
        Name = { en = "Dark Whisp", ["zh-CN"] = "黑暗之拥", ["zh-TW"] = "黑暗之擁" },
        PanelCoolTime = 30,
        BasePower = 600,
        AttackElementType = 8,
    },
    PoisonShot = {
        Name = { en = "Poison Blast", ["zh-CN"] = "剧毒射击", ["zh-TW"] = "劇毒射擊" },
        PanelCoolTime = 2,
        BasePower = 30,
        AttackElementType = 8,
    },
    -- Palworld 1.0 active-skill data and the 2026-08-13 final-damage log
    -- agree on these fire signatures. They are used only while the matching
    -- Waza is actually present in this Pal's EquipWaza slots, so another
    -- skill with the same power cannot leak across loadouts.
    FireBall = {
        Name = { en = "Fire Ball", ["zh-CN"] = "烈焰球", ["zh-TW"] = "烈焰球" },
        PanelCoolTime = 30,
        BasePower = 600,
        AttackElementType = 2,
    },
    FlameFunnel = {
        Name = { en = "Flame Funnel", ["zh-CN"] = "流火", ["zh-TW"] = "流火" },
        PanelCoolTime = 16,
        BasePower = 300,
        AttackElementType = 2,
    },
    FlareTornado = {
        Name = { en = "Flare Storm", ["zh-CN"] = "烈焰风暴", ["zh-TW"] = "烈焰風暴" },
        PanelCoolTime = 12,
        BasePower = 200,
        AttackElementType = 2,
    },
    -- These signatures were verified from Palworld 1.0 cooked assets and the
    -- 2026-08-12 live final-damage log. They are matched only when the same
    -- Waza is present in this Pal's current three EquipWaza slots.
    DiamondFall = {
        Name = { en = "Diamond Rain", ["zh-CN"] = "晶钻之雨", ["zh-TW"] = "晶鑽之雨" },
        PanelCoolTime = 30,
        BasePower = 600,
        AttackElementType = 6,
    },
    DoubleIcicleThrow = {
        Name = { en = "Double Blizzard", ["zh-CN"] = "极寒双星", ["zh-TW"] = "極寒雙星" },
        PanelCoolTime = 30,
        BasePower = 700,
        AttackElementType = 6,
    },
    IcicleThrow = {
        Name = { en = "Diamond Star", ["zh-CN"] = "钻石星辰", ["zh-TW"] = "鑽石星辰" },
        PanelCoolTime = 20,
        BasePower = 450,
        AttackElementType = 6,
    },
}

-- Optional components. Compact, low-noise output is the public default.
-- Change a switch, then restart the server once to apply it.
config.BroadcastStart = true
config.EnableProgressReports = false
config.EnableDetailedAwards = false
-- Show a final breakdown for the player character and every individual Pal.
-- This is the easiest switch for users who want per-Pal damage, share and DPS.
-- Dedicated servers keep it off by default to avoid extra chat lines.
config.EnablePalDamageBreakdown = false
-- Legacy alias kept for existing config files. Either switch enables the same
-- breakdown; new installations should use EnablePalDamageBreakdown.
config.EnableTeamDetails = false
config.MarkTopAsMVP = true

-- Maximum number of contributors shown in the final ranking.
config.MaxResultRows = 10

-- When EnableProgressReports is true, publish a live report every N seconds.
-- Current DPS is damage dealt inside the latest report window divided by
-- the actual window duration. Set to 0 to disable live reports.
config.ProgressIntervalSeconds = 10
config.ProgressMaxRows = 4

-- Maximum player-character/Pal source rows in the damage breakdown.
config.TeamDetailMaxRows = 12

-- Fun battle comments: progress comments only appear when a threshold is met;
-- every final result receives one comment when enabled. Changing this setting
-- requires a server restart.
config.EnableFunComments = false

-- Delay between result lines to avoid flooding the chat feed.
config.MessageIntervalMilliseconds = 1000

-- End and publish a partial session after this many seconds without damage.
-- Set to 0 to disable inactivity cleanup.
config.InactivityTimeoutSeconds = 60
config.CleanupIntervalSeconds = 10

-- Include per-player DPS in addition to damage and percentage.
config.ShowDPS = true

-- Safety/back-pressure controls. Events above MaxPendingEvents are dropped;
-- each game-thread drain processes at most MaxEventsPerDrain events.
config.MaxPendingEvents = 8192
config.MaxEventsPerDrain = 256
config.MaxSourceOwnerCacheEntries = 2048

-- Cache targets already confirmed to be ordinary non-boss actors. This keeps
-- global damage events from repeatedly running player/Pal ownership queries.
config.NonBossCacheSeconds = 60

-- Known multi-actor bosses. All listed parts share one encounter total. A
-- terminal part ends the whole encounter; non-terminal part deaths do not.
-- Parts with a common Owner/attach parent are matched first. The short join
-- window is only a fallback for builds where that relationship is unavailable.
config.CompositePartJoinWindowSeconds = 15
config.CompositeBossParts = {
    YakushimaBoss002_B = { group = "YakushimaBoss002", terminal = true },
    YakushimaBoss002_Head = { group = "YakushimaBoss002" },
    YakushimaBoss002_L = { group = "YakushimaBoss002" },
    YakushimaBoss002_R = { group = "YakushimaBoss002" },
}

-- Log every accepted damage event. Keep false on a live server.
config.TraceDamage = false

-- If reflected boss flags are unavailable, use these actor-name fragments.
config.UseBossNameFallback = true
config.BossNamePatterns = {
    "boss",
    "raid",
    "gym_",
}

-- Localized fallback names keyed by a normalized character/actor id. The mod
-- first asks Palworld's localization database, then checks this table, and
-- never displays a long /Game/... object path.
config.BossNameOverrides = {
    Suzaku = { en = "Suzaku", ["zh-CN"] = "朱雀", ["zh-TW"] = "朱雀" },
    Suzaku_BOSS = { en = "Suzaku", ["zh-CN"] = "朱雀", ["zh-TW"] = "朱雀" },
    DarkScorpion = { en = "Dark Scorpion", ["zh-CN"] = "冥铠蝎", ["zh-TW"] = "冥鎧蠍" },
    DarkScorpion_BOSS = { en = "Dark Scorpion", ["zh-CN"] = "冥铠蝎", ["zh-TW"] = "冥鎧蠍" },
}

-- Optional localized species-name fallbacks for owned Pals. Player-assigned
-- nicknames still take priority over these names.
config.PalNameOverrides = {
    PinkCat = { en = "Cattiva", ["zh-CN"] = "捣蛋猫", ["zh-TW"] = "搗蛋貓" },
}

return config
