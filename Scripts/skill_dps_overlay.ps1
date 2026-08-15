param(
    [Parameter(Mandatory = $true)]
    [string]$StatePath,
    [string]$CommandPath = "",
    [string]$HeartbeatPath = "",
    [string]$LogPath = "",
    [switch]$ValidationMode,
    [string]$ValidationUpdateStatePath = "",
    [string]$ValidationScreenshotPath
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
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool ShowWindow(IntPtr hWnd, int command);
}
"@

if ([string]::IsNullOrWhiteSpace($CommandPath)) {
    $CommandPath = [IO.Path]::Combine([IO.Path]::GetDirectoryName($StatePath), "skill_dps_hud_command.txt")
}
if ([string]::IsNullOrWhiteSpace($HeartbeatPath)) {
    $HeartbeatPath = [IO.Path]::Combine([IO.Path]::GetDirectoryName($StatePath), "skill_dps_hud_heartbeat.txt")
}
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = [IO.Path]::Combine([IO.Path]::GetDirectoryName($StatePath), "skill_dps_hud_overlay.log")
}

function Write-HudLog([string]$message) {
    if ($ValidationMode -or [string]::IsNullOrWhiteSpace($LogPath)) { return }
    try {
        $line = "{0:O} pid={1} {2}`r`n" -f [DateTimeOffset]::Now, $PID, $message
        [IO.File]::AppendAllText($LogPath, $line, [Text.UTF8Encoding]::new($false))
    } catch {
        # Logging must never take down the overlay.
    }
}

function Write-HudHeartbeat {
    if ($ValidationMode -or [string]::IsNullOrWhiteSpace($HeartbeatPath)) { return }
    $temporaryPath = $HeartbeatPath + "." + $PID + ".tmp"
    try {
        $content = "pid={0}`nepoch={1}`nstate=running`n" -f $PID, [DateTimeOffset]::Now.ToUnixTimeSeconds()
        [IO.File]::WriteAllText($temporaryPath, $content, [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($HeartbeatPath)) { [IO.File]::Delete($HeartbeatPath) }
        [IO.File]::Move($temporaryPath, $HeartbeatPath)
    } catch {
        try { if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) } } catch {}
    }
}

function Remove-OwnedHudHeartbeat {
    if ($ValidationMode -or -not [IO.File]::Exists($HeartbeatPath)) { return }
    try {
        $content = [IO.File]::ReadAllText($HeartbeatPath, [Text.UTF8Encoding]::new($false))
        if ($content -match "(?m)^pid=$PID$") { [IO.File]::Delete($HeartbeatPath) }
    } catch {}
}

trap {
    if ($ValidationMode) { Write-Error $_.Exception.ToString() }
    Write-HudLog ("fatal startup exception: " + $_.Exception.ToString())
    Remove-OwnedHudHeartbeat
    exit 1
}

function New-HudBrush([string]$color) {
    return [Windows.Media.BrushConverter]::new().ConvertFromString($color)
}

function Get-HudSkillFillColor([pscustomobject]$row) {
    if ($row.Unresolved) { return "#735F4811" }
    if ([string]$row.Category -eq "basic") { return "#5E456B78" }
    switch ([int]$row.Rank) {
        1 { return "#8A1AC7E8" }
        2 { return "#7015A5C4" }
        3 { return "#58127F9B" }
        default { return "#46105F78" }
    }
}

function Get-HudSkillRankColor([pscustomobject]$row) {
    if ($row.Unresolved) { return "#FFE0B96D" }
    if ([string]$row.Category -eq "basic") { return "#FF91AAB2" }
    switch ([int]$row.Rank) {
        1 { return "#FF8BEAFF" }
        2 { return "#FF65D3EC" }
        3 { return "#FF48AFC9" }
        default { return "#FF6EAEC0" }
    }
}

function ConvertFrom-HudField([string]$value) {
    if ($null -eq $value) { return "" }
    return $value.Replace("%0A", "`n").Replace("%0D", "`r").Replace("%09", "`t").Replace("%25", "%")
}

function ConvertTo-HudNumber([string]$value) {
    $number = 0.0
    if ([double]::TryParse($value, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $number
    }
    return 0.0
}

function Format-HudInteger([double]$value) {
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:N0}", [Math]::Round($value))
}

function Format-HudDecimal([double]$value) {
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:0.0}", $value)
}

function Format-HudDuration([double]$seconds) {
    $total = [Math]::Max(0, [Math]::Floor($seconds))
    $minutes = [Math]::Floor($total / 60)
    $remainder = $total % 60
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:00}:{1:00}", $minutes, $remainder)
}

function New-HudText([string]$content, [double]$size, [string]$color, [Windows.FontWeight]$weight) {
    $block = [Windows.Controls.TextBlock]::new()
    $block.Text = $content
    $block.FontFamily = [Windows.Media.FontFamily]::new("Microsoft JhengHei UI, Segoe UI")
    $block.FontSize = $size
    $block.FontWeight = $weight
    $block.Foreground = New-HudBrush $color
    $block.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
    return $block
}

function Send-NextHudCommand {
    if ($ValidationMode) { return }
    if ($null -eq $script:pendingCommand -and $script:commandQueue.Count -gt 0) {
        $script:pendingCommand = $script:commandQueue.Dequeue()
    }
    if ($null -eq $script:pendingCommand -or [IO.File]::Exists($CommandPath)) { return }
    $temporaryPath = $CommandPath + "." + $PID + ".tmp"
    try {
        $line = $script:pendingCommand.Id + "`t" + $script:pendingCommand.Payload + "`n"
        [IO.File]::WriteAllText($temporaryPath, $line, [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($CommandPath)) {
            [IO.File]::Delete($temporaryPath)
            return
        }
        [IO.File]::Move($temporaryPath, $CommandPath)
        $script:pendingCommand.SentAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    } catch {
        Write-HudLog ("command send deferred: " + $_.Exception.Message)
        try { if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) } } catch {}
    }
}

function Write-HudCommand([string]$command) {
    if ($ValidationMode) { return }
    $script:commandSerial++
    $id = "cmd-{0}-{1}-{2}" -f $PID, [DateTimeOffset]::Now.ToUnixTimeMilliseconds(), $script:commandSerial
    $script:commandQueue.Enqueue([pscustomobject]@{ Id = $id; Payload = $command; SentAt = [long]0 })
    Send-NextHudCommand
}

function Pump-HudCommandQueue {
    if ($null -ne $script:pendingCommand -and -not [IO.File]::Exists($CommandPath)) {
        $age = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() - [long]$script:pendingCommand.SentAt
        if ($script:pendingCommand.SentAt -le 0 -or $age -ge 2000) {
            Send-NextHudCommand
        }
    } elseif ($null -eq $script:pendingCommand) {
        Send-NextHudCommand
    }
}

function New-HudButton([string]$content, [double]$width = 34, [string]$background = "#D51A3440") {
    $button = [Windows.Controls.Button]::new()
    $button.Content = $content
    $button.Width = $width
    $button.Height = 30
    $button.Margin = [Windows.Thickness]::new(3, 0, 3, 0)
    $button.Padding = [Windows.Thickness]::new(5, 0, 5, 1)
    $button.Background = New-HudBrush $background
    $button.Foreground = New-HudBrush "#FFF3FBFD"
    $button.BorderBrush = New-HudBrush "#7058C7DE"
    $button.BorderThickness = [Windows.Thickness]::new(1)
    $button.FontFamily = [Windows.Media.FontFamily]::new("Microsoft JhengHei UI, Segoe UI")
    $button.FontSize = 13
    $button.Cursor = [Windows.Input.Cursors]::Hand
    return $button
}

$sha256 = [Security.Cryptography.SHA256]::Create()
$pathHash = [BitConverter]::ToString(
    $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($StatePath.ToLowerInvariant()))
).Replace("-", "").Substring(0, 16)
$sha256.Dispose()
$mutexName = "Local\PalSkillDPSAnalyzerHUD_" + $pathHash
$createdNew = $false
$mutex = [Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    Write-HudLog "duplicate overlay launch ignored; active instance owns the HUD mutex"
    $mutex.Dispose()
    exit 0
}
Write-HudLog "overlay starting"

$window = [Windows.Window]::new()
$window.Title = "Pal Skill DPS Analyzer"
$window.WindowStyle = [Windows.WindowStyle]::None
$window.ResizeMode = [Windows.ResizeMode]::NoResize
$window.AllowsTransparency = $true
$window.Background = [Windows.Media.Brushes]::Transparent
$window.Topmost = $true
$window.ShowInTaskbar = $false
$window.SizeToContent = [Windows.SizeToContent]::Manual
$window.ShowActivated = $false

$border = [Windows.Controls.Border]::new()
$border.Background = New-HudBrush "#EB08151E"
$border.BorderBrush = New-HudBrush "#8C4FCDE4"
$border.BorderThickness = [Windows.Thickness]::new(1)
$border.CornerRadius = [Windows.CornerRadius]::new(9)
$border.ClipToBounds = $true
$border.Effect = [Windows.Media.Effects.DropShadowEffect]@{
    BlurRadius = 16
    ShadowDepth = 2
    Opacity = 0.68
    Color = [Windows.Media.Color]::FromRgb(0, 0, 0)
}

