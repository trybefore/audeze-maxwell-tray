# Tray icon for the Audeze Maxwell 2: game/chat mix position and battery level.
#   .\chatmix-tray.ps1              starts detached in the tray (this console is free again)
#   .\chatmix-tray.ps1 -Foreground  stays attached, for debugging
param([switch]$Foreground, [int]$IntervalMs = 250, [int]$LowBattery = 15)

$ErrorActionPreference = 'Stop'
$mutexName = 'Local\MaxwellChatMixTray'
$hostExe = (Get-Process -Id $PID).Path
$launchArgs = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`" -Foreground -IntervalMs $IntervalMs -LowBattery $LowBattery"

if (-not $Foreground) {
  $probe = New-Object System.Threading.Mutex($false, $mutexName)
  $running = -not $probe.WaitOne(0); if (-not $running) { $probe.ReleaseMutex() }; $probe.Dispose()
  if ($running) { 'Already running in the tray.'; return }
  Start-Process $hostExe $launchArgs -WindowStyle Hidden
  'Started in the tray.'; return
}

$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0)) { return }  # another instance owns the tray icon

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Path "$PSScriptRoot\Maxwell.cs"
Add-Type -Namespace MaxwellTray -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);'

# Dial direction: 0 = full game, 20 = full chat (confirmed on the headset).
$GameColor = [System.Drawing.Color]::FromArgb(59, 130, 246)   # blue
$ChatColor = [System.Drawing.Color]::FromArgb(168, 85, 247)   # purple
$Neutral   = [System.Drawing.Color]::FromArgb(156, 163, 175)  # grey, readable on light and dark taskbars
$script:ShowNumber = $false
$script:Warned = $false
$script:Shown = $null  # last MaxwellState drawn; $null forces a redraw

# Saved settings (per user). The low-battery notification is on unless the user turned it off.
$settingsKey = 'HKCU:\Software\audeze-maxwell-tray'
$saved = Get-ItemProperty $settingsKey -Name LowBatteryWarning -ErrorAction SilentlyContinue
$script:WarnEnabled = (-not $saved) -or ($saved.LowBatteryWarning -ne 0)

function Save-WarnSetting([bool]$on) {
  if (-not (Test-Path $settingsKey)) { [void](New-Item $settingsKey -Force) }
  Set-ItemProperty $settingsKey -Name LowBatteryWarning -Value ([int]$on) -Type DWord
}

function Get-BatteryColor([int]$b) {
  if ($b -le $LowBattery) { return [System.Drawing.Color]::FromArgb(239, 68, 68) }
  if ($b -le 30) { return [System.Drawing.Color]::FromArgb(245, 158, 11) }
  return [System.Drawing.Color]::FromArgb(34, 197, 94)
}

function Get-MixText([int]$mix) {
  if ($mix -eq 10) { return 'centre' }
  if ($mix -gt 10) { return "chat +$($mix - 10)" }
  return "game +$(10 - $mix)"
}

# Top: mix bar (game part left, chat part right, notches mark centre). Bottom: battery strip.
function New-TrayIcon([int]$mix, [int]$batt) {
  $s = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
  $u = $s / 16.0
  $bmp = New-Object System.Drawing.Bitmap $s, $s
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  $brushes = @()
  try {
    $top = 1 * $u; $barH = 9 * $u
    if ($mix -lt 0) {
      $b = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(170, $Neutral)); $brushes += $b
      $g.FillRectangle($b, 0, $top, $s, $barH)
    } elseif ($script:ShowNumber) {
      $bg = if ($mix -lt 10) { $GameColor } elseif ($mix -gt 10) { $ChatColor } else { [System.Drawing.Color]::FromArgb(75, 85, 99) }
      $b = New-Object System.Drawing.SolidBrush $bg; $brushes += $b
      $g.FillRectangle($b, 0, 0, $s, 11 * $u)
      $font = New-Object System.Drawing.Font('Segoe UI', [single](10 * $u), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
      $fmt = New-Object System.Drawing.StringFormat
      $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
      $g.DrawString("$mix", $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(-2, 0, ($s + 4), (11 * $u + 1))), $fmt)
      $font.Dispose(); $fmt.Dispose()
    } else {
      $gameW = [single]($s * (20 - $mix) / 20.0)
      $gb = New-Object System.Drawing.SolidBrush $GameColor; $cb = New-Object System.Drawing.SolidBrush $ChatColor
      $nb = New-Object System.Drawing.SolidBrush $Neutral; $brushes += $gb, $cb, $nb
      $g.FillRectangle($gb, 0, $top, $gameW, $barH)
      $g.FillRectangle($cb, $gameW, $top, ($s - $gameW), $barH)
      $g.FillRectangle($nb, ($s / 2 - $u / 2), 0, $u, $top)            # centre notch above
      $g.FillRectangle($nb, ($s / 2 - $u / 2), ($top + $barH), $u, $u)  # and below
    }
    $tb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(110, $Neutral)); $brushes += $tb
    $g.FillRectangle($tb, 0, (12 * $u), $s, (4 * $u))
    if ($batt -ge 0) {
      $bb = New-Object System.Drawing.SolidBrush (Get-BatteryColor $batt); $brushes += $bb
      $g.FillRectangle($bb, 0, (12 * $u), [single]([Math]::Max(1, $s * $batt / 100.0)), (4 * $u))
    }
  } finally {
    $brushes | ForEach-Object { $_.Dispose() }
    $g.Dispose()
  }
  $h = $bmp.GetHicon(); $bmp.Dispose()
  [System.Drawing.Icon]::FromHandle($h)
}

function Set-TrayIcon([System.Drawing.Icon]$icon) {
  $old = $tray.Icon
  $tray.Icon = $icon
  if ($old) { [void][MaxwellTray.Native]::DestroyIcon($old.Handle); $old.Dispose() }
}

# --- Start with Windows: a shortcut in the user's Startup folder
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Maxwell chat mix.lnk'
function Set-Autostart([bool]$on) {
  if (-not $on) { Remove-Item $shortcutPath -ErrorAction SilentlyContinue; return }
  $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
  # Windows PowerShell has a stable path; a Store-installed pwsh path changes with each update.
  $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $lnk.Arguments = $launchArgs
  $lnk.WorkingDirectory = $PSScriptRoot
  $lnk.WindowStyle = 7  # minimised, so the console does not flash up
  $lnk.Description = 'Audeze Maxwell chat mix and battery tray icon'
  $lnk.Save()
}

# --- UI
$poller = New-Object MaxwellPoller $IntervalMs
$poller.Start()

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = 'Maxwell: starting'
Set-TrayIcon (New-TrayIcon -1 -1)

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$statusItem = $menu.Items.Add('Starting'); $statusItem.Enabled = $false
[void]$menu.Items.Add('-')
$numberItem = $menu.Items.Add('Show mix as number')
$numberItem.add_Click({ $script:ShowNumber = -not $script:ShowNumber; $numberItem.Checked = $script:ShowNumber; $script:Shown = $null })
$warnItem = $menu.Items.Add("Low battery notification ($LowBattery%)")
$warnItem.Checked = $script:WarnEnabled
$warnItem.add_Click({ $script:WarnEnabled = -not $script:WarnEnabled; $warnItem.Checked = $script:WarnEnabled; Save-WarnSetting $script:WarnEnabled })
$batteryItem = $menu.Items.Add('Refresh battery now')
$batteryItem.add_Click({ $poller.RefreshBattery() })
$autoItem = $menu.Items.Add('Start with Windows')
$autoItem.Checked = Test-Path $shortcutPath
$autoItem.add_Click({ Set-Autostart (-not $autoItem.Checked); $autoItem.Checked = Test-Path $shortcutPath })
[void]$menu.Items.Add('-')
$exitItem = $menu.Items.Add('Exit')
$exitItem.add_Click({ [System.Windows.Forms.Application]::Exit() })
$tray.ContextMenuStrip = $menu
$tray.Visible = $true

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$timer.add_Tick({
  try {
    $state = $poller.State
    if ([object]::ReferenceEquals($state, $script:Shown)) { return }
    $script:Shown = $state
    $mix = $state.ChatMix; $batt = $state.Battery; $status = $state.Status

    Set-TrayIcon (New-TrayIcon $mix $batt)
    if ($mix -ge 0) {
      $line = "Chat mix $mix/20 ($(Get-MixText $mix))"
      $battText = if ($batt -ge 0) { "Battery $batt%" } else { 'Battery: reading...' }
      $tip = "Maxwell`n$line`n$battText"
      $statusItem.Text = "$line, $battText"
    } else {
      $tip = "Maxwell`n$status"
      $statusItem.Text = $status
    }
    $tray.Text = if ($tip.Length -gt 63) { $tip.Substring(0, 63) } else { $tip }  # .NET Framework limit

    if ($script:WarnEnabled -and $batt -ge 0 -and $batt -le $LowBattery -and -not $script:Warned) {
      $tray.ShowBalloonTip(10000, 'Maxwell battery low', "$batt% left", [System.Windows.Forms.ToolTipIcon]::Warning)
      $script:Warned = $true
    } elseif ($batt -gt $LowBattery + 5) { $script:Warned = $false }
  } catch {
    $tray.Text = 'Maxwell: UI error (run with -Foreground)'
    Write-Warning $_
  }
})
$timer.Start()

try {
  [System.Windows.Forms.Application]::Run()
} finally {
  $timer.Stop()
  $poller.Stop()
  $tray.Visible = $false
  $tray.Dispose()
  $mutex.ReleaseMutex(); $mutex.Dispose()
}
