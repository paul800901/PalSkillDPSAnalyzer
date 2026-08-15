[CmdletBinding()]
param(
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $scriptDirectory = Split-Path -Parent $PSCommandPath
    $ProjectRoot = Split-Path -Parent $scriptDirectory
}

$projectRootResolved = [System.IO.Path]::GetFullPath($ProjectRoot)
$lockPath = Join-Path $projectRootResolved "tools\native-toolchain.lock.json"
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
$toolchainRoot = Join-Path $projectRootResolved ".toolchain"
$installPath = Join-Path $toolchainRoot "VSBuildTools"
$logRoot = Join-Path $toolchainRoot "logs"
$statusPath = Join-Path $toolchainRoot "install-status.json"
$logPath = Join-Path $logRoot "vs-buildtools-install.log"

New-Item -ItemType Directory -Path $installPath -Force | Out-Null
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

function Write-InstallStatus {
    param(
        [string]$State,
        [int]$ExitCode = 0,
        [string]$Message = ""
    )

    [ordered]@{
        state = $State
        exit_code = $ExitCode
        message = $Message
        install_path = $installPath
        updated_at = [DateTimeOffset]::Now.ToString("o")
    } | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding utf8
}

try {
    Write-InstallStatus -State "running" -Message "Installing Microsoft C++ Build Tools"

    $override = @(
        "--quiet"
        "--wait"
        "--norestart"
        "--installPath", ('"' + $installPath + '"')
        "--add", "Microsoft.VisualStudio.Workload.VCTools"
        "--includeRecommended"
    ) -join " "

    & winget install `
        --id Microsoft.VisualStudio.2022.BuildTools `
        --exact `
        --version $lock.visual_studio.product_version `
        --source winget `
        --accept-source-agreements `
        --accept-package-agreements `
        --disable-interactivity `
        --override $override 2>&1 | Tee-Object -LiteralPath $logPath

    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "winget/Visual Studio installer exited with code $exitCode"
    }

    $vcvars = Join-Path $installPath "VC\Auxiliary\Build\vcvars64.bat"
    if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) {
        throw "C++ environment script was not installed: $vcvars"
    }

    $toolVersionPath = Join-Path $installPath "VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt"
    $toolVersion = (Get-Content -LiteralPath $toolVersionPath -Raw).Trim()
    Write-InstallStatus -State "complete" -Message "Microsoft C++ Build Tools installed (MSVC $toolVersion)"
}
catch {
    $code = if ($LASTEXITCODE) { [int]$LASTEXITCODE } else { 1 }
    Write-InstallStatus -State "failed" -ExitCode $code -Message $_.Exception.Message
    throw
}
