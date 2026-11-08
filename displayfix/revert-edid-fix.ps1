# Revert the EDID-override fix. Run elevated.
#   pwsh -File revert-edid-fix.ps1
[CmdletBinding()]
param(
    [string[]]$MonitorIds,
    [string]$InstanceSuffix,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.psd1')
)
$ErrorActionPreference = 'Continue'

$cfg = @{}
if (Test-Path $ConfigPath) { $cfg = Import-PowerShellDataFile -Path $ConfigPath }
if (-not $MonitorIds) { $MonitorIds = @($cfg.MonitorIds) }
if (-not $InstanceSuffix -and $cfg.InstanceSuffix) { $InstanceSuffix = $cfg.InstanceSuffix }
if (-not $MonitorIds -or $MonitorIds.Count -eq 0) {
    throw "No monitor IDs configured. Set MonitorIds in $ConfigPath or pass -MonitorIds."
}

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

foreach ($id in $MonitorIds) {
  $suffix = Get-InstanceSuffix -Id $id
  if (-not $suffix) { Write-Host "devnode $id not present, skipping"; continue }
  $dev = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY\$id\$suffix"
  Remove-Item "$dev\Device Parameters\EDID_OVERRIDE" -Recurse -Force -ErrorAction SilentlyContinue
  $drv = (Get-ItemProperty $dev -Name Driver -ErrorAction SilentlyContinue).Driver
  if ($drv) { Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$drv\EDID_OVERRIDE" -Recurse -Force -ErrorAction SilentlyContinue }
  & pnputil /restart-device "DISPLAY\$id\$suffix"
}
'EDID overrides removed; wire EDID behavior restored (reboot if a devnode restart failed).'
'To restore purged display configs (usually unnecessary): reg import Configuration-backup.reg'
