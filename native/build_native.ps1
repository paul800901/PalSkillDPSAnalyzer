[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$UE4SSSource = "",
    [string]$FmtSource = "",
    [string]$ZydisSource = "",
    [string]$ZycoreSource = "",
    [string]$ImGuiSource = "",
    [string]$ImGuiTextEditSource = "",
    [string]$IconFontSource = "",
    [Parameter(Mandatory = $true)]
    [string]$UE4SSDll,
    [string]$BuildDirectory = "$PSScriptRoot\build-native"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$projectRootResolved = [System.IO.Path]::GetFullPath($ProjectRoot)
$lock = Get-Content -LiteralPath (Join-Path $projectRootResolved "tools\native-toolchain.lock.json") -Raw | ConvertFrom-Json
$expectedCommit = $lock.ue4ss.commit

if ([string]::IsNullOrWhiteSpace($UE4SSSource)) {
    $UE4SSSource = Join-Path $projectRootResolved "external\RE-UE4SS"
}
if ([string]::IsNullOrWhiteSpace($FmtSource)) {
    $FmtSource = Join-Path $projectRootResolved "external\fmt"
}
if ([string]::IsNullOrWhiteSpace($ZydisSource)) {
    $ZydisSource = Join-Path $projectRootResolved "external\zydis"
}
if ([string]::IsNullOrWhiteSpace($ZycoreSource)) {
    $ZycoreSource = Join-Path $projectRootResolved "external\zycore"
}
if ([string]::IsNullOrWhiteSpace($ImGuiSource)) {
    $ImGuiSource = Join-Path $projectRootResolved "external\imgui"
}
if ([string]::IsNullOrWhiteSpace($ImGuiTextEditSource)) {
    $ImGuiTextEditSource = Join-Path $projectRootResolved "external\imgui-text-edit"
}
if ([string]::IsNullOrWhiteSpace($IconFontSource)) {
    $IconFontSource = Join-Path $projectRootResolved "external\icon-font-cpp-headers"
}

if (-not (Test-Path -LiteralPath $UE4SSDll -PathType Leaf)) {
    throw "UE4SS.dll not found: $UE4SSDll"
}
$runtimeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $UE4SSDll).Hash
if ($runtimeHash -ne $lock.ue4ss.runtime_sha256) {
    throw "UE4SS runtime mismatch. Expected SHA256 $($lock.ue4ss.runtime_sha256), got $runtimeHash"
}
if (-not (Test-Path -LiteralPath "$UE4SSSource\.git")) {
    throw "UE4SS source checkout not found: $UE4SSSource"
}

$actualCommit = (& git -C $UE4SSSource rev-parse HEAD).Trim()
if ($actualCommit -ne $expectedCommit) {
    throw "UE4SS source commit mismatch. Expected $expectedCommit, got $actualCommit"
}
if (-not (Test-Path -LiteralPath "$UE4SSSource\deps\first\Unreal\include\Unreal" -PathType Container)) {
    throw "UEPseudo headers are unavailable. See docs\NATIVE_DEVELOPMENT.md and rerun tools\bootstrap_native_dependencies.ps1 after linking GitHub to Epic Games."
}
if (-not (Test-Path -LiteralPath "$FmtSource\include\fmt\core.h" -PathType Leaf)) {
    throw "fmt 11.2.0 source was not found: $FmtSource"
}
if (-not (Test-Path -LiteralPath "$ZydisSource\include\Zydis\Zydis.h" -PathType Leaf)) {
    throw "Zydis 4.1.1 source was not found: $ZydisSource"
}
if (-not (Test-Path -LiteralPath "$ZycoreSource\include\Zycore\Types.h" -PathType Leaf)) {
    throw "Zycore source was not found: $ZycoreSource"
}
if (-not (Test-Path -LiteralPath "$ImGuiSource\imgui.h" -PathType Leaf)) {
    throw "ImGui source was not found: $ImGuiSource"
}
if (-not (Test-Path -LiteralPath "$ImGuiTextEditSource\TextEditor.h" -PathType Leaf)) {
    throw "ImGuiColorTextEdit source was not found: $ImGuiTextEditSource"
}
if (-not (Test-Path -LiteralPath "$IconFontSource\IconsFontAwesome6.h" -PathType Leaf)) {
    throw "IconFontCppHeaders source was not found: $IconFontSource"
}

. (Join-Path $projectRootResolved "tools\enter_native_toolchain.ps1") -ProjectRoot $projectRootResolved
$toolDirectory = Join-Path $env:VCToolsInstallDir "bin\Hostx64\x64"
$dumpbin = Join-Path $toolDirectory "dumpbin.exe"
$libTool = Join-Path $toolDirectory "lib.exe"

New-Item -ItemType Directory -Path $BuildDirectory -Force | Out-Null
$defPath = Join-Path $BuildDirectory "UE4SS.def"
$libPath = Join-Path $BuildDirectory "UE4SS.lib"
$dumpPath = Join-Path $BuildDirectory "UE4SS.exports.txt"

& $dumpbin /nologo /exports $UE4SSDll | Set-Content -LiteralPath $dumpPath -Encoding ASCII
if ($LASTEXITCODE -ne 0) {
    throw "dumpbin failed with exit code $LASTEXITCODE"
}

$exports = [System.Collections.Generic.List[string]]::new()
foreach ($line in Get-Content -LiteralPath $dumpPath) {
    if ($line -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)\s*$') {
        $exports.Add($Matches[1])
    }
}
if ($exports.Count -lt 100) {
    throw "Unexpected UE4SS export count: $($exports.Count)"
}

