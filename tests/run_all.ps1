$ErrorActionPreference = "Stop"

$testDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDirectory = Split-Path -Parent $testDirectory
$mainScript = Join-Path $projectDirectory "Scripts\main.lua"
$hudScript = Join-Path $projectDirectory "Scripts\hud.lua"
$configScript = Join-Path $projectDirectory "Scripts\config.lua"
$commentaryScript = Join-Path $projectDirectory "Scripts\commentary.lua"
$localizationScript = Join-Path $projectDirectory "Scripts\localization.lua"
$hudStringsScript = Join-Path $projectDirectory "Scripts\hud_strings.lua"
$skillNamesScript = Join-Path $projectDirectory "Scripts\skill_names.lua"
$skillEffectAttributionScript = Join-Path $projectDirectory "Scripts\skill_effect_attribution.lua"
$castEffectAttributionScript = Join-Path $projectDirectory "Scripts\cast_effect_attribution.lua"
$runtimeSourceChainScript = Join-Path $projectDirectory "Scripts\runtime_source_chain.lua"
$overlayScript = Join-Path $projectDirectory "Scripts\skill_dps_overlay.ps1"
$overlayLauncher = Join-Path $projectDirectory "Scripts\skill_dps_overlay_launcher.vbs"
$hudV1Fixture = Join-Path $testDirectory "fixtures\hud_v1_state.txt"
$hudV2Fixture = Join-Path $testDirectory "fixtures\hud_v2_state.txt"
$hudV2SettingsFixture = Join-Path $testDirectory "fixtures\hud_v2_settings_state.txt"
$hudV2SettingsEmptyFixture = Join-Path $testDirectory "fixtures\hud_v2_settings_empty_state.txt"
$localeDirectory = Join-Path $projectDirectory "Scripts\locales"
$workshopDirectory = Join-Path $projectDirectory "workshop\content"
$workshopScripts = Join-Path $workshopDirectory "Scripts"
$workshopUploadScript = Join-Path $projectDirectory "workshop\upload_workshop.ps1"
$workshopDescription = Join-Path $projectDirectory "workshop\DESCRIPTION.en.md"
$workshopLocalizationManifest = Join-Path $projectDirectory "workshop\localizations.json"
$workshopLocalizationValidator = Join-Path $projectDirectory "workshop\validate_localizations.ps1"

