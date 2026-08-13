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
$vcvars = Join-Path $projectRootResolved ".toolchain\VSBuildTools\VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) {
    throw "Project C++ toolchain is not installed. Run tools\install_native_toolchain.ps1 first."
}

$environmentDump = & cmd.exe /s /c ('"' + $vcvars + '" >nul && set')
if ($LASTEXITCODE -ne 0) {
    throw "vcvars64.bat failed with exit code $LASTEXITCODE"
}

foreach ($line in $environmentDump) {
    $separator = $line.IndexOf('=')
    if ($separator -le 0) {
        continue
    }

    $name = $line.Substring(0, $separator)
    $value = $line.Substring($separator + 1)
    Set-Item -Path ("Env:" + $name) -Value $value
}

Write-Output "Project C++ toolchain activated: $vcvars"
