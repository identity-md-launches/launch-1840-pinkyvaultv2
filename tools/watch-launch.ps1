# Polls an IMD launch until it is live, parked or failed, then prints its addresses and exits.
param(
  [string]$LaunchId = '6e9ac2a3-b5e4-4e2d-bf78-b61a8e2af6be',
  [int]$EverySec = 60,
  [int]$MaxHours = 6
)
$ProgressPreference = 'SilentlyContinue'
$log = Join-Path $PSScriptRoot '..\requests\launch.watch.log'
$deadline = (Get-Date).AddHours($MaxHours)
$last = ''
$misses = 0
while ((Get-Date) -lt $deadline) {
  try {
    $l = (Invoke-WebRequest -Uri "https://api.imd.fun/launches/$LaunchId" -UseBasicParsing -TimeoutSec 30).Content | ConvertFrom-Json
    $misses = 0
  } catch {
    $misses++
    if ($misses -ge 20) { "gave up: the API did not answer $misses times in a row ($($_.Exception.Message))"; exit 2 }
    Start-Sleep -Seconds $EverySec
    continue
  }
  $line = "launch #$($l.launchNumber) status=$($l.status) parked=$($l.parkedReason) artifacts=$(@($l.artifacts).Count)"
  if ($line -ne $last) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $line" | Tee-Object -FilePath $log -Append
    $last = $line
  }
  if ($l.status -in 'live', 'parked', 'failed', 'cancelled', 'rejected') {
    "ENDED: $line"
    $l.artifacts | ForEach-Object { "  $($_.role) $($_.name) $($_.address) tx $($_.txHash)" }
    exit 0
  }
  Start-Sleep -Seconds $EverySec
}
"still not live after $MaxHours hours: $last"
exit 3
