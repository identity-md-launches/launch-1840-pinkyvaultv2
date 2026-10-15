# Polls an IMD job until it ends or its launch goes live, then prints a summary and exits.
param(
  [string]$JobId = '13613dc2-172f-4b34-b1a6-17de4f20f4df',
  [int]$EverySec = 90,
  [int]$MaxHours = 6
)
$ProgressPreference = 'SilentlyContinue'
$log = Join-Path $PSScriptRoot '..\requests\launch.watch.log'
$deadline = (Get-Date).AddHours($MaxHours)
$last = ''
$misses = 0
while ((Get-Date) -lt $deadline) {
  try {
    $j = (Invoke-WebRequest -Uri "https://api.imd.fun/jobs/$JobId" -UseBasicParsing -TimeoutSec 30).Content | ConvertFrom-Json
    $misses = 0
  } catch {
    $misses++
    if ($misses -ge 20) { "gave up: the API did not answer $misses times in a row ($($_.Exception.Message))"; exit 2 }
    Start-Sleep -Seconds $EverySec
    continue
  }
  $nodes = ($j.nodes | Group-Object state | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
  $launch = if ($j.launch) { "$($j.launch.status)" } else { '' }
  $line = "state=$($j.state) launch=$launch nodes[$nodes] blocked=$($j.blockedReason)"
  if ($line -ne $last) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $line" | Tee-Object -FilePath $log -Append
    $last = $line
  }
  if ($j.state -in 'completed', 'blocked', 'cancelled', 'failed' -or $launch -in 'live', 'parked', 'failed') {
    "ENDED: $line"
    exit 0
  }
  Start-Sleep -Seconds $EverySec
}
"still running after $MaxHours hours: $last"
exit 3
