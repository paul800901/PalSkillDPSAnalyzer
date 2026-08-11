$ErrorActionPreference = "Stop"

$testDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDirectory = Split-Path -Parent $testDirectory
$mainScript = Join-Path $projectDirectory "Scripts\main.lua"
$configScript = Join-Path $projectDirectory "Scripts\config.lua"
$commentaryScript = Join-Path $projectDirectory "Scripts\commentary.lua"
$localizationScript = Join-Path $projectDirectory "Scripts\localization.lua"
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
& npx --yes --package=luaparse luaparse --quiet --file $configScript
if ($LASTEXITCODE -ne 0) { throw "config.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file $commentaryScript
if ($LASTEXITCODE -ne 0) { throw "commentary.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file $localizationScript
if ($LASTEXITCODE -ne 0) { throw "localization.lua parse failed" }
foreach ($localePath in Get-ChildItem -LiteralPath $localeDirectory -Filter "*.lua" -File) {
    & npx --yes --package=luaparse luaparse --quiet --file $localePath.FullName
    if ($LASTEXITCODE -ne 0) { throw "locale parse failed: $($localePath.Name)" }
}
if (Select-String -Path $commentaryScript -Pattern "糖罐" -SimpleMatch -Quiet) {
    throw "commentary.lua contains a hard-coded guild name"
}

Write-Host "[2/5] Auditing forbidden crash-path APIs"
$forbidden = "ExecuteWithDelay|SendSystemAnnounce|GetIndividualCharacterParameterByActor|IsBossPal_Database\(|IsTowerBossPal\(|FindAllOf"
$matches = & rg -n $forbidden $mainScript
if ($LASTEXITCODE -eq 0) {
    $matches | Write-Host
    throw "forbidden API found in main.lua"
}

Write-Host "[3/5] Validating strict UTF-8"
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
foreach ($file in @(
    $mainScript,
    $configScript,
    $commentaryScript,
    $localizationScript,
    (Join-Path $testDirectory "test_main.lua"),
    (Join-Path $testDirectory "test_localization.lua"),
    (Join-Path $workshopDirectory "Info.json"),
    (Join-Path $workshopDirectory "README.md"),
    $workshopDescription,
    $workshopLocalizationManifest,
    $workshopLocalizationValidator,
    (Join-Path $workshopScripts "main.lua"),
    (Join-Path $workshopScripts "config.lua"),
    (Join-Path $workshopScripts "commentary.lua"),
    (Join-Path $workshopScripts "localization.lua")
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
if ($workshopInfo.Version -ne "0.1.1") { throw "unexpected Workshop version" }
if ($workshopInfo.Dependencies -notcontains "UE4SSExperimentalPW") { throw "Workshop UE4SS dependency missing" }
if ($workshopInfo.InstallRule.Count -ne 1 -or $workshopInfo.InstallRule[0].Type -ne "Lua") {
    throw "Workshop Lua InstallRule missing"
}
foreach ($sharedName in @("main.lua", "commentary.lua", "localization.lua")) {
    $sharedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $projectDirectory "Scripts\$sharedName")).Hash
    $workshopHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $workshopScripts $sharedName)).Hash
    if ($sharedHash -ne $workshopHash) { throw "Workshop $sharedName is not synchronized with shared core" }
}
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
    "config.IncludePlayerDamage = false",
    "config.PreferNativeCollector = false"
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
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $workshopScripts "config.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop config.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $workshopScripts "commentary.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop commentary.lua parse failed" }
& npx --yes --package=luaparse luaparse --quiet --file (Join-Path $workshopScripts "localization.lua")
if ($LASTEXITCODE -ne 0) { throw "Workshop localization.lua parse failed" }

Write-Host "[5/5] Running integration, thread-affinity, lifetime, and stress tests"
Push-Location $testDirectory
try {
    $testOutput = & npx --yes --package=fengari-node-cli fengari test_main.lua 2>&1
    $testExitCode = $LASTEXITCODE
    $testOutput | Write-Host
    if ($testExitCode -ne 0 -or -not ($testOutput -match "v0\.1\.1 diagnostic/source/thread/lifetime/stress tests passed")) {
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
