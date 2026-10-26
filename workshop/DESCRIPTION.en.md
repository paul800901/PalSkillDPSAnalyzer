[h1]Pal Skill DPS Analyzer[/h1]
[i]English first. 繁體中文說明在下半部。[/i]

[h2]What it measures[/h2]
A damage verification tool for Palworld 1.0 on Windows single-player worlds. Measure your Pals' actual skill damage against Bosses, damage shares, DPS and observed hits per cast. This is not a player leaderboard or a ranking based on skill power alone.
Pal damage is enabled by default; player/weapon damage is optional. Ordinary wild Pals and PvP are outside the supported test scope.

[h2]Install and start a test[/h2]
[olist]
[*]Subscribe to this mod and [url=https://steamcommunity.com/workshop/filedetails/?id=3625223587]UE4SS Experimental (Palworld)[/url]. Enable both in Mod Management and fully restart. PalSchema is not required.
[*]Enter a world and press [b]F3[/b]. Choose [b]Field/Dungeon Boss[/b] for field, dungeon or tower Bosses, or [b]Tablet Boss[/b] for summoned raid Bosses. Modes are selected manually.
[*]Close F3 and press [b]F2[/b] to clear results and arm a new test. [b]Timing begins with the first accepted Boss hit, not the F2 press.[/b]
[*]Attack the matching Boss with your Pal. Tablet mode also includes eligible base Pals from your guild. Default manual tests accumulate results until the next F2 reset. After changing the test type or damage-source settings, press F2 before the next test.
[/olist]

[h2]HUD, reports and settings[/h2]
[list]
[*]The HUD shows damage, DPS and skill shares without posting in game chat. It appears only while Palworld is in the foreground.
[*]F3 has [b]Settings[/b], [b]Grouped %[/b] and [b]Current Test Details[/b]. Details include damage/DPS, damaging and zero-damage casts, total hits and minimum/average/maximum hits per settled cast, including zero-hit casts.
[*]Tablet reports merge only the same species with identical complete three-skill loadouts. Matches show ×N; different loadouts form A/B groups. Incomplete loadouts stay separate.
[*]The tablet HUD shows the top three damage groups with up to three skill-share bars each; F3 lists all groups.
[*]F3 adjusts HUD visibility, position, scale and detail. Language can follow the game or be chosen from 17 languages. Manual and automatic per-target tests are available.
[/list]

[h2]Reading the numbers[/h2]
Directly linked skill sources are distinguished from limited, labelled inferred matches. Insufficient evidence stays unresolved: the mod does not guess from damage amount or merely from equipped skills. Some delayed hits and damage-over-time effects may remain unidentified.
Hit counts describe observations, not guaranteed full-hit counts. Actual intervals between casts include AI decisions and movement, not just cooldown. Hard tower tests count the main Boss, excluding adds.

[h2]Optional player/weapon tests[/h2]
Enable player/weapon damage in [b]F3 Settings[/b], then press F2. Use one weapon per test for a clean comparison. Recognizable weapon/projectile sources are listed separately; unidentified sources retain an unknown label.

[h2]Compatibility and support[/h2]
Current release: [b]v0.5.29[/b]. Windows single-player is the supported target; multiplayer and dedicated servers are unverified. Game or UE4SS updates may require compatibility fixes.
The HUD uses a bundled, separate Windows display process requiring Windows PowerShell 5.1 and WPF. It exits with the game. If security software blocks it, damage may still be recorded without a visible HUD.
For issues, include game/mod versions, the affected skill or test steps, and relevant UE4SS.log excerpts.

[url=https://github.com/paul800901/PalSkillDPSAnalyzer]Source and technical details[/url]
[i]Independent MIT-licensed derivative of AsahiChan-Game/PalBossDPSBroadcast (Boss detection, Pal ownership and safe messaging foundations). Skill attribution, HUD, native F3 interface and cast/hit statistics were developed by this project. Unofficial; not affiliated with Pocketpair, Steam or UE4SS.[/i]

[h2]Issue reports[/h2]
[url=https://discord.gg/Swzj4UjejE]Discord[/url] · [url=https://github.com/paul800901/PalSkillDPSAnalyzer/issues]GitHub[/url]
Include mod/version, Palworld, mode, steps, UE4SS.log. No private data.
