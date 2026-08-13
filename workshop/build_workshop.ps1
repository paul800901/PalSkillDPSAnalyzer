$ErrorActionPreference = "Stop"

$workshopDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDirectory = Split-Path -Parent $workshopDirectory
$contentDirectory = Join-Path $workshopDirectory "content"
$contentScripts = Join-Path $contentDirectory "Scripts"
$contentLocales = Join-Path $contentScripts "locales"
$distDirectory = Join-Path $workshopDirectory "dist"

New-Item -ItemType Directory -Path $contentScripts -Force | Out-Null
New-Item -ItemType Directory -Path $contentLocales -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectDirectory "Scripts\main.lua") -Destination (Join-Path $contentScripts "main.lua") -Force
Copy-Item -LiteralPath (Join-Path $projectDirectory "Scripts\hud.lua") -Destination (Join-Path $contentScripts "hud.lua") -Force
Copy-Item -LiteralPath (Join-Path $projectDirectory "Scripts\commentary.lua") -Destination (Join-Path $contentScripts "commentary.lua") -Force
Copy-Item -LiteralPath (Join-Path $projectDirectory "Scripts\localization.lua") -Destination (Join-Path $contentScripts "localization.lua") -Force
Copy-Item -LiteralPath (Join-Path $projectDirectory "Scripts\hud_strings.lua") -Destination (Join-Path $contentScripts "hud_strings.lua") -Force
Copy-Item -LiteralPath (Join-Path $projectDirectory "Scripts\skill_names.lua") -Destination (Join-Path $contentScripts "skill_names.lua") -Force
Copy-Item -LiteralPath (Join-Path $projectDirectory "Scripts\skill_effect_attribution.lua") -Destination (Join-Path $contentScripts "skill_effect_attribution.lua") -Force
Copy-Item -LiteralPath (Join-Path $projectDirectory "Scripts\cast_effect_attribution.lua") -Destination (Join-Path $contentScripts "cast_effect_attribution.lua") -Force
Copy-Item -LiteralPath (Join-Path $projectDirectory "Scripts\runtime_source_chain.lua") -Destination (Join-Path $contentScripts "runtime_source_chain.lua") -Force
Copy-Item -LiteralPath (Join-Path $projectDirectory "Scripts\skill_dps_overlay.ps1") -Destination (Join-Path $contentScripts "skill_dps_overlay.ps1") -Force
Copy-Item -LiteralPath (Join-Path $projectDirectory "Scripts\skill_dps_overlay_launcher.vbs") -Destination (Join-Path $contentScripts "skill_dps_overlay_launcher.vbs") -Force
Copy-Item -Path (Join-Path $projectDirectory "Scripts\locales\*.lua") -Destination $contentLocales -Force
Copy-Item -LiteralPath (Join-Path $workshopDirectory "assets\thumbnail-pal-skill-dps-v1.png") -Destination (Join-Path $contentDirectory "thumbnail.png") -Force

$infoPath = Join-Path $contentDirectory "Info.json"
$info = Get-Content -LiteralPath $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json
$expectedWorkshopTitle = -join @(
    [char]0x5E15, [char]0x9B6F, [char]0x6280, [char]0x80FD,
    " DPS ", [char]0x5206, [char]0x6790, [char]0x5668
)
if ($info.ModName -ne $expectedWorkshopTitle) { throw "Unexpected Workshop ModName" }
if ($info.PackageName -ne "PalSkillDPSAnalyzerSP") { throw "Unexpected Workshop PackageName" }
if ($info.Version -ne "0.5.12") { throw "Unexpected Workshop version" }
if ($info.Dependencies -notcontains "UE4SSExperimentalPW") { throw "UE4SS dependency missing" }
if ($info.InstallRule.Count -ne 1 -or $info.InstallRule[0].Type -ne "Lua") { throw "Lua InstallRule missing" }

$configPath = Join-Path $contentScripts "config.lua"
$configText = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
foreach ($requiredSetting in @(
    "config.LocalOnlyMessages = true",
    "config.EnableSkillDiagnostics = true",
    "config.SkillDiagnosticsOnly = true",
    "config.EnableSkillSourceChain = true",
    "config.IncludePlayerDamage = false",
    'config.SkillDiagnosticChatMode = "off"',
    "config.EnableSkillDPSHUD = true",
    'config.MeasurementMode = "manual"',
    'config.TargetScope = "all"',
    "config.HUDSettingsVersion = 3",
    'config.HUDDetailMode = "compact"',
    "config.EnableExternalHUD = true",
    "config.EnableExternalHUDSettings = false",
    "config.ExternalHUDAutoLaunch = true",
    "config.HUDUseExperimentalUMG = false",
    "config.HUDUseScreenTextFallback = false",
    "config.HUDShowInternalSkillCode = false",
    "config.SkillActionPostHitSeconds = 10",
    "config.SkillEffectMaxLifetimeSeconds = 45",
    "config.PreferNativeCollector = false"
)) {
    if (-not $configText.Contains($requiredSetting)) { throw "Workshop config missing: $requiredSetting" }
}

$thumbnailPath = Join-Path $contentDirectory "thumbnail.png"
if (-not (Test-Path -LiteralPath $thumbnailPath)) { throw "Workshop thumbnail.png missing" }
if ((Get-Item -LiteralPath $thumbnailPath).Length -gt 1048576) { throw "Workshop thumbnail exceeds 1 MiB" }

& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $contentScripts "main.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop main.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $contentScripts "hud.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop hud.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file $configPath
if ($LASTEXITCODE -ne 0) { throw "Workshop config.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $contentScripts "commentary.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop commentary.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $contentScripts "localization.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop localization.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $contentScripts "hud_strings.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop hud_strings.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $contentScripts "skill_names.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop skill_names.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $contentScripts "skill_effect_attribution.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop skill_effect_attribution.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $contentScripts "cast_effect_attribution.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop cast_effect_attribution.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $contentScripts "runtime_source_chain.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop runtime_source_chain.lua parse failed" }
$overlayTokens = $null
$overlayErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $contentScripts "skill_dps_overlay.ps1"),
    [ref]$overlayTokens,
    [ref]$overlayErrors
)
if ($overlayErrors.Count -gt 0) { throw "Workshop external HUD PowerShell parse failed" }
$launcherPath = Join-Path $contentScripts "skill_dps_overlay_launcher.vbs"
$launcherProbe = & cscript.exe //nologo $launcherPath --validate 2>&1
if ($LASTEXITCODE -ne 0) { throw "Workshop hidden HUD launcher validation failed: $launcherProbe" }
foreach ($localePath in Get-ChildItem -LiteralPath $contentLocales -Filter "*.lua" -File) {
    & npx --yes --package=luaparse luaparse --quiet --file $localePath.FullName
    if ($LASTEXITCODE -ne 0) { throw "Workshop locale parse failed: $($localePath.Name)" }
}

New-Item -ItemType Directory -Path $distDirectory -Force | Out-Null
$zipPath = Join-Path $distDirectory "PalSkillDPSAnalyzerSP-Workshop-v0.5.12.zip"
Compress-Archive -Path (Join-Path $contentDirectory "*") -DestinationPath $zipPath -CompressionLevel Optimal -Force

Write-Host "Workshop package ready: $zipPath"
