# memory-guard.ps1 - keeps a long-running agent from dying when Windows runs out of memory
# (RAM + page file).
#
# Why: commit charge can sit near the commit limit, and one spike (a local LLM load, several build or
# render stages at once) reaches it. Windows then refuses memory requests and the agent dies with
# exit code 3221226505 (0xC0000409).
#
# Every $IntervalSec seconds it:
#   - appends committed / limit / free GB to commit.csv (the real risk measure, not a heartbeat);
#   - free < $UnloadFreeGB: asks the llama.cpp-style router to unload its loaded model
#     (POST /models/unload; the router reloads it on the next request) and shows a toast saying
#     what it freed;
#   - free < $WarnFreeGB: shows a toast naming the biggest memory users (at most every
#     $ToastCooldownMin minutes).
# It never kills or suspends a process. One instance at a time (named mutex).
# Windows PowerShell 5.1 on purpose: the toasts need WinRT.
# Files: %LOCALAPPDATA%\memory-guard\commit.csv and memory-guard.log
# (each rolls over to *.prev at 5 MB).
param(
  [int]$IntervalSec = 20,
  [double]$WarnFreeGB = 7,
  [double]$UnloadFreeGB = 5,
  [int]$ToastCooldownMin = 10,
  [int]$UnloadCooldownMin = 3,
  [string]$Router = 'http://127.0.0.1:8081',
  [string]$DataDir = (Join-Path $env:LOCALAPPDATA 'memory-guard'),
  [string]$AppName = 'the agent'
)
$ErrorActionPreference = 'Continue'
$dir = $DataDir
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$csv = Join-Path $dir 'commit.csv'
$log = Join-Path $dir 'memory-guard.log'

function Write-Log([string]$m) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $m) }

function Step-Roll([string]$path) {
  $f = Get-Item $path -ErrorAction SilentlyContinue
  if ($f -and $f.Length -gt 5MB) { Move-Item $path ($path -replace '\.(\w+)$', '.prev.$1') -Force }
}

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\memory-guard', [ref]$created)
if (-not $created) { exit 0 }

function Get-TopUsers([int]$n = 3) {
  Get-Process | Group-Object ProcessName | ForEach-Object {
    [pscustomobject]@{ Name = $_.Name; GB = ($_.Group | Measure-Object PrivateMemorySize64 -Sum).Sum / 1GB }
  } | Sort-Object GB -Descending | Select-Object -First $n | ForEach-Object { '{0} {1:F1} GB' -f $_.Name, $_.GB }
}

function Show-Toast([string]$title, [string]$body) {
  try {
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $t = [Security.SecurityElement]::Escape($title); $b = [Security.SecurityElement]::Escape($body)
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>$t</text><text>$b</text></binding></visual></toast>")
    $app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show((New-Object Windows.UI.Notifications.ToastNotification $xml))
    Write-Log "toast: $title | $body"
  } catch { Write-Log "toast failed: $($_.Exception.Message)" }
}

function Invoke-ModelUnload {
  $freed = @()
  try { $models = (Invoke-RestMethod -Uri "$Router/models" -TimeoutSec 5 -UseBasicParsing).data }
  catch { Write-Log "router not reachable: $($_.Exception.Message)"; return $freed }
  foreach ($m in $models) {
    if ($m.status.value -in 'loaded', 'loading') {
      try {
        $body = @{ model = $m.id } | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Post -Uri "$Router/models/unload" -ContentType 'application/json' -Body $body -TimeoutSec 15 -UseBasicParsing | Out-Null
        $freed += $m.id
        Write-Log "unloaded $($m.id)"
      } catch { Write-Log "unload $($m.id) failed: $($_.Exception.Message)" }
    }
  }
  return $freed
}

$committed = New-Object System.Diagnostics.PerformanceCounter('Memory', 'Committed Bytes')
$limitCtr = New-Object System.Diagnostics.PerformanceCounter('Memory', 'Commit Limit')
if (-not (Test-Path $csv)) { 'time,committed_gb,limit_gb,free_gb,action' | Set-Content $csv }
Write-Log "start pid=$PID interval=${IntervalSec}s warn<${WarnFreeGB}GB unload<${UnloadFreeGB}GB"
$lastToast = [datetime]::MinValue
$lastUnload = [datetime]::MinValue

while ($true) {
  try {
    $used = $committed.NextValue() / 1GB
    $limit = $limitCtr.NextValue() / 1GB
    $free = $limit - $used
    $now = Get-Date
    $action = ''
    if ($free -lt $UnloadFreeGB -and ($now - $lastUnload).TotalMinutes -ge $UnloadCooldownMin) {
      $lastUnload = $now
      $gone = @(Invoke-ModelUnload)
      if ($gone.Count -gt 0) {
        $action = 'unload:' + ($gone -join '+')
        Show-Toast 'Memory almost full: local model unloaded' ("{0:F1} of {1:F1} GB in use. Unloaded {2} so {3} keeps running. Biggest: {4}." -f $used, $limit, ($gone -join ', '), $AppName, ((Get-TopUsers) -join ', '))
        $lastToast = $now
      }
    }
    if (-not $action -and $free -lt $WarnFreeGB -and ($now - $lastToast).TotalMinutes -ge $ToastCooldownMin) {
      $action = 'warn'
      Show-Toast 'Memory almost full: the agent may crash' ("Only {0:F1} GB left ({1:F1} of {2:F1} GB in use). Biggest: {3}. Close something you are not using." -f $free, $used, $limit, ((Get-TopUsers) -join ', '))
      $lastToast = $now
    }
    Add-Content -Path $csv -Value ('{0:yyyy-MM-dd HH:mm:ss},{1:F2},{2:F2},{3:F2},{4}' -f $now, $used, $limit, $free, $action)
    Step-Roll $csv
    Step-Roll $log
  } catch { Write-Log "loop error: $($_.Exception.Message)" }
  Start-Sleep -Seconds $IntervalSec
}
