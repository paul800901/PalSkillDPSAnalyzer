using UnrealBuildTool;
using System.Collections.Generic;

public class PalSkillDPSUITarget : TargetRules
{
    public PalSkillDPSUITarget(TargetInfo Target) : base(Target)
    {
        Type = TargetType.Game;
        DefaultBuildSettings = BuildSettingsVersion.V2;
        ExtraModuleNames.Add("PalSkillDPSUI");
    }
}
