[h1]Pal Skill DPS Analyzer[/h1]
[b]A single-player Boss damage verification tool for Palworld 1.0.[/b]

Measure each Pal skill's actual damage, DPS, share, hits and casts. This is not a player ranking meter. Field/dungeon Boss and tablet Boss tests are selected explicitly; tablet reports group same-species Pals only when their complete three-skill loadouts match.

[h2]Install and test[/h2]
[olist]
[*]Subscribe to this mod and [url=https://steamcommunity.com/workshop/filedetails/?id=3625223587]UE4SS Experimental (Palworld)[/url], enable both in Palworld's Mod Manager, then fully restart the game. PalSchema is not required.
[*]Press [b]F3[/b] and select Field/Dungeon Boss or Tablet Boss. Close Settings and press [b]F2[/b] to clear the previous result. Timing starts with the first accepted Boss hit.
[*]Let your Pals attack the selected Boss. The live HUD shows total damage, DPS and skill rows; F3 contains Settings, Grouped %, and Current Test Details.
[/olist]

[h2]Attribution and v0.5.43[/h2]
[list]
[*]v0.5.43 fixes the native F3 Settings page so English also updates section headings, field labels, and the Reset/Close buttons instead of leaving those controls in Chinese.
[*]Native evidence links casts, effects, AttackFilter Waza, Blueprint OnAttack and final damage. Exact and inferred evidence remain distinct; insufficient evidence stays Unattributed Damage.
[*]v0.5.42 extends the native bridge to every synchronously executing Blueprint SkillEffect that owns an AttackFilter. The effect's own attacker and Waza ID provide exact source identity without naming a skill or requiring a fixed loadout. This covers the reported Psychokinesis hits and the same engine pattern in other skills.
[*]Existing bounded rules for delayed ice impacts, Twin Spears, Flash Charge, Mummy Attack and meteor children remain in place. Damage amount, a general current/recent action or the equipped three skills alone never choose a skill.
[*]The meteor Rock-to-Ring identity links remain in place. UE4SS and PalSchema are not modified by this update.
[/list]

[h2]Display and scope[/h2]
[list]
[*]Pal damage is enabled by default; optional player/weapon damage can be enabled in F3. Use one weapon throughout a weapon test.
[*]The tablet HUD shows the three highest-damage loadout groups; all groups and each Pal's damage, DPS, damaging/no-damage casts and hit segments remain available in F3.
[*]Hard towers count only the main actor with a GYM identity. Ordinary wild Pals, PvP, multiplayer and dedicated servers are outside the verified scope.
[*][b]Current version:[/b] v0.5.43. Windows single-player target; UE4SS Experimental required.
[/list]

[url=https://github.com/paul800901/PalSkillDPSAnalyzer]Source and technical details[/url]
[i]Independent MIT-licensed derivative of AsahiChan-Game/PalBossDPSBroadcast. Unofficial; not affiliated with Pocketpair, Steam or UE4SS.[/i]

[h2]Issue reports[/h2]
[url=https://discord.gg/Swzj4UjejE]Palworld Mod Issue Reports on Discord[/url] · [url=https://github.com/paul800901/PalSkillDPSAnalyzer/issues]GitHub Issues[/url]
Include the mod name, Palworld version, mod version, single-player/multiplayer/dedicated-server environment, reproduction steps, and relevant UE4SS.log excerpts. Do not post passwords, account information, or full private paths.
