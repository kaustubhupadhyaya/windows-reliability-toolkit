# ============================================================
# Root-cause fix: monitor keeps falling back to an interlaced
# 1080i (~29 Hz) mode instead of 1080p60.
#
# - Plants sanitized EDID overrides (interlaced VICs -> progressive)
#   under every devnode of the configured EDID product codes.
# - Purges poisoned GraphicsDrivers\Configuration entries.
# Everything is backed up next to this script.
# Revert: revert-edid-fix.ps1 in the same folder.
#
# Panel identity comes from config.psd1, or pass -MonitorIds.
# Run elevated.
# ============================================================
[CmdletBinding()]
param(
    [string[]]$MonitorIds,
    [string]$BaseDir,
    [string]$InstanceSuffix,
    [string]$ConfigurationIdPattern,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.psd1'),
    [string]$LogName = 'fix-log.txt'
)
$ErrorActionPreference = 'Continue'

$cfg = @{}
if (Test-Path $ConfigPath) { $cfg = Import-PowerShellDataFile -Path $ConfigPath }
if (-not $MonitorIds) { $MonitorIds = @($cfg.MonitorIds) }
if (-not $BaseDir) { $BaseDir = if ($cfg.BaseDir) { $cfg.BaseDir } else { $PSScriptRoot } }
if (-not $InstanceSuffix -and $cfg.InstanceSuffix) { $InstanceSuffix = $cfg.InstanceSuffix }
if (-not $ConfigurationIdPattern -and $cfg.ConfigurationIdPattern) { $ConfigurationIdPattern = $cfg.ConfigurationIdPattern }
if (-not $MonitorIds -or $MonitorIds.Count -eq 0) {
    throw "No monitor IDs configured. Set MonitorIds in $ConfigPath or pass -MonitorIds."
}
if (-not $ConfigurationIdPattern) {
    # Default: the shared prefix of the configured product codes.
    $ConfigurationIdPattern = $MonitorIds[0].Substring(0, [Math]::Max(1, $MonitorIds[0].Length - 1))
}
New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
Start-Transcript -Path (Join-Path $BaseDir $LogName) -Force

$vicMap = @{5=16; 20=31; 6=2; 7=3; 21=17; 22=18}   # interlaced -> progressive equivalent

function Get-InstanceSuffix {
    param([string]$Id)
    if ($InstanceSuffix) { return $InstanceSuffix }
    $root = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY\$Id"
    $hit = Get-ChildItem $root -ErrorAction SilentlyContinue |
        Where-Object { (Get-ItemProperty (Join-Path $_.PSPath 'Device Parameters') -Name EDID -ErrorAction SilentlyContinue).EDID } |
        Select-Object -First 1
    if ($hit) { return $hit.PSChildName }
    return $null
}

function Patch-Edid {
  param([byte[]]$edid)
  $e = [byte[]]($edid.Clone())
  if ($e.Count -lt 256 -or $e[128] -ne 2) { Write-Host '  no CEA extension block; nothing to patch'; return ,$e }
  $dtdStart = $e[130]
  $pos = 132
  $changed = @()
  while ($pos -lt (128 + $dtdStart)) {
    $hdr = $e[$pos]; $tag = ($hdr -shr 5) -band 7; $len = $hdr -band 31
    if ($tag -eq 2) {
      for ($i=1; $i -le $len; $i++) {
        $vic = [int]($e[$pos+$i] -band 0x7F)
        if ($vicMap.ContainsKey($vic)) {
          $newByte = [byte](($e[$pos+$i] -band 0x80) -bor $vicMap[$vic])
          $changed += "VIC $vic->$($vicMap[$vic])"
          $e[$pos+$i] = $newByte
        }
      }
    }
    $pos += 1 + $len
  }
  $sum = 0; for ($i=128; $i -lt 255; $i++) { $sum = ($sum + $e[$i]) % 256 }
  $e[255] = [byte]((256 - $sum) % 256)
  Write-Host ("  patched SVDs: {0}   new block-1 checksum: 0x{1:X2}" -f ($changed -join ', '), $e[255])
  return ,$e
}