Write-Host "[1/5] Parsing Lua sources"
& npx --yes --package=luaparse luaparse --quiet --file $mainScript
if ($LASTEXITCODE -ne 0) { throw "main.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file $hudScript
if ($LASTEXITCODE -ne 0) { throw "hud.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file $configScript
if ($LASTEXITCODE -ne 0) { throw "config.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file $commentaryScript
if ($LASTEXITCODE -ne 0) { throw "commentary.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file $localizationScript
if ($LASTEXITCODE -ne 0) { throw "localization.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file $hudStringsScript
if ($LASTEXITCODE -ne 0) { throw "hud_strings.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file $skillNamesScript
if ($LASTEXITCODE -ne 0) { throw "skill_names.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file $skillEffectAttributionScript
if ($LASTEXITCODE -ne 0) { throw "skill_effect_attribution.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file $castEffectAttributionScript
if ($LASTEXITCODE -ne 0) { throw "cast_effect_attribution.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file $runtimeSourceChainScript
if ($LASTEXITCODE -ne 0) { throw "runtime_source_chain.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $testDirectory "test_cast_effect_attribution.lua")
if ($LASTEXITCODE -ne 0) { throw "test_cast_effect_attribution.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $testDirectory "test_runtime_source_chain.lua")
if ($LASTEXITCODE -ne 0) { throw "test_runtime_source_chain.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $testDirectory "fixtures\cast_effect_overlap.lua")
if ($LASTEXITCODE -ne 0) { throw "cast_effect_overlap.lua parse failed" }
foreach ($localePath in Get-ChildItem -LiteralPath $localeDirectory -Filter "*.lua" -File) {
    & npx --yes --package=luaparse luaparse --quiet --file $localePath.FullName
    if ($LASTEXITCODE -ne 0) { throw "locale parse failed: $($localePath.Name)" }
}
if (Select-String -Path $commentaryScript -Pattern "糖罐" -SimpleMatch -Quiet) {
    throw "commentary.lua contains a hard-coded guild name"
}

Write-Host "[2/5] Auditing forbidden crash-path APIs"
$forbidden = "ExecuteWithDelay|SendSystemAnnounce|GetIndividualCharacterParameterByActor|IsBossPal_Database\(|IsTowerBossPal\(|FindAllOf"
$forbiddenMatches = Select-String -LiteralPath $mainScript -Pattern $forbidden
if ($forbiddenMatches) {
    $forbiddenMatches | ForEach-Object { $_.Line } | Write-Host
    throw "forbidden API found in main.lua"
}
$forbiddenHud = "StaticConstructObject|WidgetBlueprintLibrary|PrintString|AddToViewport"
$hudForbiddenMatches = Select-String -LiteralPath $hudScript -Pattern $forbiddenHud
if ($hudForbiddenMatches) {
    $hudForbiddenMatches | ForEach-Object { $_.Line } | Write-Host
    throw "forbidden Unreal UI API found in hud.lua"
}
$hudText = Get-Content -LiteralPath $hudScript -Raw -Encoding UTF8
foreach ($requiredHudFeature in @(
    'config.EnableExternalHUDSettings ~= true',
    'external input path disabled',
    'watchdog_external_overlay',
    'command_ack=',
    'external HUD heartbeat stale',
    'external HUD relaunch suppressed after 3 attempts',
    'skill_dps_overlay_launcher.vbs',
    'wscript.exe',
    'sync_gameplay_visibility'
)) {
    if (-not $hudText.Contains($requiredHudFeature)) {
        throw "HUD recovery/input-lock feature missing: $requiredHudFeature"
    }
}
foreach ($forbiddenInputFeature in @(
    'SetIgnoreLookInput',
    'SetIgnoreMoveInput',
    'bShowMouseCursor',
    'DisableInput',
    'EnableInput'
)) {
    if ($hudText.Contains($forbiddenInputFeature)) {
        throw "external HUD must not mutate Palworld input: $forbiddenInputFeature"
    }
}
$overlayText = Get-Content -LiteralPath $overlayScript -Raw -Encoding UTF8
foreach ($requiredOverlayFeature in @(
    'Write-HudHeartbeat',
    'Assert-HudWindow',
    'add_UnhandledException',
    'command acknowledged id=',
    'reset_notice',
    'settingsSelectedTab',
    'settingsScrollOffset',
    'resultsScrollOffset',
    '$border.Height = $workspaceHeight',
    '[object]::ReferenceEquals($capturedTabs, $script:settingsTabs)',
    'Assert-HudWindow ([bool]$script:lastSettingsOpen) $false',
    '0x0020',
    '"DMG " + (Format-HudInteger $row.Damage)',
    'Format-HudDecimal $row.Dps'
)) {
    if (-not $overlayText.Contains($requiredOverlayFeature)) {
        throw "external HUD recovery feature missing: $requiredOverlayFeature"
    }
}
foreach ($forbiddenOverlayFeature in @(
    'SetForegroundWindow',
    'ShowCursor',
    'ReleaseClipCursor',
    '[Windows.Input.Keyboard]::Focus',
    '$window.Activate()',
    '$window.Focus()'
)) {
    if ($overlayText.Contains($forbiddenOverlayFeature)) {
        throw "display-only overlay contains cross-process input control: $forbiddenOverlayFeature"
    }
}

Write-Host "[3/5] Validating strict UTF-8"
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
foreach ($file in @(
    $mainScript,
    $hudScript,
    $configScript,
    $commentaryScript,
    $localizationScript,
    $hudStringsScript,
    $skillNamesScript,
    $skillEffectAttributionScript,
    $castEffectAttributionScript,
    $runtimeSourceChainScript,
    $overlayScript,
    $overlayLauncher,
    $hudV1Fixture,
    $hudV2Fixture,
    $hudV2SettingsFixture,
    $hudV2SettingsEmptyFixture,
    (Join-Path $testDirectory "test_main.lua"),
    (Join-Path $testDirectory "test_localization.lua"),
    (Join-Path $testDirectory "test_cast_effect_attribution.lua"),
    (Join-Path $testDirectory "test_runtime_source_chain.lua"),
    (Join-Path $testDirectory "fixtures\cast_effect_overlap.lua"),
    (Join-Path $workshopDirectory "Info.json"),
    (Join-Path $workshopDirectory "README.md"),
    $workshopDescription,
    $workshopLocalizationManifest,
    $workshopLocalizationValidator,
    (Join-Path $workshopScripts "main.lua"),
    (Join-Path $workshopScripts "hud.lua"),
    (Join-Path $workshopScripts "config.lua"),
    (Join-Path $workshopScripts "commentary.lua"),
    (Join-Path $workshopScripts "localization.lua"),
    (Join-Path $workshopScripts "hud_strings.lua"),
    (Join-Path $workshopScripts "skill_names.lua")
    ,(Join-Path $workshopScripts "skill_effect_attribution.lua")
    ,(Join-Path $workshopScripts "cast_effect_attribution.lua")
    ,(Join-Path $workshopScripts "runtime_source_chain.lua")
    ,(Join-Path $workshopScripts "skill_dps_overlay.ps1")
    ,(Join-Path $workshopScripts "skill_dps_overlay_launcher.vbs")
)) {
    [void]$utf8.GetString([System.IO.File]::ReadAllBytes($file))
}
foreach ($localePath in Get-ChildItem -LiteralPath $localeDirectory -Filter "*.lua" -File) {
    [void]$utf8.GetString([System.IO.File]::ReadAllBytes($localePath.FullName))
}
$workshopLocalizationEntries =
    Get-Content -LiteralPath $workshopLocalizationManifest -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($entry in $workshopLocalizationEntries) {
    $descriptionPath = Join-Path (Split-Path -Parent $workshopLocalizationManifest) $entry.description
    [void]$utf8.GetString([System.IO.File]::ReadAllBytes($descriptionPath))
}

Write-Host "[4/5] Validating Steam Workshop package"
$workshopInfo = Get-Content -LiteralPath (Join-Path $workshopDirectory "Info.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$expectedWorkshopTitle = -join @(
    [char]0x5E15, [char]0x9B6F, [char]0x6280, [char]0x80FD,
    " DPS ", [char]0x5206, [char]0x6790, [char]0x5668
)
if ($workshopInfo.ModName -ne $expectedWorkshopTitle) { throw "unexpected Workshop ModName" }
if ($workshopInfo.PackageName -ne "PalSkillDPSAnalyzerSP") { throw "unexpected Workshop PackageName" }
if ($workshopInfo.Version -ne "0.5.12") { throw "unexpected Workshop version" }
if ($workshopInfo.Dependencies -notcontains "UE4SSExperimentalPW") { throw "Workshop UE4SS dependency missing" }
if ($workshopInfo.InstallRule.Count -ne 1 -or $workshopInfo.InstallRule[0].Type -ne "Lua") {
    throw "Workshop Lua InstallRule missing"
}
foreach ($sharedName in @("main.lua", "hud.lua", "commentary.lua", "localization.lua", "hud_strings.lua", "skill_names.lua", "skill_effect_attribution.lua", "cast_effect_attribution.lua", "runtime_source_chain.lua")) {
    $sharedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $projectDirectory "Scripts\$sharedName")).Hash
    $workshopHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $workshopScripts $sharedName)).Hash
    if ($sharedHash -ne $workshopHash) { throw "Workshop $sharedName is not synchronized with shared core" }
}
$sharedOverlayHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $overlayScript).Hash
$workshopOverlayHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $workshopScripts "skill_dps_overlay.ps1")).Hash
if ($sharedOverlayHash -ne $workshopOverlayHash) { throw "Workshop external HUD script is not synchronized" }
$sharedLauncherHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $overlayLauncher).Hash
$workshopLauncher = Join-Path $workshopScripts "skill_dps_overlay_launcher.vbs"
$workshopLauncherHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $workshopLauncher).Hash
if ($sharedLauncherHash -ne $workshopLauncherHash) { throw "Workshop hidden HUD launcher is not synchronized" }
$launcherProbe = & cscript.exe //nologo $overlayLauncher --validate 2>&1
if ($LASTEXITCODE -ne 0) { throw "hidden HUD launcher validation failed: $launcherProbe" }
$sharedLocales = Get-ChildItem -LiteralPath $localeDirectory -Filter "*.lua" -File
if ($sharedLocales.Count -ne 17) { throw "expected exactly 17 shared locales" }
foreach ($localePath in $sharedLocales) {
    $workshopLocalePath = Join-Path $workshopScripts "locales\$($localePath.Name)"
    if (-not (Test-Path -LiteralPath $workshopLocalePath)) {
        throw "Workshop locale missing: $($localePath.Name)"
    }
    $sharedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $localePath.FullName).Hash
    $workshopHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $workshopLocalePath).Hash
    if ($sharedHash -ne $workshopHash) {
        throw "Workshop locale is not synchronized: $($localePath.Name)"
    }
}
$workshopConfig = Get-Content -LiteralPath (Join-Path $workshopScripts "config.lua") -Raw -Encoding UTF8
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
    "config.ExternalHUDAutoLaunch = true",
    "config.EnableExternalHUDSettings = false",
    "config.HUDUseExperimentalUMG = false",
    "config.HUDUseScreenTextFallback = false",
    "config.HUDShowInternalSkillCode = false",
    "config.SkillActionPostHitSeconds = 10",
    "config.SkillEffectMaxLifetimeSeconds = 45",
    "config.PreferNativeCollector = true",
    "config.AllowLegacyNativeAggregate = false"
)) {
    if (-not $workshopConfig.Contains($requiredSetting)) { throw "Workshop config missing: $requiredSetting" }
}
$thumbnail = Get-Item -LiteralPath (Join-Path $workshopDirectory "thumbnail.png")
if ($thumbnail.Length -gt 1048576) { throw "Workshop thumbnail exceeds 1 MiB" }
$uploadScriptText = Get-Content -LiteralPath $workshopUploadScript -Raw -Encoding UTF8
if ($uploadScriptText -match '(?i)password\s*=|\+login\s+[^$]') {
    throw "Workshop uploader must not embed a Steam password or account name"
}
if (-not $uploadScriptText.Contains('$description = $description.Replace("`r", "").Replace("`n", "")')) {
    throw "Workshop uploader must collapse description newlines before writing VDF"
}
if (-not $uploadScriptText.Contains('DESCRIPTION.en.md')) {
    throw "Workshop uploader must maintain English as the Steam fallback language"
}
$descriptionText = Get-Content -LiteralPath $workshopDescription -Raw -Encoding UTF8
foreach ($requiredTag in @("[h1]", "[/h1]", "[h2]", "[/h2]", "[olist]", "[/olist]")) {
    if (-not $descriptionText.Contains($requiredTag)) { throw "Workshop description missing: $requiredTag" }
}
if ($descriptionText.Contains('\n')) { throw "Workshop description contains a literal newline escape" }
[void][scriptblock]::Create((Get-Content -LiteralPath $workshopLocalizationValidator -Raw -Encoding UTF8))
& powershell -ExecutionPolicy Bypass -File $workshopLocalizationValidator
if ($LASTEXITCODE -ne 0) { throw "Workshop localization validation failed" }
[void][scriptblock]::Create($uploadScriptText)
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $workshopScripts "main.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop main.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $workshopScripts "hud.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop hud.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $workshopScripts "config.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop config.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $workshopScripts "commentary.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop commentary.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $workshopScripts "localization.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop localization.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $workshopScripts "hud_strings.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop hud_strings.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $workshopScripts "skill_names.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop skill_names.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $workshopScripts "skill_effect_attribution.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop skill_effect_attribution.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $workshopScripts "cast_effect_attribution.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop cast_effect_attribution.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $workshopScripts "runtime_source_chain.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop runtime_source_chain.lua parse failed" }
$overlayTokens = $null
$overlayErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $workshopScripts "skill_dps_overlay.ps1"),
    [ref]$overlayTokens,
    [ref]$overlayErrors
)
if ($overlayErrors.Count -gt 0) { throw "Workshop external HUD PowerShell parse failed" }

$windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$v1Validation = & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass `
    -File $overlayScript -StatePath $hudV1Fixture -ValidationMode
if ($LASTEXITCODE -ne 0 -or -not ($v1Validation -match "view=text rows=0")) {
    throw "external HUD V1 settings view runtime validation failed"
}
$v2Validation = & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass `
    -File $overlayScript -StatePath $hudV2Fixture -ValidationMode
if ($LASTEXITCODE -ne 0 -or -not ($v2Validation -match "view=meter rows=2")) {
    throw "external HUD V2 meter runtime validation failed"
}
if (-not ($v2Validation -match "meter_rebuilds=1")) {
    throw "external HUD V2 meter rebuilt on a data update instead of updating in place"
}
if (-not ($v2Validation -match "position_moves=1")) {
    throw "external HUD moved more than once while processing unchanged-anchor data snapshots"
}
$settingsValidation = & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass `
    -File $overlayScript -StatePath $hudV2SettingsFixture -ValidationMode
if ($LASTEXITCODE -ne 0 -or -not ($settingsValidation -match "view=settings rows=3.*tab_stable=1")) {
    throw "external HUD V2 interactive settings/results runtime validation failed"
}
$emptySettingsValidation = & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass `
    -File $overlayScript -StatePath $hudV2SettingsEmptyFixture -ValidationMode
