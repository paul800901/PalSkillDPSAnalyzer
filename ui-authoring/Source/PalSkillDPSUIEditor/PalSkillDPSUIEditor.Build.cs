using UnrealBuildTool;

public class PalSkillDPSUIEditor : ModuleRules
{
    public PalSkillDPSUIEditor(ReadOnlyTargetRules Target) : base(Target)
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
        PrivateDependencyModuleNames.AddRange(new[]
        {
            "UnrealEd",
            "UMGEditor",
            "Kismet",
            "BlueprintGraph",
            "KismetCompiler",
            "AssetRegistry",
            "AssetTools",
            "Slate",
            "SlateCore"
        });
    }
}