$contentHost = [Windows.Controls.Grid]::new()
$contentHost.Focusable = $true
$border.Child = $contentHost
$window.Content = $border

$lastSequence = -1
$lastAnchor = "left-center"
$lastScale = 0.85
$shouldBeVisible = $false
$missingGameChecks = 0
$timerTicks = 0
$gameIsRunning = $true
$lastRenderedView = "none"
$lastRenderedRows = 0
$lastSettingsOpen = $false
$lastHeartbeatAt = [long]0

# Meter UI is built once and updated in place. The old code cleared the whole
# content tree on every data update and re-positioned the window each time,
# which made the HUD jump between anchors while damage numbers were ticking.
$meterUi = $null          # { Scale, Detail, HeaderSource, HeaderContext, HeaderDamage, HeaderDps, RowHost, Rows, SourceHeaders, WaitingText }
$meterRebuilds = 0
$lastPositionAnchor = $null
$lastWorkAreaKey = ""
$lastPositionWidth = 0.0
$positionMoves = 0
$lastMeterHeight = 0
$lastTopmostRefreshAt = [long]0
$expiresAt = 0
$windowHandle = [IntPtr]::Zero
$settingsKeys = @()
$settingsSelectedIndex = 0
$settingsSelectedTab = 0
$settingsTabs = $null
$settingsScrollOffset = 0.0
$resultsScrollOffset = 0.0
$commandQueue = [Collections.Generic.Queue[object]]::new()
$pendingCommand = $null
$commandSerial = 0
$interactionMode = $null

function Test-PalworldForeground {
    $handle = [PalSkillDpsWindowNative]::GetForegroundWindow()
    if ($handle -eq [IntPtr]::Zero) { return $false }
    [uint32]$processId = 0
    [void][PalSkillDpsWindowNative]::GetWindowThreadProcessId($handle, [ref]$processId)
    if ($processId -eq 0) { return $false }
    try {
        if ($script:lastSettingsOpen -and [int]$processId -eq $PID) { return $true }
        $name = [Diagnostics.Process]::GetProcessById([int]$processId).ProcessName
        return $name -in @("Palworld-Win64-Shipping", "Palworld")
    } catch {
        return $false
    }
}

function Set-HudInteractionMode([bool]$settingsOpen) {
    if ($script:windowHandle -eq [IntPtr]::Zero) { return }
    if ($null -ne $script:interactionMode) { return }
    $style = [PalSkillDpsWindowNative]::GetWindowLong($script:windowHandle, -20)
    $style = $style -bor 0x00000080
    # External HUD is permanently display-only. Interactive settings are
    # allowed only after a native Palworld CommonUI page owns input/focus.
    $style = $style -bor 0x00000020 -bor 0x08000000
    $border.Background = New-HudBrush "#D407141D"
    [void][PalSkillDpsWindowNative]::SetWindowLong($script:windowHandle, -20, $style)
    # Recalculate the cached display-only extended style immediately.
    $frameFlags = [uint32](0x0001 -bor 0x0002 -bor 0x0004 -bor 0x0010 -bor 0x0020)
    [void][PalSkillDpsWindowNative]::SetWindowPos(
        $script:windowHandle,
        [IntPtr]::Zero,
        0, 0, 0, 0,
        $frameFlags
    )
    $script:interactionMode = $false
}

function Assert-HudWindow([bool]$interactive, [bool]$requestFocus = $false) {
    if ($script:windowHandle -eq [IntPtr]::Zero) { return }
    try {
        [void][PalSkillDpsWindowNative]::ShowWindow($script:windowHandle, 5)
        # Keep the display-only overlay topmost without ever activating it.
        # Cross-process focus control caused the recorded flashing and leaked
        # clicks into Palworld, so no focus API is used on this path.
        $flags = [uint32](0x0001 -bor 0x0002 -bor 0x0010)
        [void][PalSkillDpsWindowNative]::SetWindowPos(
            $script:windowHandle,
            [IntPtr](-1),
            0, 0, 0, 0,
            $flags
        )
    } catch {
        Write-HudLog ("window recovery failed: " + $_.Exception.Message)
    }
}

function Set-HudPosition([string]$anchor) {
    if ($anchor -notin @("left-center", "right-center", "top-left", "top-right", "center")) {
        $anchor = "left-center"
    }
    $area = [System.Windows.SystemParameters]::WorkArea
    $workAreaKey = "{0},{1},{2},{3}" -f $area.Left, $area.Top, $area.Width, $area.Height
    $positionWidth = [double]$window.Width
    if ($script:lastPositionAnchor -eq $anchor -and
        $script:lastWorkAreaKey -eq $workAreaKey -and
        [Math]::Abs($script:lastPositionWidth - $positionWidth) -le 0.5) {
        return
    }
    $margin = 24
    $newLeft = 0
    $newTop = 0
    if ($script:lastSettingsOpen -or $anchor -eq "center") {
        $newLeft = [Math]::Round($area.Left + [Math]::Max(0, ($area.Width - $window.Width) / 2))
        $newTop = [Math]::Round($area.Top + [Math]::Max(0, ($area.Height - $window.Height) / 2))
    } else {
        if ($anchor -in @("top-left", "left-center")) {
            $newLeft = $area.Left + $margin
        } else {
            $newLeft = [Math]::Round($area.Right - $window.Width - $margin)
        }
        if ($anchor -in @("left-center", "right-center")) {
            $newTop = $area.Top + [Math]::Max(92, [Math]::Min(160, $area.Height * 0.15))
        } else {
            $newTop = $area.Top + 72
        }
    }
    # The window position is pinned once per anchor/work-area/width change.
    # Assigning the same Left/Top on every 200 ms tick (and after every data
    # update) re-triggers WPF layout and was the source of the left/right
    # alternation while damage numbers ticked. Only move when the target
    # actually differs from the current window rect.
    if ([Math]::Abs($newLeft - $window.Left) -le 0.5 -and
        [Math]::Abs($newTop - $window.Top) -le 0.5) {
        return
    }
    # Position-change trace: the last live regression (HUD-POS-011) showed the
    # meter alternating sides without any second writer in the logs. Record the
    # anchor, requested rect and actual window rect on every real move so the
    # next on-device run can identify the source instead of guessing.
    if (-not $ValidationMode) {
        Write-HudLog ("position-move seq={0} anchor={1} left={2} top={3} width={4} height={5} actual_left={6} actual_top={7} actual_width={8} actual_height={9}" -f
            $script:lastSequence, $anchor,
            [Math]::Round($newLeft), [Math]::Round($newTop),
            [Math]::Round($window.Width), [Math]::Round($window.Height),
            [Math]::Round($window.Left), [Math]::Round($window.Top),
            [Math]::Round($window.ActualWidth), [Math]::Round($window.ActualHeight))
    }
    $window.Left = $newLeft
    $window.Top = $newTop
    $script:lastPositionAnchor = $anchor
    $script:lastWorkAreaKey = $workAreaKey
    $script:lastPositionWidth = $positionWidth
    $script:positionMoves++
}

function Show-HudText([string]$content, [double]$scale) {
    $script:lastRenderedView = "text"
    $script:lastRenderedRows = 0
    $script:settingsTabs = $null
    $script:meterUi = $null
    $contentHost.Children.Clear()
    $border.Width = [double]::NaN
    $border.Height = [double]::NaN
    $border.MinHeight = 0
    $border.MaxHeight = [double]::PositiveInfinity
    $window.Width = 420 * $scale
    $window.Height = 220 * $scale
    $border.Padding = [Windows.Thickness]::new(16 * $scale, 12 * $scale, 16 * $scale, 12 * $scale)
    $text = New-HudText $content (14 * $scale) "#FFF4FBFD" ([Windows.FontWeights]::Normal)
    $text.TextWrapping = [Windows.TextWrapping]::NoWrap
    $text.LineHeight = 20 * $scale
    [void]$contentHost.Children.Add($text)
}