foreach ($id in $MonitorIds) {
  Write-Host "=== devnode $id ==="
  $suffix = Get-InstanceSuffix -Id $id
  if (-not $suffix) { Write-Host '  devnode missing or has no stored EDID, skipping'; continue }
  $devPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY\$id\$suffix"
  if (-not (Test-Path $devPath)) { Write-Host '  devnode missing, skipping'; continue }
  $dp = Join-Path $devPath 'Device Parameters'
  $edid = (Get-ItemProperty $dp -Name EDID -ErrorAction SilentlyContinue).EDID
  if (-not $edid) { Write-Host '  no stored EDID, skipping'; continue }
  [IO.File]::WriteAllBytes((Join-Path $BaseDir "$id-original-edid.bin"), [byte[]]$edid)
  $patched = Patch-Edid -edid ([byte[]]$edid)
  [IO.File]::WriteAllBytes((Join-Path $BaseDir "$id-override-edid.bin"), $patched)
  $b0 = [byte[]]$patched[0..127]; $b1 = [byte[]]$patched[128..255]

  # Location 1: Device Parameters\EDID_OVERRIDE (CRU-proven location)
  $ov1 = Join-Path $dp 'EDID_OVERRIDE'
  New-Item -Path $ov1 -Force | Out-Null
  New-ItemProperty -Path $ov1 -Name '0' -PropertyType Binary -Value $b0 -Force | Out-Null
  New-ItemProperty -Path $ov1 -Name '1' -PropertyType Binary -Value $b1 -Force | Out-Null
  Write-Host "  wrote override -> Device Parameters\EDID_OVERRIDE (blocks 0,1)"

  # Location 2: the devnode's driver (class) key (documented monitor-INF location)
  $drv = (Get-ItemProperty $devPath -Name Driver -ErrorAction SilentlyContinue).Driver
  if ($drv) {
    $drvKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$drv"
    if (Test-Path $drvKey) {
      $ov2 = Join-Path $drvKey 'EDID_OVERRIDE'
      New-Item -Path $ov2 -Force | Out-Null
      New-ItemProperty -Path $ov2 -Name '0' -PropertyType Binary -Value $b0 -Force | Out-Null
      New-ItemProperty -Path $ov2 -Name '1' -PropertyType Binary -Value $b1 -Force | Out-Null
      Write-Host "  wrote override -> Class\$drv\EDID_OVERRIDE (blocks 0,1)"
    } else { Write-Host "  WARN: driver key $drvKey not found" }
  } else { Write-Host '  WARN: devnode has no Driver value' }
}

Write-Host ''
Write-Host '=== GraphicsDrivers\Configuration audit (poisoned-mode purge) ==='
reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration' (Join-Path $BaseDir 'Configuration-backup.reg') /y | Out-Null
Write-Host '  (full backup saved: Configuration-backup.reg)'
$cfgRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration'
$toDelete = @()
Get-ChildItem $cfgRoot | ForEach-Object {
  $name = $_.PSChildName
  if ($name -notmatch $ConfigurationIdPattern) { return }
  $props = Get-ItemProperty $_.PSPath
  $ts = if ($props.Timestamp) { [DateTime]::FromFileTime($props.Timestamp) } else { 'n/a' }
  Write-Host "SetId: $name"
  Write-Host "   written: $ts"
  $bad = $false
  foreach ($sub in (Get-ChildItem $_.PSPath)) {
    $v = Get-ItemProperty $sub.PSPath
    $den = $v.'VSyncFreq.Denominator'; $num = $v.'VSyncFreq.Numerator'
    $hz = if ($den) { [math]::Round($num/$den,2) } else { 0 }
    $scan = [int64]$v.ScanLineOrdering
    Write-Host ("   path {0}: {1}x{2} @ {3}Hz  ScanLineOrdering={4}" -f $sub.PSChildName, $v.'ActiveSize.cx', $v.'ActiveSize.cy', $hz, $scan)
    if ($scan -ge 2 -or ($v.'ActiveSize.cy' -eq 1080 -and $hz -gt 0 -and $hz -lt 35)) { $bad = $true }
  }
  if ($bad) { $toDelete += $_.PSPath; Write-Host '   -> POISONED (interlaced/29Hz) - will delete' }
}
foreach ($p in $toDelete) { Remove-Item $p -Recurse -Force; Write-Host "deleted poisoned SetId: $($p -replace '.*\\','')" }
if (-not $toDelete) { Write-Host 'no poisoned Configuration entries matched (nothing deleted)' }

Write-Host ''
Write-Host '=== Connectivity audit (log only) ==='
$connRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Connectivity'
if (Test-Path $connRoot) {
  reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Connectivity' (Join-Path $BaseDir 'Connectivity-backup.reg') /y | Out-Null
  Get-ChildItem $connRoot | ForEach-Object { Write-Host "  $($_.PSChildName)" }
} else { Write-Host '  (no Connectivity key present)' }

Write-Host ''
Write-Host '=== restarting monitor devnodes to apply override ==='
foreach ($id in $MonitorIds) {
  $suffix = Get-InstanceSuffix -Id $id
  if (-not $suffix) { continue }
  $iid = "DISPLAY\$id\$suffix"
  Write-Host "pnputil /restart-device $iid"
  & pnputil /restart-device "$iid" 2>&1 | ForEach-Object { Write-Host "  $_" }
}
Write-Host 'DONE'
Stop-Transcript
