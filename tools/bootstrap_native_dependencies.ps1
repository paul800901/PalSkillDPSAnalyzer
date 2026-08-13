[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [switch]$SkipRestrictedUEHeaders
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $scriptDirectory = Split-Path -Parent $PSCommandPath
    $ProjectRoot = Split-Path -Parent $scriptDirectory
}

$projectRootResolved = [System.IO.Path]::GetFullPath($ProjectRoot)
$lockPath = Join-Path $projectRootResolved "tools\native-toolchain.lock.json"
$externalRoot = Join-Path $projectRootResolved "external"
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json

New-Item -ItemType Directory -Path $externalRoot -Force | Out-Null

function Sync-Repository {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath (Join-Path $Destination ".git") -PathType Container)) {
        git clone --filter=blob:none --no-checkout $Repository $Destination
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone $Name from $Repository"
        }
    }

    git -C $Destination fetch --filter=blob:none origin $Commit
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to fetch locked $Name commit $Commit"
    }
    git -C $Destination checkout --detach $Commit
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to check out locked $Name commit $Commit"
    }

    $actual = (git -C $Destination rev-parse HEAD).Trim()
    if ($actual -ne $Commit) {
        throw "$Name commit mismatch. Expected $Commit, got $actual"
    }
}

$ue4ssPath = Join-Path $externalRoot "RE-UE4SS"
Sync-Repository `
    -Name "RE-UE4SS" `
    -Repository $lock.ue4ss.repository `
    -Commit $lock.ue4ss.commit `
    -Destination $ue4ssPath

git -C $ue4ssPath config submodule.deps/first/patternsleuth.url $lock.ue4ss.submodules.'deps/first/patternsleuth'.repository
git -C $ue4ssPath submodule update --init --checkout deps/first/patternsleuth
if ($LASTEXITCODE -ne 0) {
    throw "Failed to initialize the public patternsleuth submodule"
}

if (-not $SkipRestrictedUEHeaders) {
    git -C $ue4ssPath config submodule.deps/first/Unreal.url $lock.ue4ss.submodules.'deps/first/Unreal'.repository
    git -C $ue4ssPath submodule update --init --checkout deps/first/Unreal
    if ($LASTEXITCODE -ne 0) {
        throw @"
UEPseudo headers could not be downloaded. UE4SS requires the GitHub account used
by git to be linked to an Epic Games account. Complete that authorization, then
run this script again. No project source or installed game file was changed.
"@
    }
}

$dependencies = @(
    @{ Name = "fmt"; Entry = $lock.header_only_dependencies.fmt; Directory = "fmt" },
    @{ Name = "Zydis"; Entry = $lock.header_only_dependencies.zydis; Directory = "zydis" },
    @{ Name = "Zycore"; Entry = $lock.header_only_dependencies.zycore; Directory = "zycore" }
)

foreach ($dependency in $dependencies) {
    Sync-Repository `
        -Name $dependency.Name `
        -Repository $dependency.Entry.repository `
        -Commit $dependency.Entry.commit `
        -Destination (Join-Path $externalRoot $dependency.Directory)
}

Write-Output "Locked native dependencies are ready under $externalRoot"
if ($SkipRestrictedUEHeaders) {
    Write-Warning "UEPseudo was intentionally skipped; the native DLL cannot be compiled until it is available."
}