function New-HudSkillRow([pscustomobject]$row, [double]$maximumDamage, [double]$scale, [bool]$fullDetail, [hashtable]$sink, [string]$damageLabel) {
    if ($null -eq $sink) { $sink = @{} }
    $rowBorder = [Windows.Controls.Border]::new()
    $rowBorder.BorderBrush = New-HudBrush "#20FFFFFF"
    $rowBorder.BorderThickness = [Windows.Thickness]::new(0, 0, 0, 1)
    $rowBorder.MinHeight = 46 * $scale

    $layer = [Windows.Controls.Grid]::new()
    $fill = [Windows.Controls.Border]::new()
    $fill.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
    $ratio = if ($maximumDamage -gt 0) { [Math]::Max(0, [Math]::Min(1, $row.Damage / $maximumDamage)) } else { 0 }
    $fill.Width = 420 * $scale * $ratio
    $fill.Background = New-HudBrush (Get-HudSkillFillColor $row)
    [void]$layer.Children.Add($fill)

    $vertical = [Windows.Controls.StackPanel]::new()
    $primary = [Windows.Controls.Grid]::new()
    $primary.MinHeight = 46 * $scale
    $primary.Margin = [Windows.Thickness]::new(8 * $scale, 0, 10 * $scale, 0)
    [void]$primary.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]@{ Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })
    [void]$primary.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]@{ Width = [Windows.GridLength]::new(150 * $scale) })

    $nameGroup = [Windows.Controls.StackPanel]::new()
    $nameGroup.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $name = New-HudText $row.Name (13 * $scale) "#FFF3FBFD" ([Windows.FontWeights]::Medium)
    $nameGroup.Children.Add($name) | Out-Null
    $subline = "{0} DPS  ·  {1}%" -f (Format-HudDecimal $row.Dps), (Format-HudDecimal $row.Share)
    $sub = New-HudText $subline (9.5 * $scale) "#FF9ABBC3" ([Windows.FontWeights]::Normal)
    $sub.Margin = [Windows.Thickness]::new(0, 1 * $scale, 0, 0)
    $nameGroup.Children.Add($sub) | Out-Null
    [Windows.Controls.Grid]::SetColumn($nameGroup, 0)
    [void]$primary.Children.Add($nameGroup)

    $damage = New-HudText ($damageLabel + " " + (Format-HudInteger $row.Damage)) (13.5 * $scale) "#FFFFFFFF" ([Windows.FontWeights]::SemiBold)
    $damage.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
    $damage.VerticalAlignment = [Windows.VerticalAlignment]::Center
    [Windows.Controls.Grid]::SetColumn($damage, 1)
    [void]$primary.Children.Add($damage)
    [void]$vertical.Children.Add($primary)

    [void]$layer.Children.Add($vertical)
    $rowBorder.Child = $layer
    $sink.Name = $name
    $sink.RankValue = [int]$row.Rank
    $sink.Sub = $sub
    $sink.Damage = $damage
    $sink.Fill = $fill
    $sink.Row = $rowBorder
    return $rowBorder
}

function Update-HudSkillRow([hashtable]$cached, [pscustomobject]$row, [double]$maximumDamage, [double]$scale, [bool]$fullDetail, [string]$damageLabel) {
    # In-place update: only the text and the bar width change. The visual tree
    # stays the same, so WPF does not re-measure/layout the whole meter.
    $cached.Name.Text = [string]$row.Name
    $cached.RankValue = [int]$row.Rank
    $cached.Sub.Text = "{0} DPS  ·  {1}%" -f (Format-HudDecimal $row.Dps), (Format-HudDecimal $row.Share)
    $cached.Damage.Text = $damageLabel + " " + (Format-HudInteger $row.Damage)
    $ratio = if ($maximumDamage -gt 0) { [Math]::Max(0, [Math]::Min(1, $row.Damage / $maximumDamage)) } else { 0 }
    $cached.Fill.Width = 420 * $scale * $ratio
    $cached.Fill.Background = New-HudBrush (Get-HudSkillFillColor $row)
}

function Add-HudTextBlocks([Windows.DependencyObject]$root, [Collections.Generic.List[object]]$sink) {
    if ($null -eq $root) { return }
    if ($root -is [Windows.Controls.TextBlock]) {
        [void]$sink.Add($root)
    }
    $childCount = [Windows.Media.VisualTreeHelper]::GetChildrenCount($root)
    for ($index = 0; $index -lt $childCount; $index++) {
        Add-HudTextBlocks ([Windows.Media.VisualTreeHelper]::GetChild($root, $index)) $sink
    }
}

function New-HudDetailRow([pscustomobject]$row, [double]$maximumDamage, [string]$damageLabel) {
    $rowBorder = [Windows.Controls.Border]::new()
    $rowBorder.BorderBrush = New-HudBrush "#3058C7DE"
    $rowBorder.BorderThickness = [Windows.Thickness]::new(1)
    $rowBorder.CornerRadius = [Windows.CornerRadius]::new(5)
    $rowBorder.Margin = [Windows.Thickness]::new(2, 3, 2, 5)

    $layer = [Windows.Controls.Grid]::new()
    $fill = [Windows.Controls.Border]::new()
    $fill.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
    $ratio = if ($maximumDamage -gt 0) { [Math]::Max(0, [Math]::Min(1, $row.Damage / $maximumDamage)) } else { 0 }
    $fill.Width = 560 * $ratio
    $fill.Background = New-HudBrush (Get-HudSkillFillColor $row)
    [void]$layer.Children.Add($fill)

    $content = [Windows.Controls.StackPanel]::new()
    $content.Margin = [Windows.Thickness]::new(10, 7, 10, 8)
    $header = [Windows.Controls.Grid]::new()
    [void]$header.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]@{ Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })
    [void]$header.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]@{ Width = [Windows.GridLength]::Auto })
    $name = New-HudText ("{0}. {1}" -f $row.Rank, $row.Name) 12.5 "#FFF3FBFD" ([Windows.FontWeights]::SemiBold)
    [void]$header.Children.Add($name)
    $damage = New-HudText ("{0} {1}  ·  {2} DPS  ·  {3}%" -f
        $damageLabel, (Format-HudInteger $row.Damage), (Format-HudDecimal $row.Dps),
        (Format-HudDecimal $row.Share)) 11.5 "#FFFFFFFF" ([Windows.FontWeights]::SemiBold)
    $damage.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
    [Windows.Controls.Grid]::SetColumn($damage, 1)
    [void]$header.Children.Add($damage)
    [void]$content.Children.Add($header)
    foreach ($detailLine in @($row.DetailCasts, $row.DetailHits, $row.DetailRange, $row.DetailLimits)) {
        if (-not [string]::IsNullOrWhiteSpace($detailLine)) {
            $detail = New-HudText ([string]$detailLine) 10.2 "#FFB6CED4" ([Windows.FontWeights]::Normal)
            $detail.Margin = [Windows.Thickness]::new(0, 3, 0, 0)
            [void]$content.Children.Add($detail)
        }
    }
    [void]$layer.Children.Add($content)
    $rowBorder.Child = $layer
    return $rowBorder
}

