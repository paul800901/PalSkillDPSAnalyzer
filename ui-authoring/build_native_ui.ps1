$ErrorActionPreference = "Stop"

$authoringDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDirectory = Split-Path -Parent $authoringDirectory
$engineDirectory = Join-Path $projectDirectory ".toolchain\UnrealEngine-5.1"
$editor = Join-Path $engineDirectory "Engine\Binaries\Win64\UnrealEditor-Cmd.exe"
$unrealPak = Join-Path $engineDirectory "Engine\Binaries\Win64\UnrealPak.exe"
$buildTool = Join-Path $engineDirectory "Engine\Build\BatchFiles\Build.bat"
$uproject = Join-Path $authoringDirectory "PalSkillDPSUI.uproject"
$cookSource = Join-Path $authoringDirectory "Content\Mods\PalSkillDPSAnalyzerSP"
$cookedDirectory = Join-Path $authoringDirectory "Saved\Cooked\Windows\PalSkillDPSUI\Content\Mods\PalSkillDPSAnalyzerSP"
$cookedAsset = Join-Path $cookedDirectory "WBP_PalSkillDPSSettings.uasset"
$cookedExport = Join-Path $cookedDirectory "WBP_PalSkillDPSSettings.uexp"
$cookedBootstrapAsset = Join-Path $cookedDirectory "ModActor.uasset"
$cookedBootstrapExport = Join-Path $cookedDirectory "ModActor.uexp"
$pakDirectory = Join-Path $projectDirectory "workshop\content\Paks"
$pakPath = Join-Path $pakDirectory "PalSkillDPSAnalyzerSP_P.pak"
$responsePath = Join-Path $authoringDirectory "Saved\PalSkillDPSAnalyzerSP_P.response"
$logicPakDirectory = Join-Path $projectDirectory "workshop\content\LogicMods"
$logicPakPath = Join-Path $logicPakDirectory "PalSkillDPSAnalyzerSP.pak"
$logicResponsePath = Join-Path $authoringDirectory "Saved\PalSkillDPSAnalyzerSP_LogicMods.response"
$mountMarker = Join-Path $projectDirectory "workshop\content\Info.json"
$sourceAsset = Join-Path $cookSource "WBP_PalSkillDPSSettings.uasset"
$sourceAssetBackup = Join-Path $authoringDirectory "Saved\WBP_PalSkillDPSSettings.previous.uasset"
$sourceBootstrapAsset = Join-Path $cookSource "ModActor.uasset"
$sourceBootstrapBackup = Join-Path $authoringDirectory "Saved\ModActor.previous.uasset"

foreach ($required in @($editor, $unrealPak, $buildTool, $uproject, $mountMarker)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Native UI toolchain input missing: $required"
    }
}

& $buildTool PalSkillDPSUIEditor Win64 Development "-Project=$uproject" -WaitMutex -NoHotReloadFromIDE
if ($LASTEXITCODE -ne 0) {
    throw "Native UI generator compilation failed"
}

foreach ($generatedSource in @(
    @{ Source = $sourceAsset; Backup = $sourceAssetBackup },
    @{ Source = $sourceBootstrapAsset; Backup = $sourceBootstrapBackup }
)) {
    if (Test-Path -LiteralPath $generatedSource.Source) {
        Copy-Item -LiteralPath $generatedSource.Source -Destination $generatedSource.Backup -Force
        Remove-Item -LiteralPath $generatedSource.Source -Force
    }
}

& $editor $uproject -run=PalSkillDPSGenerateUI -stdout -unattended -nop4 -NoLogTimes
if ($LASTEXITCODE -ne 0) {
    foreach ($generatedSource in @(
        @{ Source = $sourceAsset; Backup = $sourceAssetBackup },
        @{ Source = $sourceBootstrapAsset; Backup = $sourceBootstrapBackup }
    )) {
        if (Test-Path -LiteralPath $generatedSource.Backup) {
            Copy-Item -LiteralPath $generatedSource.Backup -Destination $generatedSource.Source -Force
        }
    }
    throw "Native UI generation failed; previous generated asset restored"
}

