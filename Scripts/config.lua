local config = {}

-- Master switch for all boss damage recording and chat reports.
-- Changing this setting requires a server restart.
config.EnableDPSRecording = true

-- Chat report language. "auto" follows Palworld's current language when it
-- can be detected. You may also use any supported code such as en, zh-CN,
-- zh-TW, ja, fr, it, de, es-ES, pt-BR, ru, ko, id, es-419, th, tr, vi or pl.
config.Language = "auto"

-- Prefer the optional C++ collector when it is installed and ABI-compatible.
-- The native layer aggregates high-frequency hits before Lua sees them.
-- Keep RequireNativeCollector false so an incompatible/missing DLL falls back
-- to the proven Lua hook instead of silently disabling all damage recording.
-- Diagnostics require the unaggregated Lua event so candidate skill metadata
-- is not discarded by the native high-frequency collector.
config.PreferNativeCollector = false
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
-- Off by default. Enable for a separate player-character test run. When the
-- damage causer exposes a weapon/projectile, the analyzer creates one bucket
-- per candidate; otherwise it falls back to a generic player source bucket.
config.IncludePlayerDamage = false
config.DumpDamageSchema = true
config.SkillDiagnosticMaxSamplesPerCandidate = 3
config.SkillDiagnosticMaxSchemaFields = 128
config.SkillDiagnosticChatMaxRows = 12
-- A Pal Waza marker is emitted immediately before its damage info is built.
-- Keep it briefly so delayed projectiles and multi-hit skills remain attributed.
config.SkillMarkerTTLSeconds = 30
config.SkillMarkerMaxEntries = 2048

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
