param([int]$Seconds = 0, [int]$IntervalMs = 200)
Add-Type -Path "$PSScriptRoot\Maxwell.cs"

$path = [Maxwell]::FindPath()
if (-not $path) { throw "Maxwell 2 dongle vendor interface not found" }
$dev = New-Object Maxwell $path
try {
  if ($Seconds -le 0) {
    $v = $dev.ReadChatMix(); $mixRaw = $dev.LastRaw
    $b = $dev.ReadBattery()
    "value=$v battery=$b% raw=$mixRaw battery_raw=$($dev.LastRaw)"
    return
  }
  $end = (Get-Date).AddSeconds($Seconds); $last = $null
  while ((Get-Date) -lt $end) {
    $v = $dev.ReadChatMix()
    if ($v -ne $last) { "{0:HH:mm:ss.f}  value={1,3}  raw={2}" -f (Get-Date), $v, $dev.LastRaw; $last = $v }
    Start-Sleep -Milliseconds $IntervalMs
  }
} finally { $dev.Dispose() }
