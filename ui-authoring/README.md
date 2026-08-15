# Pal Skill DPS Native UI authoring

This project creates the cooked, in-game CommonUI settings assets for the mod.
It is intentionally isolated from the Palworld Modding Kit game module so it
does not require Wwise or any Palworld source module to build the widget.

The generated assets live under:

`/Game/Mods/PalSkillDPSAnalyzerSP`

They use only Engine, UMG, and CommonUI runtime classes. Creative Menu is an
architecture reference only and is not copied or required at runtime.
