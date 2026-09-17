[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ToolchainRoot,
    [Parameter(Mandatory = $true)]
    [string]$DependencyRoot,
    [Parameter(Mandatory = $true)]
    [string]$RuntimeDll,
    [string]$BuildDirectory = ""
)

$ErrorActionPreference = "Stop"
$expectedUe4ssCommit = "2281fa311e417b1dfddedbcd49972d764fddb244"
$expectedUePseudoCommit = "1cb4c98746f03dfcbf2f0394b59dfec0c9f83a04"
$expectedRuntimeSha256 = "21B691A69A20C0801F465369D4FCBCA7D7444764022FAC2A7E8EDC7709EF92B8"

$nativeRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$toolchainRootResolved = [System.IO.Path]::GetFullPath($ToolchainRoot)
$dependencyRootResolved = [System.IO.Path]::GetFullPath($DependencyRoot)
if ([string]::IsNullOrWhiteSpace($BuildDirectory)) {
    $BuildDirectory = Join-Path $toolchainRootResolved "build-source-bridge"
}
$buildRoot = [System.IO.Path]::GetFullPath($BuildDirectory)

function Assert-Path([string]$Path, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Description was not found: $Path"
    }
}

Assert-Path (Join-Path $toolchainRootResolved ".git") "UE4SS checkout"
Assert-Path $RuntimeDll "UE4SS.dll"
$actualUe4ssCommit = (git -C $toolchainRootResolved rev-parse HEAD).Trim()
if ($actualUe4ssCommit -ne $expectedUe4ssCommit) {
    throw "UE4SS source commit mismatch. Expected $expectedUe4ssCommit, got $actualUe4ssCommit"
}
$uePseudoRoot = Join-Path $toolchainRootResolved "deps\first\Unreal"
Assert-Path (Join-Path $uePseudoRoot ".git") "UEPseudo checkout"
$actualUePseudoCommit = (git -C $uePseudoRoot rev-parse HEAD).Trim()
if ($actualUePseudoCommit -ne $expectedUePseudoCommit) {
    throw "UEPseudo commit mismatch. Expected $expectedUePseudoCommit, got $actualUePseudoCommit"
}
$actualRuntimeSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $RuntimeDll).Hash
if ($actualRuntimeSha256 -ne $expectedRuntimeSha256) {
    throw "UE4SS runtime SHA-256 mismatch. Expected $expectedRuntimeSha256, got $actualRuntimeSha256"
}

$externalRoot = Join-Path $dependencyRootResolved "external"
$dependencyPaths = @{
    fmt = Join-Path $externalRoot "fmt"
    zydis = Join-Path $externalRoot "zydis"
    zycore = Join-Path $externalRoot "zycore"
    imgui = Join-Path $externalRoot "imgui"
    imgui_text_edit = Join-Path $externalRoot "imgui-text-edit"
    icon_font_cpp_headers = Join-Path $externalRoot "icon-font-cpp-headers"
}
$dependencyCommits = @{
    fmt = "40626af88bd7df9a5fb80be7b25ac85b122d6c21"
    zydis = "a2278f1d254e492f6a6b39f6cb5d1f5d515659dc"
    zycore = "0b2432ced0884fd152b471d97ecf0258ff4d859f"
    imgui = "5d4126876bc10396d4c6511853ff10964414c776"
    imgui_text_edit = "6d943aba9f7cef05da80b86dbb0253b63818f95c"
    icon_font_cpp_headers = "210b5a399a64270674560d633638952d1e8d804d"
}
foreach ($name in $dependencyPaths.Keys) {
    Assert-Path (Join-Path $dependencyPaths[$name] ".git") "$name dependency checkout"
    $actual = (git -C $dependencyPaths[$name] rev-parse HEAD).Trim()
    if ($actual -ne $dependencyCommits[$name]) {
        throw "$name dependency commit mismatch. Expected $($dependencyCommits[$name]), got $actual"
    }
}

$enterToolchain = Join-Path $dependencyRootResolved "tools\enter_native_toolchain.ps1"
Assert-Path $enterToolchain "native C++ toolchain launcher"
& $enterToolchain -ProjectRoot $dependencyRootResolved | Out-Host
$toolDirectory = Join-Path $env:VCToolsInstallDir "bin\Hostx64\x64"
$dumpbin = Join-Path $toolDirectory "dumpbin.exe"
$libTool = Join-Path $toolDirectory "lib.exe"
Assert-Path $dumpbin "dumpbin.exe"
Assert-Path $libTool "lib.exe"
Assert-Path (Join-Path $nativeRoot "src\ScriptSourceBridge.cpp") "ScriptSourceBridge.cpp"
Assert-Path (Join-Path $nativeRoot "include\NativeAttackFrame.hpp") "NativeAttackFrame.hpp"
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null