function Show-HudMeter([hashtable]$values, [string]$body, [double]$scale) {
    $sources = @{}
    $sourceOrder = [Collections.Generic.List[string]]::new()
    $rows = [Collections.Generic.List[object]]::new()
    $waiting = ""
    foreach ($line in ($body -split "\r?\n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $fields = $line.Split([char]9)
        if ($fields[0] -eq "S" -and $fields.Count -ge 6) {
            $source = [pscustomobject]@{
                Index = $fields[1]
                Name = ConvertFrom-HudField $fields[2]
                Damage = ConvertTo-HudNumber $fields[3]
                Dps = ConvertTo-HudNumber $fields[4]
                Hits = [int](ConvertTo-HudNumber $fields[5])
            }
            $sources[$source.Index] = $source
            $sourceOrder.Add($source.Index)
        } elseif ($fields[0] -eq "R" -and $fields.Count -ge 21) {
            $rows.Add([pscustomobject]@{
                SourceIndex = $fields[1]
                Rank = [int](ConvertTo-HudNumber $fields[2])
                Name = ConvertFrom-HudField $fields[3]
                InternalCode = ConvertFrom-HudField $fields[4]
                Damage = ConvertTo-HudNumber $fields[5]
                Dps = ConvertTo-HudNumber $fields[6]
                Share = ConvertTo-HudNumber $fields[7]
                Hits = [int](ConvertTo-HudNumber $fields[8])
                Casts = [int](ConvertTo-HudNumber $fields[9])
                DamagePerCast = ConvertTo-HudNumber $fields[10]
                ActionDuration = ConvertTo-HudNumber $fields[11]
                ActionDps = ConvertTo-HudNumber $fields[12]
                PanelCd = ConvertTo-HudNumber $fields[13]
                ActualInterval = ConvertTo-HudNumber $fields[14]
                ReuseGap = ConvertTo-HudNumber $fields[15]
                LifecycleComplete = [int](ConvertTo-HudNumber $fields[16])
                Unresolved = $fields[17] -eq "1"
                Timing = ConvertFrom-HudField $fields[18]
                Cooldown = ConvertFrom-HudField $fields[19]
                CompactCounts = ConvertFrom-HudField $fields[20]
                HitQuality = if ($fields.Count -ge 22) { ConvertFrom-HudField $fields[21] } else { "" }
                Category = if ($fields.Count -ge 23) { ConvertFrom-HudField $fields[22] } else { "skill" }
            })
        } elseif ($fields[0] -eq "W" -and $fields.Count -ge 2) {
            $waiting = ConvertFrom-HudField $fields[1]
        }
    }

    $detail = [string]$values.detail
    $fullDetail = $false
    $primarySource = ConvertFrom-HudField ([string]$values.primary_source)
    if ([string]::IsNullOrWhiteSpace($primarySource)) {
        $primarySource = ConvertFrom-HudField ([string]$values.title)
    }
    $duration = Format-HudDuration (ConvertTo-HudNumber ([string]$values.duration))
    $contextLine = $duration
    $shortcutHint = ConvertFrom-HudField ([string]$values.shortcut_hint)
    $encounterDps = ConvertTo-HudNumber ([string]$values.encounter_dps)
    $damageLabel = ConvertFrom-HudField ([string]$values.damage_label)
    if ([string]::IsNullOrWhiteSpace($damageLabel)) { $damageLabel = "DMG" }
    $damageLine = $damageLabel + " " + (Format-HudInteger (ConvertTo-HudNumber ([string]$values.total_damage)))
    $dpsLine = (Format-HudDecimal $encounterDps) + " DPS"
    $sourceCount = [int](ConvertTo-HudNumber ([string]$values.source_count))

    # The meter visual tree is built once and updated in place. Rebuilding on
    # every 0.5 s snapshot re-measured the window and was the second half of
    # the left/right alternation: header and rows moved because WPF relaid the
    # whole content on every damage tick.
    $rebuild = $null -eq $script:meterUi -or
        [Math]::Abs([double]$script:meterUi.Scale - [double]$scale) -gt 0.01 -or
        $script:lastRenderedView -ne "meter"

    if ($rebuild) {
        $script:settingsTabs = $null
        $contentHost.Children.Clear()
        $border.Padding = [Windows.Thickness]::new(0)
        $border.Width = 420 * $scale
        $border.Height = [double]::NaN
        $border.MinHeight = 0
        $border.MaxHeight = [double]::PositiveInfinity
        # A fixed outer rectangle removes the two-pass WPF desired-size race that
        # previously alternated the meter between left and right anchors.
        $window.Width = 420 * $scale

        $panel = [Windows.Controls.StackPanel]::new()
        $header = [Windows.Controls.Grid]::new()
        $header.Margin = [Windows.Thickness]::new(12 * $scale, 9 * $scale, 12 * $scale, 8 * $scale)
        [void]$header.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]@{ Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })
        [void]$header.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]@{ Width = [Windows.GridLength]::Auto })

        $left = [Windows.Controls.StackPanel]::new()
        $sourceName = New-HudText $primarySource (13.5 * $scale) "#FFF2FAFC" ([Windows.FontWeights]::Medium)
        [void]$left.Children.Add($sourceName)
        $contextText = New-HudText $contextLine (9.5 * $scale) "#FF93B8C1" ([Windows.FontWeights]::Normal)
        $contextText.Margin = [Windows.Thickness]::new(0, 2 * $scale, 0, 0)
        [void]$left.Children.Add($contextText)
        [Windows.Controls.Grid]::SetColumn($left, 0)
        [void]$header.Children.Add($left)

        $right = [Windows.Controls.StackPanel]::new()
        $right.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
        $damageText = New-HudText $damageLine (16 * $scale) "#FFFFFFFF" ([Windows.FontWeights]::SemiBold)
        $damageText.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
        [void]$right.Children.Add($damageText)
        $dpsText = New-HudText $dpsLine (9.5 * $scale) "#FF9ABBC3" ([Windows.FontWeights]::Normal)
        $dpsText.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
        [void]$right.Children.Add($dpsText)
        [Windows.Controls.Grid]::SetColumn($right, 1)
        [void]$header.Children.Add($right)
        [void]$panel.Children.Add($header)

        $divider = [Windows.Controls.Border]::new()
        $divider.Height = 1
        $divider.Background = New-HudBrush "#3A58C7DE"
        [void]$panel.Children.Add($divider)

        $rowHost = [Windows.Controls.StackPanel]::new()
        [void]$panel.Children.Add($rowHost)

        $shortcutText = New-HudText $shortcutHint (9 * $scale) "#FF789DA6" ([Windows.FontWeights]::Normal)
        $shortcutText.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
        $shortcutText.Margin = [Windows.Thickness]::new(12 * $scale, 5 * $scale, 12 * $scale, 7 * $scale)
        [void]$panel.Children.Add($shortcutText)

        $script:meterUi = @{
            Scale = $scale
            Detail = $detail
            DamageLabel = $damageLabel
            HeaderSource = $sourceName
            HeaderContext = $contextText
            HeaderDamage = $damageText
            HeaderDps = $dpsText
            RowHost = $rowHost
            Rows = @{}
            SourceHeaders = @{}
            WaitingText = $null
            Shortcut = $shortcutText
            LastHeight = 0
        }
        $script:meterRebuilds++
        [void]$contentHost.Children.Add($panel)
        $script:lastRenderedView = "meter"
    } else {
        # In-place header update only; the tree stays identical.
        $script:meterUi.HeaderSource.Text = $primarySource
        $script:meterUi.HeaderContext.Text = $contextLine
        $script:meterUi.HeaderDamage.Text = $damageLine
        $script:meterUi.HeaderDps.Text = $dpsLine
        $script:meterUi.Shortcut.Text = $shortcutHint
        $script:meterUi.DamageLabel = $damageLabel
    }

    # ---- Skill rows: create once, update numbers, add/remove only on change.
    if ($rows.Count -eq 0) {
        if ($null -eq $script:meterUi.WaitingText) {
            $waitingText = New-HudText $waiting (11 * $scale) "#FFACC6CC" ([Windows.FontWeights]::Normal)
            $waitingText.Margin = [Windows.Thickness]::new(14 * $scale, 13 * $scale, 14 * $scale, 14 * $scale)
            $waitingText.TextWrapping = [Windows.TextWrapping]::Wrap
            [void]$script:meterUi.RowHost.Children.Add($waitingText)
            $script:meterUi.WaitingText = $waitingText
            foreach ($key in @($script:meterUi.Rows.Keys)) {
                $script:meterUi.RowHost.Children.Remove($script:meterUi.Rows[$key].Row)
            }
            $script:meterUi.Rows.Clear()
            foreach ($key in @($script:meterUi.SourceHeaders.Keys)) {
                $script:meterUi.RowHost.Children.Remove($script:meterUi.SourceHeaders[$key])
            }
            $script:meterUi.SourceHeaders.Clear()
        } else {
            $script:meterUi.WaitingText.Text = $waiting
        }
    } else {
        if ($null -ne $script:meterUi.WaitingText) {
            $script:meterUi.RowHost.Children.Remove($script:meterUi.WaitingText)
            $script:meterUi.WaitingText = $null
        }
        $maximumDamage = ($rows | Measure-Object -Property Damage -Maximum).Maximum
        $seen = @{}
        $liveSources = @{}
        $lastSourceIndex = $null
        $desiredVisuals = [Collections.Generic.List[object]]::new()
        foreach ($row in $rows) {
            $key = "$($row.SourceIndex)|$($row.InternalCode)"
            $seen[$key] = $true
            $liveSources[$row.SourceIndex] = $true
            if ($sourceCount -gt 1 -and $row.SourceIndex -ne $lastSourceIndex -and $sources.ContainsKey($row.SourceIndex)) {
                $lastSourceIndex = $row.SourceIndex
                if (-not $script:meterUi.SourceHeaders.ContainsKey($row.SourceIndex)) {
                    $sourceHeader = New-HudText $sources[$row.SourceIndex].Name (9.5 * $scale) "#FF8FD8E6" ([Windows.FontWeights]::Medium)
                    $sourceHeader.Margin = [Windows.Thickness]::new(11 * $scale, 5 * $scale, 11 * $scale, 4 * $scale)
                    [void]$script:meterUi.RowHost.Children.Add($sourceHeader)
                    $script:meterUi.SourceHeaders[$row.SourceIndex] = $sourceHeader
                } else {
                    $script:meterUi.SourceHeaders[$row.SourceIndex].Text = $sources[$row.SourceIndex].Name
                }
                [void]$desiredVisuals.Add($script:meterUi.SourceHeaders[$row.SourceIndex])
            }
            if ($script:meterUi.Rows.ContainsKey($key)) {
                Update-HudSkillRow $script:meterUi.Rows[$key] $row $maximumDamage $scale $fullDetail $damageLabel
            } else {
                $sink = @{}
                $rowBorder = New-HudSkillRow $row $maximumDamage $scale $fullDetail $sink $damageLabel
                [void]$script:meterUi.RowHost.Children.Add($rowBorder)
                $script:meterUi.Rows[$key] = $sink
            }
            [void]$desiredVisuals.Add($script:meterUi.Rows[$key].Row)
        }
        foreach ($key in @($script:meterUi.Rows.Keys)) {
            if (-not $seen.ContainsKey($key)) {
                $script:meterUi.RowHost.Children.Remove($script:meterUi.Rows[$key].Row)
                $script:meterUi.Rows.Remove($key)
            }
        }
        foreach ($key in @($script:meterUi.SourceHeaders.Keys)) {
            if (-not $liveSources.ContainsKey($key)) {
                $script:meterUi.RowHost.Children.Remove($script:meterUi.SourceHeaders[$key])
                $script:meterUi.SourceHeaders.Remove($key)
            }
        }

        # Lua publishes damage-ranked rows. Reuse every existing row and only
        # move it when its rank actually changes; this preserves the fixed
        # visual tree during ordinary number ticks while keeping the visible
        # order strictly highest damage to lowest damage.
        for ($desiredIndex = 0; $desiredIndex -lt $desiredVisuals.Count; $desiredIndex++) {
            $visual = $desiredVisuals[$desiredIndex]
            $currentIndex = $script:meterUi.RowHost.Children.IndexOf($visual)
            if ($currentIndex -ne $desiredIndex) {
                $script:meterUi.RowHost.Children.Remove($visual)
                $script:meterUi.RowHost.Children.Insert($desiredIndex, $visual)
            }
        }
    }

    # Window height only changes when the row count changes; the fixed meter
    # width plus unchanged height mean no re-layout while damage numbers tick.
    $newHeight = [Math]::Min(540 * $scale,
        [Math]::Max(118 * $scale, (118 + 46 * $rows.Count) * $scale))
    if ([Math]::Abs([double]$script:meterUi.LastHeight - [double]$newHeight) -gt 0.5) {
        $window.Height = $newHeight
        $script:meterUi.LastHeight = $newHeight
    }
    $script:lastRenderedRows = $rows.Count
}

