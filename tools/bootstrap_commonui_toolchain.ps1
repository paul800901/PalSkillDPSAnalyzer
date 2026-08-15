[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$LogRoot = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $scriptDirectory = Split-Path -Parent $PSCommandPath
    $ProjectRoot = Split-Path -Parent $scriptDirectory
}

$projectRootResolved = [System.IO.Path]::GetFullPath($ProjectRoot)
$lockPath = Join-Path $projectRootResolved "tools\commonui-toolchain.lock.json"
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
$toolchainRoot = Join-Path $projectRootResolved ".toolchain"

if ([string]::IsNullOrWhiteSpace($LogRoot)) {
    $LogRoot = Join-Path $toolchainRoot "logs\commonui"
}

$logRootResolved = [System.IO.Path]::GetFullPath($LogRoot)
$statusPath = Join-Path $logRootResolved "bootstrap-status.json"
$logPath = Join-Path $logRootResolved "bootstrap.log"

New-Item -ItemType Directory -Path $toolchainRoot -Force | Out-Null
New-Item -ItemType Directory -Path $logRootResolved -Force | Out-Null

function Write-BootstrapStatus {
    param(
        [string]$State,
        [string]$Stage,
        [string]$Message = ""
    )

    [ordered]@{
        state = $State
        stage = $Stage
        message = $Message
        unreal_engine = Join-Path $projectRootResolved $lock.unreal_engine.install_directory
        palworld_modding_kit = Join-Path $projectRootResolved $lock.palworld_modding_kit.install_directory
        updated_at = [DateTimeOffset]::Now.ToString("o")
    } | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding utf8
}

function Invoke-LoggedGit {
    param([string[]]$Arguments)

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & git @Arguments 2>&1 | Tee-Object -FilePath $logPath -Append
        $gitExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($gitExitCode -ne 0) {
        throw "git exited with code ${gitExitCode}: git $($Arguments -join ' ')"
    }
}

function Install-PinnedRepository {
    param(
        [pscustomobject]$Repository,
        [string]$Name
    )

    $destination = [System.IO.Path]::GetFullPath((Join-Path $projectRootResolved $Repository.install_directory))
    $gitDirectory = Join-Path $destination ".git"

    if (-not (Test-Path -LiteralPath $gitDirectory -PathType Container)) {
        if (Test-Path -LiteralPath $destination) {
            throw "$Name destination exists but is not a Git checkout: $destination"
        }

        Write-BootstrapStatus -State "running" -Stage "clone-$Name" -Message $destination
        Invoke-LoggedGit -Arguments @(
            "clone",
            "--depth", "1",
            "--single-branch",
            "--branch", [string]$Repository.branch,
            [string]$Repository.repository,
            $destination
        )
    }

    Write-BootstrapStatus -State "running" -Stage "verify-$Name" -Message $destination
    $actualCommit = (& git -C $destination rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot read $Name checkout commit: $destination"
    }

    if ($actualCommit -ne [string]$Repository.commit) {
        throw "$Name checkout is not the locked commit. Expected $($Repository.commit), got $actualCommit"
    }

    Add-Content -LiteralPath $logPath -Encoding utf8 -Value "$Name verified at $actualCommit"
}

try {
    Write-BootstrapStatus -State "running" -Stage "preflight" -Message "Checking GitHub access"
    & gh api repos/EpicGames/UnrealEngine *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "EpicGames/UnrealEngine is not accessible. Verify the Epic-GitHub account link and gh authentication."
    }

    Install-PinnedRepository -Repository $lock.palworld_modding_kit -Name "palworld-modding-kit"
    Install-PinnedRepository -Repository $lock.unreal_engine -Name "unreal-engine-5.1"

    Write-BootstrapStatus -State "complete" -Stage "source-checkouts" -Message "Pinned source checkouts are ready"
}
catch {
    Write-BootstrapStatus -State "failed" -Stage "bootstrap" -Message $_.Exception.Message
    throw
}
