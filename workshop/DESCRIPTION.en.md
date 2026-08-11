[h1]Pal Skill DPS Analyzer[/h1]
[b]A single-player damage verification tool for Palworld 1.0.[/b]

This is not a player ranking meter. Each Pal is treated as an independent test source. Damage is grouped by evidence available in Palworld's damage event, such as a skill ID, projectile, or damage causer. The log reports total damage, encounter DPS, share, hit count, and average damage per hit.

[h2]Diagnostic release[/h2]
[list]
[*]Pal damage enabled by default; player/weapon damage disabled by default
[*]Optional one-weapon-per-fight player verification mode
[*]Evidence-backed candidates; unknown damage is never assigned a guessed skill name
[*]Per-skill damage, share, encounter DPS, hits, and average hit shown in game chat at completion
[*]One-time reflected damage-event schema and bounded per-candidate samples in UE4SS.log
[*]Boss defeat, capture, and inactivity completion paths
[/list]

[h2]Installation[/h2]
[olist]
[*]Subscribe to this mod.
[*]Subscribe to and enable [url=https://steamcommunity.com/workshop/filedetails/?id=3625223587]UE4SS Experimental (Palworld)[/url].
[*]Enable both mods in Palworld's Mod Manager.
[*]Use one Pal with known skills against a Boss, then keep UE4SS.log after the fight.
[/olist]

[h2]Optional weapon test[/h2]
Set [code]config.IncludePlayerDamage = true[/code], fully restart Palworld, and use one weapon for the entire fight. If a reliable weapon or projectile source is exposed it receives its own candidate; otherwise the result remains an unknown player-weapon candidate.

[h2]Scope[/h2]
[list]
[*][b]Target:[/b] Windows single-player worlds
[*][b]Current status:[/b] v0.1.1 diagnostic; Pal damage uses EPalWazaID when available
[*][b]Not a goal:[/b] comparing players or producing a competitive DPS leaderboard
[/list]

Source and issue tracker: [url=https://github.com/paul800901/PalSkillDPSAnalyzer]GitHub[/url]

[i]Independent MIT-licensed mod derived from AsahiChan-Game/PalBossDPSBroadcast. Unofficial and not affiliated with Pocketpair, Steam, or UE4SS.[/i]