$defPath = Join-Path $buildRoot "UE4SS.def"
$libPath = Join-Path $buildRoot "UE4SS.lib"
$dumpPath = Join-Path $buildRoot "UE4SS.exports.txt"
& $dumpbin /nologo /exports $RuntimeDll | Set-Content -LiteralPath $dumpPath -Encoding ASCII
if ($LASTEXITCODE -ne 0) { throw "dumpbin failed with exit code $LASTEXITCODE" }
$exports = [System.Collections.Generic.List[string]]::new()
foreach ($line in Get-Content -LiteralPath $dumpPath) {
    if ($line -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)\s*$') {
        $exports.Add($Matches[1])
    }
}
if ($exports.Count -lt 100) { throw "Unexpected UE4SS export count: $($exports.Count)" }
$defLines = [System.Collections.Generic.List[string]]::new()
$defLines.Add("LIBRARY UE4SS")
$defLines.Add("EXPORTS")
foreach ($export in $exports) { $defLines.Add("    $export") }
[System.IO.File]::WriteAllLines($defPath, $defLines, [System.Text.UTF8Encoding]::new($false))
& $libTool /nologo "/def:$defPath" /machine:x64 "/out:$libPath"
if ($LASTEXITCODE -ne 0) { throw "lib.exe failed with exit code $LASTEXITCODE" }

$includeDirectories = @(
    (Join-Path $toolchainRootResolved "UE4SS\include"),
    (Join-Path $toolchainRootResolved "UE4SS\generated_include"),
    (Join-Path $uePseudoRoot "include"),
    (Join-Path $uePseudoRoot "include\Unreal"),
    (Join-Path $uePseudoRoot "include\Unreal\Core"),
    (Join-Path $uePseudoRoot "generated_include"),
    (Join-Path $toolchainRootResolved "deps\first\LuaMadeSimple\include"),
    (Join-Path $toolchainRootResolved "deps\first\LuaRaw\include"),
    (Join-Path $toolchainRootResolved "deps\first\String\include"),
    (Join-Path $toolchainRootResolved "deps\first\File\include"),
    (Join-Path $toolchainRootResolved "deps\first\Function\include"),
    (Join-Path $toolchainRootResolved "deps\first\Helpers\include"),
    (Join-Path $toolchainRootResolved "deps\first\Input\include"),
    (Join-Path $toolchainRootResolved "deps\first\IniParser\include"),
    (Join-Path $toolchainRootResolved "deps\first\JSON\include"),
    (Join-Path $toolchainRootResolved "deps\first\MProgram\include"),
    (Join-Path $toolchainRootResolved "deps\first\ParserBase\include"),
    (Join-Path $toolchainRootResolved "deps\first\Profiler\include"),
    (Join-Path $toolchainRootResolved "deps\first\ScopedTimer\include"),
    (Join-Path $toolchainRootResolved "deps\first\SinglePassSigScanner\include"),
    (Join-Path $toolchainRootResolved "deps\first\Constructs\include"),
    (Join-Path $toolchainRootResolved "deps\first\DynamicOutput\include"),
    (Join-Path $toolchainRootResolved "deps\first\ASMHelper\include"),
    (Join-Path $dependencyPaths.fmt "include"),
    (Join-Path $dependencyPaths.zydis "include"),
    (Join-Path $dependencyPaths.zycore "include"),
    $dependencyPaths.imgui,
    $dependencyPaths.imgui_text_edit,
    $dependencyPaths.icon_font_cpp_headers,
    (Join-Path $nativeRoot "include")
)
$includeArguments = foreach ($directory in $includeDirectories) { "/I$directory" }
$sourceArguments = @(
    "/nologo", "/std:c++latest", "/EHsc", "/MD", "/O2", "/W4", "/utf-8",
    "/DUE_BUILD_SHIPPING=1", "/DUE_GAME=1", "/DPLATFORM_WINDOWS=1",
    "/DPLATFORM_MICROSOFT=1", "/DOVERRIDE_PLATFORM_HEADER_NAME=Windows",
    "/DUBT_COMPILED_PLATFORM=Win64", "/D_WIN32_WINNT=0x0A00", "/DWINVER=0x0A00",
    "/DFMT_HEADER_ONLY=1", "/D_UNICODE", "/DUNICODE", "/DWIN32_LEAN_AND_MEAN", "/LD",
    "/Fo:$buildRoot\ScriptSourceBridge.obj",
    (Join-Path $nativeRoot "src\ScriptSourceBridge.cpp")
) + $includeArguments + @(
    "/link", $libPath, "/OUT:$buildRoot\main.dll", "/IMPLIB:$buildRoot\ScriptSourceBridge.lib"
)
& cl.exe @sourceArguments
if ($LASTEXITCODE -ne 0) { throw "ScriptSourceBridge.cpp build failed with exit code $LASTEXITCODE" }

