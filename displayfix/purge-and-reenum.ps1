# Pass 2: deep config audit/purge + GPU restart + verification sweep.
# Run elevated, after fix-edid.ps1.
[CmdletBinding()]
param(
    [string]$ConfigurationIdPattern,
    [string]$GpuInstanceId,
    [string]$BaseDir,
    [int]$WaitSeconds = 10,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.psd1'),
    [string]$LogName = 'fix2-log.txt'
)
$ErrorActionPreference = 'Continue'

$cfg = @{}
if (Test-Path $ConfigPath) { $cfg = Import-PowerShellDataFile -Path $ConfigPath }
if (-not $ConfigurationIdPattern -and $cfg.ConfigurationIdPattern) { $ConfigurationIdPattern = $cfg.ConfigurationIdPattern }
if (-not $BaseDir) { $BaseDir = if ($cfg.BaseDir) { $cfg.BaseDir } else { $PSScriptRoot } }
if (-not $ConfigurationIdPattern) {
    $ids = @($cfg.MonitorIds)
    if ($ids.Count -gt 0) { $ConfigurationIdPattern = $ids[0].Substring(0, [Math]::Max(1, $ids[0].Length - 1)) }
}
if (-not $ConfigurationIdPattern) { throw "No monitor ID configured. Set MonitorIds in $ConfigPath or pass -ConfigurationIdPattern." }
New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
Start-Transcript -Path (Join-Path $BaseDir $LogName) -Force

Write-Host '=== DEEP GraphicsDrivers\Configuration audit ==='
$cfgRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration'
$toDelete = @()
foreach ($set in (Get-ChildItem $cfgRoot)) {
  $name = $set.PSChildName
  if ($name -notmatch [regex]::Escape($ConfigurationIdPattern)) { continue }
  $props = Get-ItemProperty $set.PSPath
  $ts = if ($props.Timestamp) { [DateTime]::FromFileTime($props.Timestamp) } else { 'n/a' }
  Write-Host "SetId: $name"
  Write-Host "   written: $ts"
  $bad = $false
  # recurse EVERY descendant key and inspect mode-related values
  $keys = @($set) + @(Get-ChildItem $set.PSPath -Recurse)
  foreach ($k in $keys) {
    $v = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
    $hasData = $false
    $den = $v.'VSyncFreq.Denominator'; $num = $v.'VSyncFreq.Numerator'
    $hz = if ($den) { [math]::Round($num/$den,2) } else { $null }
    $scan = $v.ScanLineOrdering
    $cx = $v.'ActiveSize.cx'; $cy = $v.'ActiveSize.cy'
    $pcx = $v.'PrimSurfSize.cx'; $pcy = $v.'PrimSurfSize.cy'
    if ($null -ne $scan -or $null -ne $hz -or $cy -or $pcy) { $hasData = $true }
    if ($hasData) {
      $rel = $k.PSPath -replace '.*\\Configuration\\',''
      Write-Host ("   [{0}] PrimSurf={1}x{2} Active={3}x{4} VSync={5}Hz ScanLineOrdering={6}" -f $rel, $pcx, $pcy, $cx, $cy, $hz, $scan)
      if (([int64]$scan -ge 2) -or ($cy -eq 1080 -and $hz -and $hz -lt 35)) { $bad = $true }
    }
  }
  if ($bad) { $toDelete += @{Path=$set.PSPath; Name=$name}; Write-Host '   -> POISONED (interlaced/sub-35Hz 1080) - deleting' }
}
foreach ($d in $toDelete) { Remove-Item $d.Path -Recurse -Force; Write-Host "deleted SetId: $($d.Name)" }
if (-not $toDelete) { Write-Host 'no poisoned SetIds found at any depth' }

Write-Host ''
Write-Host '=== restarting the GPU to force full display re-enumeration ==='
if (-not $GpuInstanceId) {
  $GpuInstanceId = (Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match '^PCI\\VEN_8086' } |
    Select-Object -First 1).InstanceId
}
if (-not $GpuInstanceId) {
  Write-Host '  no Intel GPU found; skipping the GPU restart (pass -GpuInstanceId to override)'
} else {
  & pnputil /restart-device "$GpuInstanceId" 2>&1 | ForEach-Object { Write-Host "  $_" }
  Write-Host "waiting ${WaitSeconds}s for displays to settle..."
  Start-Sleep -Seconds $WaitSeconds
}

Write-Host ''
Write-Host '=== post-restart mode sweep on the target display ==='
& (Join-Path $PSScriptRoot 'Get-DisplayModes.ps1')
Write-Host 'DONE'
Stop-Transcript
