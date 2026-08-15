using UnrealBuildTool;

public class PalSkillDPSUI : ModuleRules
{
    public PalSkillDPSUI(ReadOnlyTargetRules Target) : base(Target)
    {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
        PublicDependencyModuleNames.AddRange(new[]
        {
            "Core",
            "CoreUObject",
            "Engine",
            "UMG",
            "CommonUI"
        });
    }
}
