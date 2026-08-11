[h1]Pal Skill DPS Analyzer[/h1]
[b]A single-player damage verification tool for Palworld 1.0.[/b]

This is not a player ranking meter. Each Pal is an independent test source. Damage and action-lifecycle evidence are grouped per skill. Reports include total damage, encounter DPS, share, hits, observed casts, damage per cast, full action duration, cast DPS, actual start interval, and reuse gap.

[h2]Dedicated HUD and F1 settings[/h2]
[list]
[*]Pal damage enabled by default; player/weapon damage disabled by default
[*]Optional one-weapon-per-fight player verification mode
[*]Evidence-backed candidates; unknown damage is never assigned a guessed skill name
[*]Official in-game localized skill names shown together with internal English codes
[*]Panel cooldown compared with observed cast-start intervals affected by combat AI, movement, and skill selection
[*]Damage per cast, full action duration, cast DPS, reuse gap, and timing coverage shown at completion
[*]Dedicated top-right skill-DPS HUD updates live, stays after combat, and replaces chat output by default
[*]F1 changes player damage, full/compact detail, position, scale, post-fight retention, and chat mode
[*]Bounded per-hit and per-cast evidence in UE4SS.log
[*]Boss defeat, capture, and inactivity completion paths
[/list]

[h2]Installation[/h2]
[olist]
[*]Subscribe to this mod.
[*]Subscribe to and enable [url=https://steamcommunity.com/workshop/filedetails/?id=3625223587]UE4SS Experimental (Palworld)[/url].
[*]Enable both mods in Palworld's Mod Manager.
[*]Enter a world and press F1 to verify the settings panel.
[*]Use one Pal with known skills against a Boss, then keep UE4SS.log after the fight.
[/olist]

[h2]Optional weapon test[/h2]
Enable player damage in the F1 panel and use one weapon for the entire fight. If a reliable weapon or projectile source is exposed it receives its own candidate; otherwise the result remains an unknown player-weapon candidate.

[h2]Scope[/h2]
[list]
[*][b]Target:[/b] Windows single-player worlds
[*][b]Current status:[/b] v0.3.0 HUD with localized names, panel/observed cooldown comparison, and full-action DPS
[*][b]Required dependency:[/b] UE4SS Experimental; PalSchema is not required
[*][b]Not a goal:[/b] comparing players or producing a competitive DPS leaderboard
[/list]

Source and issue tracker: [url=https://github.com/paul800901/PalSkillDPSAnalyzer]GitHub[/url]

[i]Independent MIT-licensed mod derived from AsahiChan-Game/PalBossDPSBroadcast. Unofficial and not affiliated with Pocketpair, Steam, or UE4SS.[/i]