$defLines = [System.Collections.Generic.List[string]]::new()
$defLines.Add("LIBRARY UE4SS")
$defLines.Add("EXPORTS")
foreach ($export in $exports) {
    $defLines.Add("    $export")
}
[System.IO.File]::WriteAllLines($defPath, $defLines, [System.Text.UTF8Encoding]::new($false))

& $libTool /nologo "/def:$defPath" /machine:x64 "/out:$libPath"
if ($LASTEXITCODE -ne 0) {
    throw "lib.exe failed with exit code $LASTEXITCODE"
}

$includeDirectories = @(
    "$UE4SSSource\UE4SS\include",
    "$UE4SSSource\UE4SS\generated_include",
    "$UE4SSSource\deps\first\Unreal\include",
    "$UE4SSSource\deps\first\Unreal\include\Unreal",
    "$UE4SSSource\deps\first\Unreal\include\Unreal\Core",
    "$UE4SSSource\deps\first\Unreal\generated_include",
    "$UE4SSSource\deps\first\LuaMadeSimple\include",
    "$UE4SSSource\deps\first\LuaRaw\include",
    "$UE4SSSource\deps\first\String\include",
    "$UE4SSSource\deps\first\File\include",
    "$UE4SSSource\deps\first\Function\include",
    "$UE4SSSource\deps\first\Helpers\include",
    "$UE4SSSource\deps\first\Input\include",
    "$UE4SSSource\deps\first\IniParser\include",
    "$UE4SSSource\deps\first\JSON\include",
    "$UE4SSSource\deps\first\MProgram\include",
    "$UE4SSSource\deps\first\ParserBase\include",
    "$UE4SSSource\deps\first\Profiler\include",
    "$UE4SSSource\deps\first\ScopedTimer\include",
    "$UE4SSSource\deps\first\SinglePassSigScanner\include",
    "$UE4SSSource\deps\first\Constructs\include",
    "$UE4SSSource\deps\first\DynamicOutput\include",
    "$UE4SSSource\deps\first\ASMHelper\include",
    "$FmtSource\include",
    "$ZydisSource\include",
    "$ZycoreSource\include",
    $ImGuiSource,
    $ImGuiTextEditSource,
    $IconFontSource,
    "$PSScriptRoot\include"
)
$includeArguments = @()
foreach ($directory in $includeDirectories) {
    $includeArguments += "/I$directory"
}

$nativeArguments = @(
    "/nologo", "/std:c++latest", "/EHsc", "/MD", "/O2", "/W4", "/utf-8",
    "/DUE_BUILD_SHIPPING=1", "/DUE_GAME=1",
    "/DPLATFORM_WINDOWS=1", "/DPLATFORM_MICROSOFT=1",
    "/DOVERRIDE_PLATFORM_HEADER_NAME=Windows", "/DUBT_COMPILED_PLATFORM=Win64",
    "/D_WIN32_WINNT=0x0A00", "/DWINVER=0x0A00",
    "/DFMT_HEADER_ONLY=1",
    "/D_UNICODE", "/DUNICODE", "/DWIN32_LEAN_AND_MEAN", "/LD",
    "/Fo:$BuildDirectory\BossDPSNativeCollector.obj",
    "$PSScriptRoot\src\BossDPSNativeCollector.cpp"
) + $includeArguments + @(
    "/link", $libPath, "/OUT:$BuildDirectory\main.dll",
    "/IMPLIB:$BuildDirectory\BossDPSNativeCollector.lib"
)
& cl.exe @nativeArguments
if ($LASTEXITCODE -ne 0) {
    throw "Native build failed with exit code $LASTEXITCODE"
}

$testArguments = @(
    "/nologo", "/std:c++latest", "/EHsc", "/MD", "/O2", "/W4",
    "$PSScriptRoot\tests\collector_stress.cpp",
    "/I$PSScriptRoot\include",
    "/Fo:$BuildDirectory\collector_stress.obj",
    "/Fe:$BuildDirectory\collector_stress.exe"
)
& cl.exe @testArguments
if ($LASTEXITCODE -ne 0) {
    throw "Native stress-test build failed with exit code $LASTEXITCODE"
}
& "$BuildDirectory\collector_stress.exe"
if ($LASTEXITCODE -ne 0) {
    throw "Native stress test failed with exit code $LASTEXITCODE"
}

foreach ($testName in @(
    "attribution_event_core_test",
    "native_event_queue_test",
    "pending_fingerprint_matcher_test"
)) {
    $sourcePath = Join-Path $PSScriptRoot "tests\$testName.cpp"
    $testArguments = @(
        "/nologo", "/std:c++latest", "/EHsc", "/MD", "/O2", "/W4", "/WX", "/utf-8",
        $sourcePath,
        "/I$PSScriptRoot\include",
        "/Fo:$BuildDirectory\$testName.obj",
        "/Fe:$BuildDirectory\$testName.exe"
    )
    & cl.exe @testArguments
    if ($LASTEXITCODE -ne 0) {
        throw "$testName build failed with exit code $LASTEXITCODE"
    }
    & "$BuildDirectory\$testName.exe"
    if ($LASTEXITCODE -ne 0) {
        throw "$testName failed with exit code $LASTEXITCODE"
    }
}

Write-Host "Native collector built: $BuildDirectory\main.dll"
