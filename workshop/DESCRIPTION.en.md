[h1]Pal Skill DPS Analyzer[/h1]
[b]A single-player damage verification tool for Palworld 1.0.[/b]

This is not a player ranking meter. Reset and start a test at any time; timing begins with the first accepted hit. Field/dungeon Boss and tablet Boss tests are selected explicitly. Tablet reports group Pals by species plus their complete three-skill loadout.

[h2]Dedicated HUD and safe reset[/h2]
[list]
[*]Pal damage enabled by default; player/weapon damage disabled by default
[*]Native per-hit attribution links cast, effect, AttackFilter Waza, Blueprint OnAttack, and final damage
[*]A 2–4 hit batch from one Pal to one Boss that precedes a single observed OnAttack Waza may enter that skill as inferred evidence; larger batches, conflicts, and timeouts remain unresolved
[*]Long-travel Double Icicle Throw/Icicle Throw tail impacts may reuse a recent linked hit on the same target; when every source bridge is absent, only the nearest uniquely non-conflicting completed equipped action for those two skills is accepted and marked inferred
[*]Once Twin Spears has established a cast binding, its last hit may follow within one second only when it is the immediately consecutive native damage sequence; any intervening damage event prevents the carry-over
[*]Flash Charge accepts only the first source-less hit 1.5–3.3 seconds into the exact active Action for the same Pal and target; a second hit or any post-action tail remains unresolved
[*]Inferred evidence never masquerades as exact evidence, and general current/recent actions or power/element signatures never choose the skill
[*]F3 has three top-level pages: Settings, Grouped %, and Current Test Details; the third page shows each Pal's damaging/no-damage casts, total hit segments, hit segments per cast, and per-cast minimum/average/maximum including no-damage casts
[*]Compact left-side meter updates live with total damage as the primary figure and DPS as secondary efficiency context, replacing chat output by default
[*]F2 resets and starts a new test without opening an external window or changing game cursor/input state
[*]F3 explicitly selects Field/Dungeon Boss or Tablet Boss; profiles are not auto-mixed
[*]Hard towers count only the main actor with a GYM character identity; adds stay excluded even when they also expose Boss/TowerBoss database flags
[*]The tablet HUD merges only same-species Pals with an identical complete three-skill loadout; matching loadouts show ×N and different loadouts become A/B groups
[*]The live HUD shows only the three highest-damage loadout groups and three skill-percentage bars per group; remaining groups are available in the complete F3 Grouped % report
[*]If a complete loadout cannot be read, that Pal remains separate instead of being merged from uncertain data
[/list]

[h2]Installation[/h2]
[olist]
[*]Subscribe to this mod.
[*]Subscribe to and enable [url=https://steamcommunity.com/workshop/filedetails/?id=3625223587]UE4SS Experimental (Palworld)[/url].
[*]Enable both mods in Palworld's Mod Manager.
[*]Enter a world, choose the test type in F3, close Settings, press F2 to reset, and then attack the matching Boss.
[/olist]

[h2]Optional weapon test[/h2]
Enable player damage in config.lua, restart the game, and use one weapon for the entire fight. If a reliable weapon or projectile source is exposed it receives its own candidate; otherwise the result remains an unknown player-weapon candidate.

[h2]Scope[/h2]
[list]
[*][b]Target:[/b] Windows single-player worlds
[*][b]Current status:[/b] v0.5.29 HUD shutdown and idle-update fix; damage attribution unchanged
[*][b]Required dependency:[/b] UE4SS Experimental; PalSchema is not required
[*][b]Not a goal:[/b] comparing players or producing a competitive DPS leaderboard
[/list]

Source and issue tracker: [url=https://github.com/paul800901/PalSkillDPSAnalyzer]GitHub[/url]

[i]An independently maintained MIT-licensed derivative. Boss encounter detection, Pal ownership resolution, and safe messaging derive from AsahiChan-Game/PalBossDPSBroadcast. Per-hit skill attribution, the DPS HUD, native F3 CommonUI, and cast/hit statistics were developed by this project. Unofficial and not affiliated with Pocketpair, Steam, or UE4SS.[/i]
