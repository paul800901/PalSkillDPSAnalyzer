[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$UE4SSDll = "E:\Program Files (x86)\Steam\steamapps\common\Palworld\Mods\NativeMods\UE4SS\UE4SS.dll",
    [switch]$RequireDependencies
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $scriptDirectory = Split-Path -Parent $PSCommandPath
    $ProjectRoot = Split-Path -Parent $scriptDirectory
}

$projectRootResolved = [System.IO.Path]::GetFullPath($ProjectRoot)
$lock = Get-Content -LiteralPath (Join-Path $projectRootResolved "tools\native-toolchain.lock.json") -Raw | ConvertFrom-Json
$issues = [System.Collections.Generic.List[string]]::new()

$vcVersionPath = Join-Path $projectRootResolved ".toolchain\VSBuildTools\VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt"
if (-not (Test-Path -LiteralPath $vcVersionPath -PathType Leaf)) {
    $issues.Add("Project-local Visual Studio Build Tools are not installed")
}
else {
    $actualVersion = (Get-Content -LiteralPath $vcVersionPath -Raw).Trim()
    if ($actualVersion -ne $lock.visual_studio.msvc_version) {
        $issues.Add("MSVC mismatch: expected $($lock.visual_studio.msvc_version), got $actualVersion")
    }
}

if (-not (Test-Path -LiteralPath $UE4SSDll -PathType Leaf)) {
    $issues.Add("UE4SS runtime was not found: $UE4SSDll")
}
else {
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $UE4SSDll).Hash
    if ($actualHash -ne $lock.ue4ss.runtime_sha256) {
        $issues.Add("UE4SS runtime hash mismatch: expected $($lock.ue4ss.runtime_sha256), got $actualHash")
    }
}

if ($RequireDependencies) {
    $repositories = @(
        @{ Name = "RE-UE4SS"; Path = "external\RE-UE4SS"; Commit = $lock.ue4ss.commit },
        @{ Name = "fmt"; Path = "external\fmt"; Commit = $lock.header_only_dependencies.fmt.commit },
        @{ Name = "Zydis"; Path = "external\zydis"; Commit = $lock.header_only_dependencies.zydis.commit },
        @{ Name = "Zycore"; Path = "external\zycore"; Commit = $lock.header_only_dependencies.zycore.commit },
        @{ Name = "ImGui"; Path = "external\imgui"; Commit = $lock.header_only_dependencies.imgui.commit },
        @{ Name = "ImGuiColorTextEdit"; Path = "external\imgui-text-edit"; Commit = $lock.header_only_dependencies.imgui_text_edit.commit },
        @{ Name = "IconFontCppHeaders"; Path = "external\icon-font-cpp-headers"; Commit = $lock.header_only_dependencies.icon_font_cpp_headers.commit }
    )
    foreach ($repository in $repositories) {
        $path = Join-Path $projectRootResolved $repository.Path
        if (-not (Test-Path -LiteralPath (Join-Path $path ".git") -PathType Container)) {
            $issues.Add("$($repository.Name) checkout is missing: $path")
            continue
        }
        $actualCommit = (git -C $path rev-parse HEAD).Trim()
        if ($actualCommit -ne $repository.Commit) {
            $issues.Add("$($repository.Name) commit mismatch: expected $($repository.Commit), got $actualCommit")
        }
    }

    foreach ($requiredHeader in @(
        "external\imgui\imgui.h",
        "external\imgui-text-edit\TextEditor.h",
        "external\icon-font-cpp-headers\IconsFontAwesome6.h"
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $projectRootResolved $requiredHeader) -PathType Leaf)) {
            $issues.Add("Required UE4SS UI header is missing: $requiredHeader")
        }
    }

    $unrealHeaders = Join-Path $projectRootResolved "external\RE-UE4SS\deps\first\Unreal\include\Unreal"
    if (-not (Test-Path -LiteralPath $unrealHeaders -PathType Container)) {
        $issues.Add("UEPseudo headers are missing; link GitHub to Epic Games and rerun bootstrap_native_dependencies.ps1")
    }
    else {
        $unrealRoot = Join-Path $projectRootResolved "external\RE-UE4SS\deps\first\Unreal"
        $actualUnrealCommit = (git -C $unrealRoot rev-parse HEAD).Trim()
        $expectedUnrealCommit = $lock.ue4ss.submodules.'deps/first/Unreal'.commit
        if ($actualUnrealCommit -ne $expectedUnrealCommit) {
            $issues.Add("UEPseudo commit mismatch: expected $expectedUnrealCommit, got $actualUnrealCommit")
        }
    }

    $patternRoot = Join-Path $projectRootResolved "external\RE-UE4SS\deps\first\patternsleuth"
    if (-not (Test-Path -LiteralPath $patternRoot -PathType Container)) {
        $issues.Add("patternsleuth submodule is missing")
    }
    else {
        $actualPatternCommit = (git -C $patternRoot rev-parse HEAD).Trim()
        $expectedPatternCommit = $lock.ue4ss.submodules.'deps/first/patternsleuth'.commit
        if ($actualPatternCommit -ne $expectedPatternCommit) {
            $issues.Add("patternsleuth commit mismatch: expected $expectedPatternCommit, got $actualPatternCommit")
        }
    }
}

if ($issues.Count -gt 0) {
    $issues | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Output "Native environment matches tools/native-toolchain.lock.json"
