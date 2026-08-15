[h1]Pal Skill DPS Analyzer[/h1]
[b]A single-player damage verification tool for Palworld 1.0.[/b]

This is not a player ranking meter. Reset and start a test at any time; timing begins with the first accepted hit. Mounted, party/following, and base Pals are grouped by their actual individual actor, then by skill and cumulative damage.

[h2]Dedicated HUD and safe reset[/h2]
[list]
[*]Pal damage enabled by default; player/weapon damage disabled by default
[*]Optional one-weapon-per-fight player verification mode
[*]Native per-hit attribution links cast, effect, AttackFilter Waza, Blueprint OnAttack, and final damage
[*]Hits without an exact source remain unresolved; current/recent actions and power/element signatures never choose a named skill
[*]Official in-game localized skill names shown by default; internal codes remain in the log
[*]Panel cooldown compared with observed cast-start intervals affected by combat AI, movement, and skill selection
[*]F3 details show damaging/no-damage casts, total hit segments, hit segments per cast, and per-cast minimum/average/maximum including no-damage casts
[*]Compact left-side meter updates live with total damage as the primary figure and DPS as secondary efficiency context, replacing chat output by default
[*]Crash-isolated display: Lua writes a local UTF-8 state file and a bundled transparent Windows overlay renders it without Unreal UMG or PrintString
[*]F2 resets and starts a new test without opening an external window or changing game cursor/input state
[*]The external HUD is now a fixed-size click-through display, avoiding focus contention and anchor oscillation
[*]Official localized names are shown alone by default; advanced options remain available in config.lua
[*]Bounded per-hit and per-cast evidence in UE4SS.log
[*]Boss-only by default: the final Boss death or capture freezes the complete result until the next F2 reset, while known phase transitions do not
[*]In all-wild-Pal scope, target deaths do not freeze the test; it continues until the next F2 reset
[/list]

[h2]Installation[/h2]
[olist]
[*]Subscribe to this mod.
[*]Subscribe to and enable [url=https://steamcommunity.com/workshop/filedetails/?id=3625223587]UE4SS Experimental (Palworld)[/url].
[*]Enable both mods in Palworld's Mod Manager.
[*]Enter a world, press F2 to reset, then attack a Boss. To test ordinary wild Pals, first change the target scope in F3.
[/olist]

[h2]Optional weapon test[/h2]
Enable player damage in config.lua, restart the game, and use one weapon for the entire fight. If a reliable weapon or projectile source is exposed it receives its own candidate; otherwise the result remains an unknown player-weapon candidate.

[h2]Scope[/h2]
[list]
[*][b]Target:[/b] Windows single-player worlds
[*][b]Current status:[/b] v0.5.19 five-core-field HUD build. The live meter shows only skill name, total damage, DPS, share, and test duration. F2 safely resets; F3 opens or closes an in-game native settings panel. Use the mouse to switch between Settings and Current Test. Cast/Hit diagnostics are confined to the second page. Attribution still accepts only reliable engine-provided source evidence; missing evidence stays unresolved instead of being guessed from damage, power rates, or current actions.
[*][b]Required dependency:[/b] UE4SS Experimental; PalSchema is not required
[*][b]Not a goal:[/b] comparing players or producing a competitive DPS leaderboard
[/list]

Source and issue tracker: [url=https://github.com/paul800901/PalSkillDPSAnalyzer]GitHub[/url]

[i]An independently maintained MIT-licensed derivative. Boss encounter detection, Pal ownership resolution, and safe messaging derive from AsahiChan-Game/PalBossDPSBroadcast. Per-hit skill attribution, the DPS HUD, native F3 CommonUI, cast/hit statistics, and Boss result snapshots were developed by this project. Unofficial and not affiliated with Pocketpair, Steam, or UE4SS.[/i]
