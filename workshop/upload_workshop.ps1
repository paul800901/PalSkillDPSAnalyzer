param(
    [Parameter(Mandatory = $true)]
    [string]$SteamCmdPath,

    [string]$SteamAccountName = "",

    [ValidateSet(0, 1, 2)]
    [int]$Visibility = 0
)

$ErrorActionPreference = "Stop"

function ConvertTo-VdfValue([string]$Value) {
    return $Value.Replace("\", "\\").Replace('"', '\"').Replace("`r", "").Replace("`n", "\n")
}

$workshopDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$contentDirectory = Join-Path $workshopDirectory "content"
$distDirectory = Join-Path $workshopDirectory "dist"
$buildScript = Join-Path $workshopDirectory "build_workshop.ps1"

if (-not (Test-Path -LiteralPath $SteamCmdPath -PathType Leaf)) {
    throw "steamcmd.exe not found: $SteamCmdPath"
}
if ([string]::IsNullOrWhiteSpace($SteamAccountName)) {
    $SteamAccountName = Read-Host "Steam login account name"
}
if ([string]::IsNullOrWhiteSpace($SteamAccountName)) {
    throw "Steam account name is required"
}

& powershell -ExecutionPolicy Bypass -File $buildScript
if ($LASTEXITCODE -ne 0) { throw "Workshop package validation failed" }

$metadataPath = Join-Path $contentDirectory ".workshop.json"
$metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
$publishedFileId = [string]$metadata.publishedfileid
if ([string]::IsNullOrWhiteSpace($publishedFileId)) { $publishedFileId = "0" }

$description = Get-Content -LiteralPath (Join-Path $workshopDirectory "DESCRIPTION.en.md") -Raw -Encoding UTF8
# SteamCMD stores escaped newlines as the visible text "\n". Steam BBCode block tags
# provide the layout, so collapse physical line breaks before writing the VDF.
$description = $description.Replace("`r", "").Replace("`n", "")
$workshopTitle = "Pal Skill DPS Analyzer - Damage Verification"
$steamCmdDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($SteamCmdPath))
$stagingDirectory = Join-Path $steamCmdDirectory ("workshop\PalSkillDPSAnalyzerSP-{0}" -f $PID)
$stagedContentDirectory = Join-Path $stagingDirectory "content"
New-Item -ItemType Directory -Path $stagedContentDirectory -Force | Out-Null
Get-ChildItem -LiteralPath $contentDirectory -Force | Copy-Item -Destination $stagedContentDirectory -Recurse -Force
$vdfPath = Join-Path $stagingDirectory "PalSkillDPSAnalyzerSP.workshop.vdf"
$vdf = @(
    '"workshopitem"'
    '{'
    '    "appid" "1623730"'
    ('    "publishedfileid" "{0}"' -f (ConvertTo-VdfValue $publishedFileId))
    ('    "contentfolder" "{0}"' -f (ConvertTo-VdfValue $stagedContentDirectory))
    ('    "previewfile" "{0}"' -f (ConvertTo-VdfValue (Join-Path $stagedContentDirectory "thumbnail.png")))
    ('    "visibility" "{0}"' -f $Visibility)
    ('    "title" "{0}"' -f (ConvertTo-VdfValue $workshopTitle))
    ('    "description" "{0}"' -f (ConvertTo-VdfValue $description))
    '    "changenote" "v0.1.1 diagnostic: attribute Pal damage with EPalWazaID and BasePower fallback."'
    '}'
) -join "`r`n"
[System.IO.File]::WriteAllText($vdfPath, $vdf, [System.Text.UTF8Encoding]::new($false))

Write-Host "ASCII-only upload staging directory: $stagingDirectory"
Write-Host "SteamCMD will request your password and Steam Guard code in this terminal."
Write-Host "The script never stores or passes your password on the command line."
& $SteamCmdPath +login $SteamAccountName +workshop_build_item $vdfPath +quit
if ($LASTEXITCODE -ne 0) { throw "SteamCMD Workshop upload failed with exit code $LASTEXITCODE" }

$updatedVdf = Get-Content -LiteralPath $vdfPath -Raw -Encoding UTF8
$match = [regex]::Match($updatedVdf, '"publishedfileid"\s+"([0-9]+)"')
if (-not $match.Success -or $match.Groups[1].Value -eq "0") {
    throw "Upload completed but SteamCMD did not return a Published File ID"
}

$metadata.publishedfileid = $match.Groups[1].Value
$metadata.changenote = "v0.1.1 diagnostic: attribute Pal damage with EPalWazaID and BasePower fallback."
$metadata.last_published_version = "0.1.1"
$metadataJson = $metadata | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($metadataPath, $metadataJson + "`r`n", [System.Text.UTF8Encoding]::new($false))

Write-Host "Workshop upload succeeded. Published File ID: $($match.Groups[1].Value)"
Write-Host "Open: https://steamcommunity.com/sharedfiles/filedetails/?id=$($match.Groups[1].Value)"
