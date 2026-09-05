$ErrorActionPreference = "Stop"
$overlayPath = Join-Path (Split-Path $PSScriptRoot -Parent) "Scripts\skill_dps_overlay.ps1"
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($overlayPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "overlay parse failed: $parseErrors" }

# Exercise the shipped functions without showing a window or touching Palworld.
foreach ($functionName in @("Test-HudGameRunning", "Read-HudState", "Update-HudRuntime")) {
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    if ($null -eq $definition) { throw "missing runtime function: $functionName" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}
function ConvertFrom-HudField([string]$value) { return $value }
function Show-HudText { $script:renderCalls++ }
function Write-HudLog([string]$message) { $script:logMessages.Add($message) }
function Pump-HudCommandQueue {}
function Write-HudHeartbeat { $script:heartbeatCalls++ }
function Test-PalworldForeground { return $script:foreground }
function Set-HudPosition {}
function Assert-HudWindow { $script:topmostCalls++ }
function Get-Process { throw "runtime tick must not enumerate processes" }

$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("palskilldps-hud-" + [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($temporaryDirectory)
$StatePath = Join-Path $temporaryDirectory "state.txt"
$script:renderCalls = 0
$script:heartbeatCalls = 0
$script:topmostCalls = 0
$script:logMessages = [Collections.Generic.List[string]]::new()
$script:lastSequence = -1
$script:lastStatePath = ""
$script:lastStateWriteTicks = [long]-1
$script:lastStateLength = [long]-1
$script:pendingCommand = $null
$script:lastSettingsOpen = $false
$script:foreground = $true
$script:lastHeartbeatAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$script:gameProcess = [Diagnostics.Process]::GetCurrentProcess()
[void]$script:gameProcess.Handle
$ownerProcess = $script:gameProcess
$exitedProcess = $null
$window = [pscustomobject]@{ IsVisible = $false; Shows = 0; Hides = 0; Closes = 0 }
$window | Add-Member ScriptMethod Show { $this.IsVisible = $true; $this.Shows++ }
$window | Add-Member ScriptMethod Hide { $this.IsVisible = $false; $this.Hides++ }
$window | Add-Member ScriptMethod Close { $this.IsVisible = $false; $this.Closes++ }
$timer = [pscustomobject]@{ Interval = [TimeSpan]::Zero }

function Write-TestState([int]$sequence, [bool]$visible) {
    $visibleValue = if ($visible) { "1" } else { "0" }
    $document = "PAL_SKILL_DPS_HUD_V1`nsequence=$sequence`nvisible=$visibleValue`nanchor=left-center`nscale=0.85`nsettings=0`n---`ntest $sequence`n"
    [IO.File]::WriteAllText($StatePath, $document)
    # Avoid depending on filesystem timestamp resolution or real-time sleeps.
    [IO.File]::SetLastWriteTimeUtc($StatePath, [DateTime]::UtcNow.Date.AddSeconds($sequence))
}

try {
    Write-TestState 1 $true
    Update-HudRuntime
    Assert-True ($script:renderCalls -eq 1 -and $window.Shows -eq 1) "first visible state was not rendered"
    Assert-True ($script:topmostCalls -eq 1 -and $timer.Interval.TotalMilliseconds -eq 200) "visible HUD did not recover once"

    # A cached file must return before reading its sequence or rendering again.
    $script:lastSequence = 99
    Update-HudRuntime
    Assert-True ($script:lastSequence -eq 99 -and $script:renderCalls -eq 1) "unchanged state file was parsed again"
    Assert-True ($script:topmostCalls -eq 1) "ordinary tick repeated the topmost/window operation"

    Write-TestState 2 $false
    Update-HudRuntime
    Assert-True (-not $script:shouldBeVisible -and $window.Hides -eq 1) "hidden state failed to hide the window"
    Assert-True ($script:renderCalls -eq 1) "hidden state rebuilt the visual tree"
    Assert-True ($timer.Interval.TotalMilliseconds -eq 1000) "hidden HUD did not reduce polling"

    $script:lastHeartbeatAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() - 2500
    Update-HudRuntime
    Assert-True ($script:heartbeatCalls -eq 1 -and $window.Closes -eq 0) "hidden live HUD lost its watchdog heartbeat"

    Write-TestState 3 $true
    Update-HudRuntime
    Assert-True ($script:renderCalls -eq 2 -and $window.Shows -eq 2) "new visible state did not wake the HUD"
    Assert-True ($script:topmostCalls -eq 2 -and $timer.Interval.TotalMilliseconds -eq 200) "visible HUD did not restore responsiveness"

    $script:foreground = $false
    Update-HudRuntime
    Assert-True (-not $window.IsVisible -and $timer.Interval.TotalMilliseconds -eq 1000) "Alt-Tab did not suspend the visible meter"
    $script:foreground = $true
    Update-HudRuntime
    Assert-True ($window.Shows -eq 3 -and $script:topmostCalls -eq 3) "returning to the game did not restore the HUD"

    # An atomic remove/rename gap is not a producer shutdown; retry the next tick.
    $savedState = [IO.File]::ReadAllText($StatePath)
    [IO.File]::Delete($StatePath)
    Update-HudRuntime
    Assert-True ($window.Closes -eq 0) "a temporary state-file gap closed the HUD"
    [IO.File]::WriteAllText($StatePath, $savedState)

    # Exercise real process lifetime while another process (this test) remains alive.
    $windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $exitedProcess = Start-Process -FilePath $windowsPowerShell -WindowStyle Hidden -PassThru -ArgumentList @(
        "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Milliseconds 300"
    )
    [void]$exitedProcess.Handle
    Assert-True ($exitedProcess.WaitForExit(10000)) "test owner process did not exit"
    $script:gameProcess = $exitedProcess
    $heartbeatBeforeExit = $script:heartbeatCalls
    $script:lastHeartbeatAt = 0
    Update-HudRuntime
    Assert-True ($window.Closes -eq 1) "HUD survived the exit of its bound process"
    Assert-True ($script:heartbeatCalls -eq $heartbeatBeforeExit) "HUD renewed its heartbeat after its owner exited"
    Assert-True (-not (Test-HudGameRunning)) "HUD rebound to another live process"
    Assert-True ($script:logMessages -contains "bound game exited; overlay closing") "owner-exit reason was not logged"
    Assert-True (-not ($script:logMessages -match "exception")) "runtime tick caught an unexpected error"
    Write-Output "HUD lifecycle tests passed: cached reads, hidden idle, wake, Alt-Tab, atomic file gap, bound-process exit"
} finally {
    if ($null -ne $exitedProcess) {
        if (-not $exitedProcess.HasExited) { $exitedProcess.Kill(); $exitedProcess.WaitForExit() }
        $exitedProcess.Dispose()
    }
    $ownerProcess.Dispose()
    # Only remove the one file and empty temporary directory created by this test.
    if ([IO.File]::Exists($StatePath)) { [IO.File]::Delete($StatePath) }
    [IO.Directory]::Delete($temporaryDirectory, $false)
}