function Show-HudSettings([hashtable]$values, [string]$body) {
    if ($null -ne $script:settingsTabs -and $script:settingsTabs.SelectedIndex -ge 0) {
        $script:settingsSelectedTab = $script:settingsTabs.SelectedIndex
    }
    $border.Padding = [Windows.Thickness]::new(0)
    $border.Width = 640
    # Settings and results are two pages of one workspace. Pin the outer
    # workspace height so an empty results page cannot collapse the window.
    # The cap still adapts to smaller desktops instead of running off-screen.
    $workspaceHeight = [Math]::Min(760.0,
        [Math]::Max(560.0, [System.Windows.SystemParameters]::WorkArea.Height - 80.0))
    $border.Height = $workspaceHeight
    $border.MinHeight = $workspaceHeight
    $border.MaxHeight = $workspaceHeight
    $window.Width = 640
    $window.Height = $workspaceHeight

    $settingRows = [Collections.Generic.List[object]]::new()
    $sources = @{}
    $sourceOrder = [Collections.Generic.List[string]]::new()
    $resultRows = [Collections.Generic.List[object]]::new()
    $damageLabel = ConvertFrom-HudField ([string]$values.damage_label)
    if ([string]::IsNullOrWhiteSpace($damageLabel)) { $damageLabel = "DMG" }
    $settingsTitle = ConvertFrom-HudField ([string]$values.settings_title)
    $resultsTitle = ConvertFrom-HudField ([string]$values.results_title)
    $requestedTitleTab = [Math]::Max(0, [Math]::Min(1,
        [int](ConvertTo-HudNumber ([string]$values.selected_tab))))
    foreach ($line in ($body -split "\r?\n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $fields = $line.Split([char]9)
        if ($fields[0] -in @("P", "B") -and $fields.Count -ge 6) {
            $settingRows.Add([pscustomobject]@{
                Kind = $fields[0]
                Key = ConvertFrom-HudField $fields[1]
                Group = ConvertFrom-HudField $fields[2]
                Label = ConvertFrom-HudField $fields[3]
                Value = ConvertFrom-HudField $fields[4]
                Selected = $fields[5] -eq "1"
            })
        } elseif ($fields[0] -eq "S" -and $fields.Count -ge 6) {
            $source = [pscustomobject]@{
                Index = $fields[1]
                Name = ConvertFrom-HudField $fields[2]
                Damage = ConvertTo-HudNumber $fields[3]
                Dps = ConvertTo-HudNumber $fields[4]
                Hits = [int](ConvertTo-HudNumber $fields[5])
            }
            $sources[$source.Index] = $source
            $sourceOrder.Add($source.Index)
        } elseif ($fields[0] -eq "R" -and $fields.Count -ge 20) {
            $resultRows.Add([pscustomobject]@{
                SourceIndex = $fields[1]
                Rank = [int](ConvertTo-HudNumber $fields[2])
                Name = ConvertFrom-HudField $fields[3]
                InternalCode = ConvertFrom-HudField $fields[4]
                Damage = ConvertTo-HudNumber $fields[5]
                Dps = ConvertTo-HudNumber $fields[6]
                Share = ConvertTo-HudNumber $fields[7]
                Hits = [int](ConvertTo-HudNumber $fields[8])
                Casts = [int](ConvertTo-HudNumber $fields[9])
                DamagePerCast = ConvertTo-HudNumber $fields[10]
                ActionDuration = ConvertTo-HudNumber $fields[11]
                ActionDps = ConvertTo-HudNumber $fields[12]
                PanelCd = ConvertTo-HudNumber $fields[13]
                ActualInterval = ConvertTo-HudNumber $fields[14]
                ReuseGap = ConvertTo-HudNumber $fields[15]
                LifecycleComplete = [int](ConvertTo-HudNumber $fields[16])
                Unresolved = $fields[17] -eq "1"
                Timing = ConvertFrom-HudField $fields[18]
                Cooldown = ConvertFrom-HudField $fields[19]
                Category = if ($fields.Count -ge 21) { ConvertFrom-HudField $fields[20] } else { "skill" }
                HitCasts = if ($fields.Count -ge 22) { [int](ConvertTo-HudNumber $fields[21]) } else { 0 }
                ZeroDamageCasts = if ($fields.Count -ge 23) { [int](ConvertTo-HudNumber $fields[22]) } else { 0 }
                PendingCasts = if ($fields.Count -ge 24) { [int](ConvertTo-HudNumber $fields[23]) } else { 0 }
                PerCastHits = if ($fields.Count -ge 25) { ConvertFrom-HudField $fields[24] } else { "" }
                MinimumHits = if ($fields.Count -ge 26) { ConvertTo-HudNumber $fields[25] } else { 0 }
                AverageHits = if ($fields.Count -ge 27) { ConvertTo-HudNumber $fields[26] } else { 0 }
                MaximumHits = if ($fields.Count -ge 28) { ConvertTo-HudNumber $fields[27] } else { 0 }
                HistoricalMaxHits = if ($fields.Count -ge 29) { ConvertTo-HudNumber $fields[28] } else { 0 }
                FullHitCap = if ($fields.Count -ge 30) { ConvertTo-HudNumber $fields[29] } else { 0 }
                Approximate = $fields.Count -ge 31 -and $fields[30] -eq "1"
                UnassignedHits = if ($fields.Count -ge 32) { [int](ConvertTo-HudNumber $fields[31]) } else { 0 }
                DetailCasts = if ($fields.Count -ge 33) { ConvertFrom-HudField $fields[32] } else { "" }
                DetailHits = if ($fields.Count -ge 34) { ConvertFrom-HudField $fields[33] } else { "" }
                DetailRange = if ($fields.Count -ge 35) { ConvertFrom-HudField $fields[34] } else { "" }
                DetailLimits = if ($fields.Count -ge 36) { ConvertFrom-HudField $fields[35] } else { "" }
            })
        }
    }

    $script:settingsKeys = @($settingRows | ForEach-Object { $_.Key })
    $resetRow = $settingRows | Where-Object { $_.Key -eq "reset" } | Select-Object -First 1
    $script:settingsSelectedIndex = 0
    for ($index = 0; $index -lt $settingRows.Count; $index++) {
        if ($settingRows[$index].Selected) { $script:settingsSelectedIndex = $index; break }
    }

    $root = [Windows.Controls.Grid]::new()
    [void]$root.RowDefinitions.Add([Windows.Controls.RowDefinition]@{ Height = [Windows.GridLength]::Auto })
    [void]$root.RowDefinitions.Add([Windows.Controls.RowDefinition]@{ Height = [Windows.GridLength]::Auto })
    [void]$root.RowDefinitions.Add([Windows.Controls.RowDefinition]@{ Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })
    [void]$root.RowDefinitions.Add([Windows.Controls.RowDefinition]@{ Height = [Windows.GridLength]::Auto })

    $heading = [Windows.Controls.Grid]::new()
    $heading.Margin = [Windows.Thickness]::new(20, 15, 14, 10)
    [void]$heading.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]@{ Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })
    [void]$heading.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]@{ Width = [Windows.GridLength]::Auto })
    $headingText = [Windows.Controls.StackPanel]::new()
    $headingTitle = New-HudText $(if ($requestedTitleTab -eq 1) { $resultsTitle } else { $settingsTitle }) 20 "#FFF4FBFD" ([Windows.FontWeights]::SemiBold)
    [void]$headingText.Children.Add($headingTitle)
    $note = New-HudText (ConvertFrom-HudField ([string]$values.note)) 11 "#FF9CBCC4" ([Windows.FontWeights]::Normal)
    $note.Margin = [Windows.Thickness]::new(0, 4, 0, 0)
    $note.TextWrapping = [Windows.TextWrapping]::Wrap
    [void]$headingText.Children.Add($note)
    [Windows.Controls.Grid]::SetColumn($headingText, 0)
    [void]$heading.Children.Add($headingText)
    $closeButton = New-HudButton (ConvertFrom-HudField ([string]$values.close_label)) 70 "#D5264652"
    $closeButton.Add_Click({ Write-HudCommand "close" })
    [Windows.Controls.Grid]::SetColumn($closeButton, 1)
    [void]$heading.Children.Add($closeButton)
    [Windows.Controls.Grid]::SetRow($heading, 0)
    [void]$root.Children.Add($heading)

    $actionBorder = [Windows.Controls.Border]::new()
    $actionBorder.Margin = [Windows.Thickness]::new(14, 0, 14, 10)
    $actionBorder.Padding = [Windows.Thickness]::new(10, 8, 10, 8)
    $actionBorder.Background = New-HudBrush "#C9162B35"
    $actionBorder.BorderBrush = New-HudBrush "#5058C7DE"
    $actionBorder.BorderThickness = [Windows.Thickness]::new(1)
    $actionBorder.CornerRadius = [Windows.CornerRadius]::new(6)
    $actionGrid = [Windows.Controls.Grid]::new()
    [void]$actionGrid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]@{ Width = [Windows.GridLength]::Auto })
    [void]$actionGrid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]@{ Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })
    if ($null -ne $resetRow) {
        $resetButton = New-HudButton $resetRow.Label 280 "#EF17657A"
        $resetButton.Height = 42
        $resetButton.FontSize = 14
        $resetButton.FontWeight = [Windows.FontWeights]::SemiBold
        $capturedResetButton = $resetButton
        $capturedResetKey = $resetRow.Key
        $resetButton.Add_Click(({
            $capturedResetButton.IsEnabled = $false
            Write-HudCommand ("cycle`t{0}`t1" -f $capturedResetKey)
        }).GetNewClosure())
        [Windows.Controls.Grid]::SetColumn($resetButton, 0)
        [void]$actionGrid.Children.Add($resetButton)
    }
    $resetNotice = ConvertFrom-HudField ([string]$values.reset_notice)
    if (-not [string]::IsNullOrWhiteSpace($resetNotice)) {
        $noticeText = New-HudText $resetNotice 11.5 "#FF8DE4C1" ([Windows.FontWeights]::Medium)
        $noticeText.Margin = [Windows.Thickness]::new(12, 0, 4, 0)
        $noticeText.VerticalAlignment = [Windows.VerticalAlignment]::Center
        $noticeText.TextWrapping = [Windows.TextWrapping]::Wrap
        [Windows.Controls.Grid]::SetColumn($noticeText, 1)
        [void]$actionGrid.Children.Add($noticeText)
    }
    $actionBorder.Child = $actionGrid
    [Windows.Controls.Grid]::SetRow($actionBorder, 1)
    [void]$root.Children.Add($actionBorder)

    $tabs = [Windows.Controls.TabControl]::new()
    $tabs.Margin = [Windows.Thickness]::new(14, 0, 14, 4)
    $tabs.Background = [Windows.Media.Brushes]::Transparent
    $tabs.BorderBrush = New-HudBrush "#4058C7DE"
    $tabs.Foreground = New-HudBrush "#FFF3FBFD"

    $settingsTab = [Windows.Controls.TabItem]::new()
    $settingsTab.Header = ConvertFrom-HudField ([string]$values.settings_tab_label)
    $settingsScroll = [Windows.Controls.ScrollViewer]::new()
    $settingsScroll.VerticalScrollBarVisibility = [Windows.Controls.ScrollBarVisibility]::Auto
    $settingsScroll.MaxHeight = 570
    $settingsPanel = [Windows.Controls.StackPanel]::new()
    $settingsPanel.Margin = [Windows.Thickness]::new(8, 8, 8, 10)
    $lastGroup = ""
    foreach ($row in $settingRows) {
        if ($row.Key -eq "reset") { continue }
        if ($row.Group -ne $lastGroup) {
            $groupText = New-HudText $row.Group 11 "#FF68D4E8" ([Windows.FontWeights]::SemiBold)
            $groupText.Margin = [Windows.Thickness]::new(6, $(if ($lastGroup -eq "") { 0 } else { 12 }), 6, 5)
            [void]$settingsPanel.Children.Add($groupText)
            $lastGroup = $row.Group
        }
        if ($row.Kind -eq "B") {
            $button = New-HudButton $row.Label 260 "#E0296575"
            $button.Height = 38
            $button.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
            $button.Margin = [Windows.Thickness]::new(5, 3, 5, 4)
            $capturedKey = $row.Key
            $button.Add_Click(({ Write-HudCommand ("cycle`t{0}`t1" -f $capturedKey) }).GetNewClosure())
            [void]$settingsPanel.Children.Add($button)
            continue
        }
        $rowBorder = [Windows.Controls.Border]::new()
        $rowBorder.Background = New-HudBrush $(if ($row.Selected) { "#42326E7D" } else { "#160E2933" })
        $rowBorder.CornerRadius = [Windows.CornerRadius]::new(5)
        $rowBorder.Margin = [Windows.Thickness]::new(3, 2, 3, 2)
        $rowGrid = [Windows.Controls.Grid]::new()
        $rowGrid.MinHeight = 42
        $rowGrid.Margin = [Windows.Thickness]::new(10, 0, 7, 0)
        [void]$rowGrid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]@{ Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) })
        [void]$rowGrid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]@{ Width = [Windows.GridLength]::Auto })
        $label = New-HudText $row.Label 12.5 "#FFEAF7F9" ([Windows.FontWeights]::Normal)
        $label.VerticalAlignment = [Windows.VerticalAlignment]::Center
        [Windows.Controls.Grid]::SetColumn($label, 0)
        [void]$rowGrid.Children.Add($label)
        $control = [Windows.Controls.StackPanel]::new()
        $control.Orientation = [Windows.Controls.Orientation]::Horizontal
        $control.VerticalAlignment = [Windows.VerticalAlignment]::Center
        $leftButton = New-HudButton "<"
        $rightButton = New-HudButton ">"
        $capturedKey = $row.Key
        $leftButton.Add_Click(({ Write-HudCommand ("cycle`t{0}`t-1" -f $capturedKey) }).GetNewClosure())
        $rightButton.Add_Click(({ Write-HudCommand ("cycle`t{0}`t1" -f $capturedKey) }).GetNewClosure())
        [void]$control.Children.Add($leftButton)
        $valueBorder = [Windows.Controls.Border]::new()
        $valueBorder.Width = 174
        $valueBorder.Height = 30
        $valueBorder.Background = New-HudBrush "#E3102731"
        $valueBorder.BorderBrush = New-HudBrush "#4058C7DE"
        $valueBorder.BorderThickness = [Windows.Thickness]::new(1)
        $valueBorder.CornerRadius = [Windows.CornerRadius]::new(4)
        $value = New-HudText $row.Value 11.5 "#FFFFFFFF" ([Windows.FontWeights]::Medium)
        $value.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
        $value.VerticalAlignment = [Windows.VerticalAlignment]::Center
        $valueBorder.Child = $value
        [void]$control.Children.Add($valueBorder)
        [void]$control.Children.Add($rightButton)
        [Windows.Controls.Grid]::SetColumn($control, 1)
        [void]$rowGrid.Children.Add($control)
        $rowBorder.Child = $rowGrid
        [void]$settingsPanel.Children.Add($rowBorder)
    }
    $settingsScroll.Content = $settingsPanel
    $settingsScroll.ScrollToVerticalOffset($script:settingsScrollOffset)
    $capturedSettingsScroll = $settingsScroll
    $settingsScroll.Add_ScrollChanged(({
        $script:settingsScrollOffset = $capturedSettingsScroll.VerticalOffset
    }).GetNewClosure())
    $settingsTab.Content = $settingsScroll
    [void]$tabs.Items.Add($settingsTab)

    $resultsTab = [Windows.Controls.TabItem]::new()
    $resultsTab.Header = ConvertFrom-HudField ([string]$values.results_tab_label)
    $resultsScroll = [Windows.Controls.ScrollViewer]::new()
    $resultsScroll.VerticalScrollBarVisibility = [Windows.Controls.ScrollBarVisibility]::Auto
    $resultsScroll.MaxHeight = 570
    $resultsPanel = [Windows.Controls.StackPanel]::new()
    $resultsPanel.Margin = [Windows.Thickness]::new(10, 10, 10, 12)
    if ($resultRows.Count -eq 0) {
        $empty = New-HudText (ConvertFrom-HudField ([string]$values.no_results_label)) 13 "#FFA9C4CA" ([Windows.FontWeights]::Normal)
        $empty.Margin = [Windows.Thickness]::new(10, 24, 10, 24)
        $empty.TextWrapping = [Windows.TextWrapping]::Wrap
        [void]$resultsPanel.Children.Add($empty)
    } else {
        $summary = "{0}  ·  {3} {2}  ·  {1} DPS" -f
            (ConvertFrom-HudField ([string]$values.result_context)),
            (Format-HudDecimal (ConvertTo-HudNumber ([string]$values.result_dps))),
            (Format-HudInteger (ConvertTo-HudNumber ([string]$values.result_damage))),
            $damageLabel
        $summaryText = New-HudText $summary 12 "#FFB9D5DB" ([Windows.FontWeights]::Medium)
        $summaryText.Margin = [Windows.Thickness]::new(6, 2, 6, 10)
        [void]$resultsPanel.Children.Add($summaryText)
        $maximumDamage = ($resultRows | Measure-Object -Property Damage -Maximum).Maximum
        $lastSourceIndex = $null
        foreach ($row in $resultRows) {
            if ($row.SourceIndex -ne $lastSourceIndex -and $sources.ContainsKey($row.SourceIndex)) {
                $source = $sources[$row.SourceIndex]
                $sourceHeader = New-HudText ("{0}   {3} {2}   {1} DPS" -f $source.Name,
                    (Format-HudDecimal $source.Dps), (Format-HudInteger $source.Damage),
                    $damageLabel) 12.5 "#FF74D9EC" ([Windows.FontWeights]::SemiBold)
                $sourceHeader.Margin = [Windows.Thickness]::new(6, $(if ($null -eq $lastSourceIndex) { 2 } else { 13 }), 6, 5)
                [void]$resultsPanel.Children.Add($sourceHeader)
                $lastSourceIndex = $row.SourceIndex
            }
            $skillRow = New-HudDetailRow $row $maximumDamage $damageLabel
            $skillRow.Width = 560
            [void]$resultsPanel.Children.Add($skillRow)
        }
    }
    $resultsScroll.Content = $resultsPanel
    $resultsScroll.ScrollToVerticalOffset($script:resultsScrollOffset)
    $capturedResultsScroll = $resultsScroll
    $resultsScroll.Add_ScrollChanged(({
        $script:resultsScrollOffset = $capturedResultsScroll.VerticalOffset
    }).GetNewClosure())
    $resultsTab.Content = $resultsScroll
    [void]$tabs.Items.Add($resultsTab)
    $requestedTab = [int](ConvertTo-HudNumber ([string]$values.selected_tab))
    $tabs.SelectedIndex = [Math]::Max(0, [Math]::Min(1, $requestedTab))
    $script:settingsSelectedTab = $tabs.SelectedIndex
    $capturedTabs = $tabs
    $capturedHeadingTitle = $headingTitle
    $capturedSettingsTitle = $settingsTitle
    $capturedResultsTitle = $resultsTitle
    $tabs.Add_SelectionChanged(({
        param($sender, $eventArgs)
        # Removing an old TabControl during a state refresh changes its
        # SelectedIndex to -1. Only the currently mounted control may update
        # the remembered tab, otherwise every refresh jumps back to Settings.
        if ([object]::ReferenceEquals($capturedTabs, $script:settingsTabs) -and
            $capturedTabs.SelectedIndex -ge 0) {
            $script:settingsSelectedTab = $capturedTabs.SelectedIndex
            $capturedHeadingTitle.Text = if ($capturedTabs.SelectedIndex -eq 1) {
                $capturedResultsTitle
            } else {
                $capturedSettingsTitle
            }
        }
    }).GetNewClosure())

    [Windows.Controls.Grid]::SetRow($tabs, 2)
    [void]$root.Children.Add($tabs)
    $footer = New-HudText (ConvertFrom-HudField ([string]$values.footer)) 10.5 "#FF8FAFB7" ([Windows.FontWeights]::Normal)
    $footer.Margin = [Windows.Thickness]::new(20, 6, 20, 13)
    [Windows.Controls.Grid]::SetRow($footer, 3)
    [void]$root.Children.Add($footer)

    $script:lastRenderedView = "settings"
    $script:lastRenderedRows = $resultRows.Count
    # Build the replacement tree first, then swap it into the live window in
    # one operation. Clearing at the start exposed a blank frame every refresh.
    $script:settingsTabs = $tabs
    $script:meterUi = $null
    $contentHost.Children.Clear()
    [void]$contentHost.Children.Add($root)
}