& $editor $uproject -run=Cook -TargetPlatform=Windows -CookCultures=en "-CookDir=$cookSource" -unversioned -stdout -unattended -nop4 -NoLogTimes
if ($LASTEXITCODE -ne 0) { throw "Native UI cook failed" }

foreach ($required in @($cookedAsset, $cookedExport, $cookedBootstrapAsset, $cookedBootstrapExport)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Cooked native UI asset missing: $required"
    }
}

New-Item -ItemType Directory -Path $pakDirectory -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $responsePath) -Force | Out-Null
$responseLines = @(
    ('"{0}" "../../../Pal/Content/Mods/PalSkillDPSAnalyzerSP/WBP_PalSkillDPSSettings.uasset"' -f $cookedAsset),
    ('"{0}" "../../../Pal/Content/Mods/PalSkillDPSAnalyzerSP/WBP_PalSkillDPSSettings.uexp"' -f $cookedExport),
    ('"{0}" "../../../PalSkillDPSAnalyzerSP.mount.json"' -f $mountMarker)
)
[System.IO.File]::WriteAllLines($responsePath, $responseLines, [System.Text.UTF8Encoding]::new($false))

if (Test-Path -LiteralPath $pakPath) {
    Remove-Item -LiteralPath $pakPath -Force
}
& $unrealPak $pakPath "-Create=$responsePath"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $pakPath)) {
    throw "Native UI pak creation failed"
}

$pakListing = (& $unrealPak $pakPath -List 2>&1) -join "`n"
if (-not $pakListing.Contains("Mount point ../../../")) {
    throw "Native UI pak mount point is incorrect"
}
foreach ($requiredEntry in @(
    "Pal/Content/Mods/PalSkillDPSAnalyzerSP/WBP_PalSkillDPSSettings.uasset",
    "Pal/Content/Mods/PalSkillDPSAnalyzerSP/WBP_PalSkillDPSSettings.uexp",
    "PalSkillDPSAnalyzerSP.mount.json"
)) {
    if (-not $pakListing.Contains($requiredEntry)) {
        throw "Native UI pak entry missing: $requiredEntry"
    }
}

Write-Host "Native CommonUI package ready: $pakPath"

New-Item -ItemType Directory -Path $logicPakDirectory -Force | Out-Null
$logicResponseLines = @(
    ('"{0}" "../../../Pal/Content/Mods/PalSkillDPSAnalyzerSP/ModActor.uasset"' -f $cookedBootstrapAsset),
    ('"{0}" "../../../Pal/Content/Mods/PalSkillDPSAnalyzerSP/ModActor.uexp"' -f $cookedBootstrapExport)
)
[System.IO.File]::WriteAllLines($logicResponsePath, $logicResponseLines, [System.Text.UTF8Encoding]::new($false))

if (Test-Path -LiteralPath $logicPakPath) {
    Remove-Item -LiteralPath $logicPakPath -Force
}
& $unrealPak $logicPakPath "-Create=$logicResponsePath"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $logicPakPath)) {
    throw "LogicMods bootstrap pak creation failed"
}

$logicPakListing = (& $unrealPak $logicPakPath -List 2>&1) -join "`n"
if (-not $logicPakListing.Contains("Mount point ../../../Pal/Content/Mods/PalSkillDPSAnalyzerSP/")) {
    throw "LogicMods bootstrap pak mount point is incorrect"
}
foreach ($requiredEntry in @("ModActor.uasset", "ModActor.uexp")) {
    if (-not $logicPakListing.Contains($requiredEntry)) {
        throw "LogicMods bootstrap pak entry missing: $requiredEntry"
    }
}

Write-Host "LogicMods bootstrap package ready: $logicPakPath"
