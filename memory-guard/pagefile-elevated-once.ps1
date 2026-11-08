# One-time elevated step for memory-guard. Run elevated (Windows PowerShell 5.1).
#
# Replaces the system-managed page file with a fixed C:\pagefile.sys of about 32 GB or more. Windows
# caps a system-managed page file at volume size / 8, so the commit limit stays low, and the page
# file starts smaller again after every boot and grows only once memory is already short. Programs
# get refused memory at that limit or while it grows; that is what kills an agent with exit
# 3221226505. A 32 GB minimum keeps the limit about 32 GB above the common system-managed size.
# Takes full effect after a restart.
# Undo: Settings > System > About > Advanced system settings > Performance Settings > Advanced >
#       Virtual memory > tick "Automatically manage paging file size for all drives".
# Result: pagefile-elevated-once.result.txt next to this file.
param(
  [string]$SystemDrive = 'C',
  [string]$OutFile = (Join-Path $PSScriptRoot 'pagefile-elevated-once.result.txt')
)
$ErrorActionPreference = 'Continue'
$out = $OutFile
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
"start $(Get-Date -Format s) elevated=$($me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))" | Set-Content $out
try {
  $freeGB = [math]::Round((Get-PSDrive $SystemDrive).Free / 1GB, 1)
  "$SystemDrive`: free before: $freeGB GB" | Add-Content $out
  if ($freeGB -lt 12) { throw "$SystemDrive`: has only $freeGB GB free; not resizing the page file" }

  $pageFile = '{0}:\pagefile.sys' -f $SystemDrive
  $cs = Get-WmiObject Win32_ComputerSystem -EnableAllPrivileges
  if ($cs.AutomaticManagedPagefile) {
    $cs.AutomaticManagedPagefile = $false
    [void]$cs.Put()
    'system-managed page file: turned off' | Add-Content $out
  }
  $pf = Get-WmiObject Win32_PageFileSetting -EnableAllPrivileges | Where-Object { $_.Name -ieq $pageFile }
  if (-not $pf) {
    $pf = Set-WmiInstance -Class Win32_PageFileSetting -EnableAllPrivileges -Arguments @{ Name = $pageFile; InitialSize = [uint32]0; MaximumSize = [uint32]0 }
  }
  # The system-managed size is capped at volume/8. Try sizes from largest down; keep the first one
  # Windows accepts. WBEM_E_VALUE_OUT_OF_RANGE (0x8004102B) usually means the maximum exceeded the
  # free space left on the volume.
  $ok = $false
  foreach ($c in @(@(32768, 40960), @(32768, 36864), @(32768, 34816), @(32768, 33792), @(32768, 32768), @(30720, 32768), @(30720, 30720))) {
    try {
      $pf.InitialSize = [uint32]$c[0]
      $pf.MaximumSize = [uint32]$c[1]
      [void]$pf.Put()
      "accepted: initial=$($c[0]) MB max=$($c[1]) MB" | Add-Content $out
      $ok = $true
      break
    } catch { "refused: initial=$($c[0]) MB max=$($c[1]) MB ($($_.Exception.InnerException.Message))" | Add-Content $out }
  }
  if (-not $ok) { 'no size accepted; volume stays at system-managed size (PagingFiles <drive> 0 0)' | Add-Content $out }
  Get-WmiObject Win32_PageFileSetting | ForEach-Object { 'now: {0} initial={1} MB max={2} MB' -f $_.Name, $_.InitialSize, $_.MaximumSize } | Add-Content $out
  'AutomaticManagedPagefile=' + (Get-WmiObject Win32_ComputerSystem).AutomaticManagedPagefile | Add-Content $out
} catch { "ERROR: $_" | Add-Content $out }
"done $(Get-Date -Format s) - restart Windows for the new size to take full effect" | Add-Content $out