function Read-HudState {
    if (-not [IO.File]::Exists($StatePath)) { return }
    try {
        $raw = [IO.File]::ReadAllText($StatePath, [Text.UTF8Encoding]::new($false))
    } catch {
        return
    }
    $parts = $raw -split "(?:\r?\n)---(?:\r?\n)", 2
    if ($parts.Count -ne 2) { return }
    $protocol = ($parts[0] -split "\r?\n", 2)[0]
    if ($protocol -notin @("PAL_SKILL_DPS_HUD_V1", "PAL_SKILL_DPS_HUD_V2")) { return }
    $values = @{}
    foreach ($line in ($parts[0] -split "\r?\n")) {
        if ($line -match "^([^=]+)=(.*)$") { $values[$matches[1]] = $matches[2] }
    }
    $commandAck = ConvertFrom-HudField ([string]$values.command_ack)
    if ($null -ne $script:pendingCommand -and $commandAck -eq $script:pendingCommand.Id) {
        Write-HudLog ("command acknowledged id=" + $commandAck)
        $script:pendingCommand = $null
        Send-NextHudCommand
    }
    $sequence = 0
    [void][int]::TryParse([string]$values.sequence, [ref]$sequence)
    if ($sequence -eq $lastSequence) { return }
    $script:lastSequence = $sequence
    $wasSettingsOpen = $script:lastSettingsOpen
    $script:shouldBeVisible = $values.visible -eq "1"
    $requestedSettings = $values.settings -eq "1" -or $values.view -eq "settings"
    # The settings workspace remains display-only and click-through. Lua owns
    # the F3 page cycle, so the external window never captures game input.
    $script:lastSettingsOpen = $requestedSettings
    $script:lastAnchor = if ($values.anchor -in @("left-center", "right-center", "top-left", "top-right", "center")) {
        [string]$values.anchor
    } else { "left-center" }
    $parsedScale = 0.85
    if (-not [double]::TryParse([string]$values.scale, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedScale)) {
        $parsedScale = 0.85
    }
    $script:lastScale = [Math]::Max(0.7, [Math]::Min(1.4, $parsedScale))
    $parsedExpiry = 0.0
    [void][double]::TryParse([string]$values.expires_at, [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedExpiry)
    $script:expiresAt = $parsedExpiry
    if ($protocol -eq "PAL_SKILL_DPS_HUD_V2" -and $values.view -eq "settings") {
        Show-HudSettings $values $parts[1].TrimEnd("`r", "`n")
    } elseif ($protocol -eq "PAL_SKILL_DPS_HUD_V2" -and $values.view -eq "meter") {
        Show-HudMeter $values $parts[1].TrimEnd("`r", "`n") $script:lastScale
    } else {
        Show-HudText $parts[1].TrimEnd("`r", "`n") $script:lastScale
    }
    # Reading a new damage snapshot may update text and bar widths, but it must
    # never move the window. The previous BeginInvoke closure occasionally
    # received an empty anchor; an empty anchor resolves to the right side, then
    # the 200 ms timer pulled the HUD back left. That was the exact live
    # left/right alternation. Positioning is owned only by the timer below.
}

$window.add_SourceInitialized({
    $helper = [Windows.Interop.WindowInteropHelper]::new($window)
    $script:windowHandle = $helper.Handle
    Set-HudInteractionMode ([bool]$script:lastSettingsOpen)
})

$window.Dispatcher.add_UnhandledException({
    param($sender, $eventArgs)
    Write-HudLog ("dispatcher exception: " + $eventArgs.Exception.ToString())
    $eventArgs.Handled = $true
})

if ($ValidationMode) {
    Read-HudState
    $rankOrdered = "n/a"
    $rankReorderedInPlace = "n/a"
    $rankGradient = "n/a"
    $coreFieldsOnly = "n/a"
    if ($lastRenderedView -eq "meter") {
        $initialRows = @{}
        $initialOrder = [Collections.Generic.List[string]]::new()
        foreach ($key in @($script:meterUi.Rows.Keys)) {
            $initialRows[$key] = $script:meterUi.Rows[$key].Row
        }
        foreach ($visual in $script:meterUi.RowHost.Children) {
            foreach ($key in @($script:meterUi.Rows.Keys)) {
                if ([object]::ReferenceEquals($visual, $script:meterUi.Rows[$key].Row)) {
                    [void]$initialOrder.Add([string]$key)
                    break
                }
            }
        }

        # Feed a changed damage ranking as the next 0.5 s snapshot. Rows must
        # move in place: no tree rebuild and no replacement row objects.
        if (-not [string]::IsNullOrWhiteSpace($ValidationUpdateStatePath)) {
            $StatePath = $ValidationUpdateStatePath
        }
        $script:lastSequence = -1
        Read-HudState

        $finalOrder = [Collections.Generic.List[string]]::new()
        $expectedRank = 1
        $ordered = $true
        foreach ($visual in $script:meterUi.RowHost.Children) {
            foreach ($key in @($script:meterUi.Rows.Keys)) {
                $cached = $script:meterUi.Rows[$key]
                if ([object]::ReferenceEquals($visual, $cached.Row)) {
                    [void]$finalOrder.Add([string]$key)
                    if ([int]$cached.RankValue -ne $expectedRank) { $ordered = $false }
                    $expectedRank++
                    break
                }
            }
        }
        $rankOrdered = if ($ordered -and $finalOrder.Count -eq $script:meterUi.Rows.Count) { "1" } else { "0" }

        $sameObjects = $initialRows.Count -eq $script:meterUi.Rows.Count
        foreach ($key in @($initialRows.Keys)) {
            if (-not $script:meterUi.Rows.ContainsKey($key) -or
                -not [object]::ReferenceEquals($initialRows[$key], $script:meterUi.Rows[$key].Row)) {
                $sameObjects = $false
            }
        }
        $orderChanged = ($initialOrder -join "|") -ne ($finalOrder -join "|")
        $rankReorderedInPlace = if ($sameObjects -and $orderChanged) { "1" } else { "0" }

        $gradientOk = $true
        $skillColors = @{}
        foreach ($key in @($script:meterUi.Rows.Keys)) {
            $cached = $script:meterUi.Rows[$key]
            $rank = [int]$cached.RankValue
            $actual = $cached.Fill.Background.ToString()
            if ($key -like "*|GravityShot") {
                if ($actual -ne "#5E456B78") { $gradientOk = $false }
            } elseif ($rank -ge 1 -and $rank -le 3) {
                $expected = @("", "#8A1AC7E8", "#7015A5C4", "#58127F9B")[$rank]
                if ($actual -ne $expected) { $gradientOk = $false }
                $skillColors[$rank] = $actual
            }
        }
        if ($skillColors.Count -ne 3 -or
            $skillColors[1] -eq $skillColors[2] -or
            $skillColors[2] -eq $skillColors[3] -or
            $skillColors[1] -eq $skillColors[3]) {
            $gradientOk = $false
        }
        $rankGradient = if ($gradientOk) { "1" } else { "0" }

        # The live row has exactly three visible text values: skill name,
        # per-skill DPS/share, and per-skill total damage. Encounter time stays
        # in the header. Cast/Hit diagnostics belong exclusively to F3 page 2.
        $damagePrefix = [string]$script:meterUi.DamageLabel
        if ([string]::IsNullOrWhiteSpace($damagePrefix)) { $damagePrefix = "DMG" }
        $damagePattern = '^' + [regex]::Escape($damagePrefix) + ' '
        $coreOk = $script:meterUi.HeaderContext.Text -match '^\d{2}:\d{2}$'
        foreach ($key in @($script:meterUi.Rows.Keys)) {
            $cached = $script:meterUi.Rows[$key]
            $textBlocks = [Collections.Generic.List[object]]::new()
            Add-HudTextBlocks $cached.Row $textBlocks
            if ($textBlocks.Count -ne 3 -or
                [string]::IsNullOrWhiteSpace($cached.Name.Text) -or
                $cached.Sub.Text -notmatch ' DPS\s+·\s+.*%$' -or
                $cached.Damage.Text -notmatch $damagePattern) {
                $coreOk = $false
            }
        }
        $coreFieldsOnly = if ($coreOk) { "1" } else { "0" }

        # Exercise the same single positioning owner used at runtime. Two data
        # snapshots with the same anchor/work area/width must produce one move.
        Set-HudPosition $script:lastAnchor
        Set-HudPosition $script:lastAnchor
    }
    $tabStable = "n/a"
    if ($lastRenderedView -eq "settings" -and $null -ne $script:settingsTabs) {
        # Validation runs without showing a native window, so WPF does not
        # raise its normal loaded SelectionChanged event. Seed the remembered
        # value exactly as that event would, then exercise a full refresh.
        $script:settingsSelectedTab = 1
        $script:settingsTabs.SelectedIndex = 1
        # Re-read the same document as if Lua published another periodic
        # snapshot. The rebuilt workspace must remain on Current Test.
        $script:lastSequence = -1
        Read-HudState
        if ($null -eq $script:settingsTabs -or
            $script:settingsTabs.SelectedIndex -ne 1 -or
            $script:settingsSelectedTab -ne 1) {
            throw "settings tab returned to the first page during refresh"
        }
        $tabStable = "1"
    }
    $border.Measure([Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $desired = $border.DesiredSize
    if (-not [string]::IsNullOrWhiteSpace($ValidationScreenshotPath)) {
        $pixelWidth = [Math]::Max(1, [int][Math]::Ceiling($desired.Width))
        $pixelHeight = [Math]::Max(1, [int][Math]::Ceiling($desired.Height))
        $border.Arrange([Windows.Rect]::new(0, 0, $desired.Width, $desired.Height))
        $border.UpdateLayout()
        $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(
            $pixelWidth, $pixelHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32
        )
        $bitmap.Render($border)
        $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = [IO.File]::Open($ValidationScreenshotPath, [IO.FileMode]::Create)
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
    }
    Write-Output ("HUD validation view={0} rows={1} desired={2:0.0}x{3:0.0} tab_stable={4} meter_rebuilds={5} position_moves={6} rank_ordered={7} rank_reordered_in_place={8} rank_gradient={9} core_fields_only={10}" -f
        $lastRenderedView, $lastRenderedRows, $desired.Width, $desired.Height, $tabStable,
        $script:meterRebuilds, $script:positionMoves, $rankOrdered, $rankReorderedInPlace, $rankGradient,
        $coreFieldsOnly)
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    exit 0
}

$window.add_PreviewKeyDown({
    param($sender, $eventArgs)
    if (-not $script:lastSettingsOpen) { return }
    if ($eventArgs.Key -in @([Windows.Input.Key]::F3, [Windows.Input.Key]::Escape)) {
        Write-HudCommand "close"
        $eventArgs.Handled = $true
        return
    }
    if ($script:settingsKeys.Count -eq 0) { return }
    if ($eventArgs.Key -eq [Windows.Input.Key]::Up) {
        $script:settingsSelectedIndex = ($script:settingsSelectedIndex - 1 + $script:settingsKeys.Count) % $script:settingsKeys.Count
        Write-HudCommand ("select`t" + $script:settingsKeys[$script:settingsSelectedIndex])
        $eventArgs.Handled = $true
    } elseif ($eventArgs.Key -eq [Windows.Input.Key]::Down) {
        $script:settingsSelectedIndex = ($script:settingsSelectedIndex + 1) % $script:settingsKeys.Count
        Write-HudCommand ("select`t" + $script:settingsKeys[$script:settingsSelectedIndex])
        $eventArgs.Handled = $true
    } elseif ($eventArgs.Key -eq [Windows.Input.Key]::Left) {
        Write-HudCommand ("cycle`t" + $script:settingsKeys[$script:settingsSelectedIndex] + "`t-1")
        $eventArgs.Handled = $true
    } elseif ($eventArgs.Key -in @([Windows.Input.Key]::Right, [Windows.Input.Key]::Enter)) {
        Write-HudCommand ("cycle`t" + $script:settingsKeys[$script:settingsSelectedIndex] + "`t1")
        $eventArgs.Handled = $true
    }
})

$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$timer.add_Tick({
    try {
        Read-HudState
        Pump-HudCommandQueue
        $script:timerTicks++
        if (($script:timerTicks % 5) -eq 0) {
            Write-HudHeartbeat
            $game = Get-Process -Name "Palworld-Win64-Shipping", "Palworld" -ErrorAction SilentlyContinue
            $script:gameIsRunning = $null -ne $game
            if (-not $script:gameIsRunning) {
                $script:missingGameChecks++
                if ($script:missingGameChecks -ge 10) { $window.Close(); return }
            } else {
                $script:missingGameChecks = 0
            }
        }
        $nowEpoch = [DateTimeOffset]::Now.ToUnixTimeSeconds()
        $notExpired = $script:lastSettingsOpen -or $script:expiresAt -le 0 -or $nowEpoch -lt $script:expiresAt
        $show = $script:gameIsRunning -and $script:shouldBeVisible -and $notExpired -and (Test-PalworldForeground)
        if ($show) {
            if (-not $window.IsVisible) { $window.Show() }
            Set-HudPosition $script:lastAnchor
            if (($script:timerTicks % 5) -eq 0) {
                Assert-HudWindow ([bool]$script:lastSettingsOpen) $false
            }
        } elseif ($window.IsVisible) {
            $window.Hide()
        }
    } catch {
        Write-HudLog ("timer exception: " + $_.Exception.ToString())
    }
})

$window.add_Closed({
    $timer.Stop()
    Remove-OwnedHudHeartbeat
    Write-HudLog "overlay closed"
    $window.Dispatcher.BeginInvokeShutdown([Windows.Threading.DispatcherPriority]::Background)
})
$timer.Start()
$lastHeartbeatAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
Write-HudHeartbeat
$window.Show()
$window.Hide()
try {
    [void][Windows.Threading.Dispatcher]::Run()
} catch {
    Write-HudLog ("fatal dispatcher exit: " + $_.Exception.ToString())
} finally {
    Remove-OwnedHudHeartbeat
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