if ($LASTEXITCODE -ne 0 -or -not ($emptySettingsValidation -match "view=settings rows=0.*tab_stable=1")) {
    throw "external HUD V2 empty-results runtime validation failed"
}
$settingsSize = [regex]::Match([string]$settingsValidation, 'desired=([0-9.]+x[0-9.]+)').Groups[1].Value
$emptySettingsSize = [regex]::Match([string]$emptySettingsValidation, 'desired=([0-9.]+x[0-9.]+)').Groups[1].Value
if ([string]::IsNullOrWhiteSpace($settingsSize) -or $settingsSize -ne $emptySettingsSize) {
    throw "settings/results workspace size changed with result content: $settingsSize vs $emptySettingsSize"
}

Write-Host "[5/5] Running integration, thread-affinity, lifetime, and stress tests"
Push-Location $testDirectory
try {
    $castEffectOutput = & npx --yes --package=fengari-node-cli fengari test_cast_effect_attribution.lua 2>&1
    $castEffectExitCode = $LASTEXITCODE
    $castEffectOutput | Write-Host
    if ($castEffectExitCode -ne 0 -or -not ($castEffectOutput -match "cast/effect attribution regression tests passed")) {
        throw "cast/effect attribution regression test failed or did not reach its completion marker"
    }
    $sourceChainOutput = & npx --yes --package=fengari-node-cli fengari test_runtime_source_chain.lua 2>&1
    $sourceChainExitCode = $LASTEXITCODE
    $sourceChainOutput | Write-Host
    if ($sourceChainExitCode -ne 0 -or -not ($sourceChainOutput -match "runtime source-chain hook regression tests passed")) {
        throw "runtime source-chain hook regression test failed or did not reach its completion marker"
    }
    $testOutput = & npx --yes --package=fengari-node-cli fengari test_main.lua 2>&1
    $testExitCode = $LASTEXITCODE
    $testOutput | Write-Host
    if ($testExitCode -ne 0 -or -not ($testOutput -match "v0\.5\.12 damage-lab/display/multitarget/source/thread/lifetime/stress tests passed")) {
        throw "Lua integration test failed or did not reach its completion marker"
    }
    $localeOutput = & npx --yes --package=fengari-node-cli fengari test_localization.lua 2>&1
    $localeExitCode = $LASTEXITCODE
    $localeOutput | Write-Host
    if ($localeExitCode -ne 0 -or -not ($localeOutput -match "localization tests passed for 17 languages")) {
        throw "Lua localization test failed or did not reach its completion marker"
    }
}
finally {
    Pop-Location
}

Write-Host "All offline checks passed. No PalServer process or live-server file was accessed."
