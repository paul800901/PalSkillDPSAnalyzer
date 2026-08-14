[h1]Pal Skill DPS Analyzer[/h1]
[b]A single-player damage verification tool for Palworld 1.0.[/b]

This is not a player ranking meter. Reset and start a test at any time; timing begins with the first accepted hit. Mounted, party/following, and base Pals are grouped by their actual individual actor, then by skill.

[h2]Dedicated HUD and safe reset[/h2]
[list]
[*]Pal damage enabled by default; player/weapon damage disabled by default
[*]Optional one-weapon-per-fight player verification mode
[*]Native per-hit attribution links cast, effect, AttackFilter Waza, Blueprint OnAttack, and final damage
[*]Hits without an exact source remain unresolved; current/recent actions and power/element signatures never choose a named skill
[*]Official in-game localized skill names shown by default; internal codes remain in the log
[*]Panel cooldown compared with observed cast-start intervals affected by combat AI, movement, and skill selection
[*]Damage per cast, full action duration, cast DPS, reuse gap, and timing coverage shown at completion
[*]Compact left-side meter updates live with total damage as the primary figure and DPS as secondary efficiency context, replacing chat output by default
[*]Crash-isolated display: Lua writes a local UTF-8 state file and a bundled transparent Windows overlay renders it without Unreal UMG or PrintString
[*]F2 resets and starts a new test without opening an external window or changing game cursor/input state
[*]The external HUD is now a fixed-size click-through display, avoiding focus contention and anchor oscillation
[*]Official localized names are shown alone by default; advanced options remain available in config.lua
[*]Bounded per-hit and per-cast evidence in UE4SS.log
[*]All wild Pals, open-world/slab Bosses, multi-target fights, and base-Pal battles by default; Boss-only scope remains available
[/list]

[h2]Installation[/h2]
[olist]
[*]Subscribe to this mod.
[*]Subscribe to and enable [url=https://steamcommunity.com/workshop/filedetails/?id=3625223587]UE4SS Experimental (Palworld)[/url].
[*]Enable both mods in Palworld's Mod Manager.
[*]Enter a world, press F2 to reset, then use one or more Pals against any wild Pal or Boss and keep UE4SS.log.
[/olist]

[h2]Optional weapon test[/h2]
Enable player damage in config.lua, restart the game, and use one weapon for the entire fight. If a reliable weapon or projectile source is exposed it receives its own candidate; otherwise the result remains an unknown player-weapon candidate.

[h2]Scope[/h2]
[list]
[*][b]Target:[/b] Windows single-player worlds
[*][b]Current status:[/b] v0.5.14 native exact-attribution diagnostic; missing exact sources remain unresolved, old external F1 settings disabled, safe F2 reset; native DLL packaging and live validation are still in progress
[*][b]Required dependency:[/b] UE4SS Experimental; PalSchema is not required
[*][b]Not a goal:[/b] comparing players or producing a competitive DPS leaderboard
[/list]

Source and issue tracker: [url=https://github.com/paul800901/PalSkillDPSAnalyzer]GitHub[/url]

[i]Independent MIT-licensed mod derived from AsahiChan-Game/PalBossDPSBroadcast. Unofficial and not affiliated with Pocketpair, Steam, or UE4SS.[/i]
