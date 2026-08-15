$ErrorActionPreference = "Stop"

$workshopDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $workshopDirectory "localizations.json"
$entries = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($entries.Count -ne 2) {
    throw "Expected English and Traditional Chinese Workshop localizations, found $($entries.Count)"
}

$seenLocales = @{}
$seenSteamCodes = @{}
foreach ($entry in $entries) {
    if ([string]::IsNullOrWhiteSpace($entry.locale)) { throw "Localization locale is empty" }
    if ([string]::IsNullOrWhiteSpace($entry.steam)) { throw "Steam language code is empty" }
    if ([string]::IsNullOrWhiteSpace($entry.title)) { throw "Title is empty for $($entry.locale)" }
    if ($entry.title.Length -gt 128) { throw "Title is too long for $($entry.locale)" }
    if ($seenLocales.ContainsKey($entry.locale)) { throw "Duplicate locale: $($entry.locale)" }
    if ($seenSteamCodes.ContainsKey($entry.steam)) { throw "Duplicate Steam language: $($entry.steam)" }
    $seenLocales[$entry.locale] = $true
    $seenSteamCodes[$entry.steam] = $true

    $descriptionPath = Join-Path $workshopDirectory $entry.description
    if (-not (Test-Path -LiteralPath $descriptionPath)) {
        throw "Description missing for $($entry.locale): $descriptionPath"
    }
    $description = Get-Content -LiteralPath $descriptionPath -Raw -Encoding UTF8
    foreach ($requiredText in @(
        "[h1]", "[/h1]", "[h2]", "[/h2]", "3625223587",
        "github.com/paul800901/PalSkillDPSAnalyzer"
    )) {
        if (-not $description.Contains($requiredText)) {
            throw "$($entry.locale) description is missing: $requiredText"
        }
    }
}

Write-Host "Workshop localization validation passed for English and Traditional Chinese."
