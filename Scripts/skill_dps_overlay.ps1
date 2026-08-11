param(
    [Parameter(Mandatory = $true)]
    [string]$StatePath
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PalSkillDpsWindowNative {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", SetLastError=true)] public static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll", SetLastError=true)] public static extern int SetWindowLong(IntPtr hWnd, int index, int value);
}
"@

$sha256 = [Security.Cryptography.SHA256]::Create()
$pathHash = [BitConverter]::ToString(
    $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($StatePath.ToLowerInvariant()))
).Replace("-", "").Substring(0, 16)
$sha256.Dispose()
$mutexName = "Local\PalSkillDPSAnalyzerHUD_" + $pathHash
$createdNew = $false
$mutex = [Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

$window = [Windows.Window]::new()
$window.Title = "Pal Skill DPS Analyzer"
$window.WindowStyle = [Windows.WindowStyle]::None
$window.ResizeMode = [Windows.ResizeMode]::NoResize
$window.AllowsTransparency = $true
$window.Background = [Windows.Media.Brushes]::Transparent
$window.Topmost = $true
$window.ShowInTaskbar = $false
$window.SizeToContent = [Windows.SizeToContent]::WidthAndHeight
$window.ShowActivated = $false

$border = [Windows.Controls.Border]::new()
$border.Background = [Windows.Media.BrushConverter]::new().ConvertFromString("#EA0E1B25")
$border.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString("#FF33D5F4")
$border.BorderThickness = [Windows.Thickness]::new(1.25)
$border.CornerRadius = [Windows.CornerRadius]::new(8)
$border.Padding = [Windows.Thickness]::new(16, 12, 16, 12)
$border.Effect = [Windows.Media.Effects.DropShadowEffect]@{
    BlurRadius = 14
    ShadowDepth = 2
    Opacity = 0.72
    Color = [Windows.Media.Color]::FromRgb(0, 0, 0)
}

$text = [Windows.Controls.TextBlock]::new()
$text.FontFamily = [Windows.Media.FontFamily]::new("Microsoft JhengHei UI, Segoe UI")
$text.FontSize = 14
$text.Foreground = [Windows.Media.Brushes]::White
$text.TextWrapping = [Windows.TextWrapping]::NoWrap
$text.LineHeight = 20
$text.Text = "Pal Skill DPS Analyzer`nWaiting for the first Boss damage event..."
$border.Child = $text
$window.Content = $border

$window.add_SourceInitialized({
    $helper = [Windows.Interop.WindowInteropHelper]::new($window)
    $style = [PalSkillDpsWindowNative]::GetWindowLong($helper.Handle, -20)
    $style = $style -bor 0x00000020 -bor 0x08000000 -bor 0x00000080
    [void][PalSkillDpsWindowNative]::SetWindowLong($helper.Handle, -20, $style)
})

$lastSequence = -1
$lastAnchor = "top-right"
$lastScale = 1.0
$shouldBeVisible = $false
$missingGameChecks = 0
$timerTicks = 0
$gameIsRunning = $true

function Test-PalworldForeground {
    $handle = [PalSkillDpsWindowNative]::GetForegroundWindow()
    if ($handle -eq [IntPtr]::Zero) { return $false }
    [uint32]$processId = 0
    [void][PalSkillDpsWindowNative]::GetWindowThreadProcessId($handle, [ref]$processId)
    if ($processId -eq 0) { return $false }
    try {
        $name = [Diagnostics.Process]::GetProcessById([int]$processId).ProcessName
        return $name -in @("Palworld-Win64-Shipping", "Palworld")
    } catch {
        return $false
    }
}

function Set-HudPosition([string]$anchor) {
    $area = [System.Windows.SystemParameters]::WorkArea
    $margin = 24
    if ($anchor -eq "top-left") {
        $window.Left = $area.Left + $margin
    } else {
        $window.Left = $area.Right - $window.ActualWidth - $margin
    }
    $window.Top = $area.Top + 72
}

function Read-HudState {
    if (-not [IO.File]::Exists($StatePath)) { return }
    try {
        $raw = [IO.File]::ReadAllText($StatePath, [Text.UTF8Encoding]::new($false))
    } catch {
        return
    }
    $parts = $raw -split "(?:\r?\n)---(?:\r?\n)", 2
    if ($parts.Count -ne 2 -or -not $parts[0].StartsWith("PAL_SKILL_DPS_HUD_V1")) { return }
    $values = @{}
    foreach ($line in ($parts[0] -split "\r?\n")) {
        if ($line -match "^([^=]+)=(.*)$") { $values[$matches[1]] = $matches[2] }
    }
    $sequence = 0
    [void][int]::TryParse([string]$values.sequence, [ref]$sequence)
    if ($sequence -eq $lastSequence) { return }
    $script:lastSequence = $sequence
    $script:shouldBeVisible = $values.visible -eq "1"
    $script:lastAnchor = if ($values.anchor -eq "top-left") { "top-left" } else { "top-right" }
    $parsedScale = 1.0
    if (-not [double]::TryParse([string]$values.scale, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedScale)) {
        $parsedScale = 1.0
    }
    $script:lastScale = [Math]::Max(0.7, [Math]::Min(1.4, $parsedScale))
    $text.FontSize = 14 * $script:lastScale
    $text.LineHeight = 20 * $script:lastScale
    $text.Text = $parts[1].TrimEnd("`r", "`n")
    $window.Dispatcher.BeginInvoke([Action]{ Set-HudPosition $script:lastAnchor }) | Out-Null
}

$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$timer.add_Tick({
    Read-HudState
    $script:timerTicks++
    if (($script:timerTicks % 5) -eq 0) {
        $game = Get-Process -Name "Palworld-Win64-Shipping", "Palworld" -ErrorAction SilentlyContinue
        $script:gameIsRunning = $null -ne $game
        if (-not $script:gameIsRunning) {
            $script:missingGameChecks++
            if ($script:missingGameChecks -ge 10) { $window.Close(); return }
        } else {
            $script:missingGameChecks = 0
        }
    }
    $show = $script:gameIsRunning -and $script:shouldBeVisible -and (Test-PalworldForeground)
    if ($show) {
        if (-not $window.IsVisible) { $window.Show() }
        Set-HudPosition $script:lastAnchor
    } elseif ($window.IsVisible) {
        $window.Hide()
    }
})

$window.add_Closed({
    $timer.Stop()
    $window.Dispatcher.BeginInvokeShutdown([Windows.Threading.DispatcherPriority]::Background)
})
$timer.Start()
$window.Show()
$window.Hide()
[void][Windows.Threading.Dispatcher]::Run()
$mutex.ReleaseMutex()
$mutex.Dispose()