& ml64.exe /nologo /c "/Fo$buildRoot\native_attack_frame_fixture.obj" (Join-Path $nativeRoot "tests\native_attack_frame_fixture.asm")
if ($LASTEXITCODE -ne 0) { throw "native attack frame fixture assembly failed with exit code $LASTEXITCODE" }
$testArguments = @(
    "/nologo", "/std:c++latest", "/EHsc", "/MD", "/O2", "/W4", "/WX", "/utf-8",
    "/D_WIN32_WINNT=0x0A00", "/DWINVER=0x0A00",
    (Join-Path $nativeRoot "tests\native_attack_frame_test.cpp"),
    "$buildRoot\native_attack_frame_fixture.obj",
    "/I$(Join-Path $nativeRoot 'include')", "/Fo:$buildRoot\native_attack_frame_test.obj",
    "/Fe:$buildRoot\native_attack_frame_test.exe"
)
& cl.exe @testArguments
if ($LASTEXITCODE -ne 0) { throw "native_attack_frame_test build failed with exit code $LASTEXITCODE" }
& (Join-Path $buildRoot "native_attack_frame_test.exe")
if ($LASTEXITCODE -ne 0) { throw "native_attack_frame_test failed with exit code $LASTEXITCODE" }

# Exercise the real Lua/C++ boundary that the previous Lua-only API stub missed.
# Keep the production guard/read block verbatim in the test executable.
$bridgeSource = Get-Content -LiteralPath (Join-Path $nativeRoot 'src\ScriptSourceBridge.cpp') -Raw
$argumentStart = $bridgeSource.IndexOf('            if (!lua.is_integer(')
$argumentEnd = $bridgeSource.IndexOf('            const auto count = ++instance->reads;', $argumentStart)
if ($argumentStart -lt 0 -or $argumentEnd -le $argumentStart) {
    throw 'Could not extract the production Lua argument block for its regression test.'
}
$argumentTestRoot = Join-Path $buildRoot 'lua-arguments'
New-Item -ItemType Directory -Path $argumentTestRoot -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $argumentTestRoot 'source_bridge_arguments.inc'),
    $bridgeSource.Substring($argumentStart, $argumentEnd - $argumentStart), [Text.UTF8Encoding]::new($false))
$luaRawRoot = Join-Path $toolchainRootResolved 'deps\first\LuaRaw'
$luaSimpleRoot = Join-Path $toolchainRootResolved 'deps\first\LuaMadeSimple'
$luaTestIncludes = @(
    "/I$(Join-Path $luaSimpleRoot 'include')", "/I$(Join-Path $luaRawRoot 'include')",
    "/I$(Join-Path $luaRawRoot 'src')", "/I$(Join-Path $toolchainRootResolved 'deps\first\Helpers\include')",
    "/I$(Join-Path $toolchainRootResolved 'deps\first\String\include')",
    "/I$(Join-Path $dependencyPaths.fmt 'include')", "/I$argumentTestRoot"
)
$luaTestOptions = @('/nologo', '/EHsc', '/MD', '/O2', '/W4', '/utf-8', '/c',
    '/D_CRT_SECURE_NO_WARNINGS', '/DWIN32_LEAN_AND_MEAN',
    '/DRC_LUA_MADE_SIMPLE_BUILD_STATIC', '/DFMT_HEADER_ONLY=1', "/Fo$argumentTestRoot\") + $luaTestIncludes
& cl.exe @luaTestOptions /std:c++latest (Join-Path $nativeRoot 'tests\source_bridge_lua_args_test.cpp') `
    (Join-Path $luaSimpleRoot 'src\LuaMadeSimple.cpp') (Join-Path $luaSimpleRoot 'src\LuaObject.cpp')
if ($LASTEXITCODE -ne 0) { throw 'Lua source-bridge argument C++ build failed.' }
$luaSources = @(Get-ChildItem -LiteralPath (Join-Path $luaRawRoot 'src') -Filter '*.c' -File |
    Where-Object { $_.Name -notin @('lua.c', 'luac.c') } | ForEach-Object FullName)
& cl.exe @luaTestOptions @luaSources
if ($LASTEXITCODE -ne 0) { throw 'LuaRaw argument-test build failed.' }
$luaObjects = @(Get-ChildItem -LiteralPath $argumentTestRoot -Filter '*.obj' -File | ForEach-Object FullName)
$luaTestExe = Join-Path $argumentTestRoot 'source_bridge_lua_args_test.exe'
& link.exe /NOLOGO @luaObjects "/OUT:$luaTestExe"
if ($LASTEXITCODE -ne 0) { throw 'Lua source-bridge argument test link failed.' }
& $luaTestExe
if ($LASTEXITCODE -ne 0) { throw 'Lua source-bridge argument test failed.' }
Write-Output "Source bridge built: $(Join-Path $buildRoot 'main.dll')"
