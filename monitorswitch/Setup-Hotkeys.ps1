<#
    Setup-Hotkeys.ps1  --  two-machine monitor input switcher

    Binds Ctrl+Alt+1 -> HDMI1 and Ctrl+Alt+2 -> HDMI2 on the external panel,
    driven over DDC/CI by ControlMyMonitor (VCP 0x60 Input Select).

    DDC/CI ONLY. The Windows display topology is never touched: no
    MultiMonitorTool /disable, no /EnableAtPosition. The panel's HPD stays
    asserted on the idle input, so the display never needs detaching to switch
    inputs. The old claim/release design ran /disable after the release switch
    so Windows would migrate stranded windows back. That was the cause of a
    hard failure: /disable detaches the monitor from the desktop, and because
    ControlMyMonitor enumerates monitors via EnumDisplayMonitors (attached
    displays only), the monitor became unaddressable - a one-way trapdoor.

    Trade-off accepted: while the other machine owns the panel, this machine
    still extends onto a screen it cannot see.

    All switching goes through Switch-Input.ps1, which VERIFIES every switch
    by reading VCP 0x60 back (ControlMyMonitor /GetValue encodes the result in
    its exit code as current + max*256; exit code 0 means unreachable). Both
    NirSoft tools always exit 0 from /SetValue, so read-back is the only
    honest success test.

    -OwnInput : this machine's own input.  15 = DisplayPort1, 17 = HDMI1,
                18 = HDMI2. (VCP 0x60 values are the decimal MCCS codes
                0x0F / 0x11 / 0x12.)

    -HotkeyMethod :
        AutoHotkey (default) - bind via a small .ahk launched from Startup.
                               More reliable than .lnk hotkeys. Requires
                               AutoHotkey v2.
        Lnk                  - native Windows .lnk "Shortcut key" plus an
                               explorer restart.

    The hotkey whose target input equals -OwnInput CLAIMS the panel; the other
    RELEASES it. Both are a single verified DDC write.

    Targeting is by the EDID-derived Short Monitor ID, never by a
    \\.\DISPLAYn ordinal (assigned per boot) and not by the full Monitor ID
    either: that embeds a devnode enumeration index which renumbers on a
    driver reinstall or a connector change.
#>
[CmdletBinding()]
param(
    [ValidateSet(15, 17, 18)]
    [int]$OwnInput = 18,

    [ValidateSet('AutoHotkey', 'Lnk')]
    [string]$HotkeyMethod = 'AutoHotkey',

    [string]$ShortId,

    # (Lnk method only) skip the explorer.exe restart
    [switch]$NoRestartExplorer,

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.psd1')
)

$ErrorActionPreference = 'Stop'
$cfg = @{}
if (Test-Path $ConfigPath) { $cfg = Import-PowerShellDataFile -Path $ConfigPath }
if (-not $PSBoundParameters.ContainsKey('OwnInput') -and $cfg.OwnInput) { $OwnInput = [int]$cfg.OwnInput }
if (-not $ShortId) { $ShortId = $cfg.ShortId }
if (-not $ShortId) { throw "No ShortId. Set it in $ConfigPath or pass -ShortId." }

$here = $PSScriptRoot
$cmm  = Join-Path $here 'ControlMyMonitor.exe'
$mmt  = Join-Path $here 'MultiMonitorTool.exe'
foreach ($e in @($cmm, $mmt)) {
    if (-not (Test-Path $e)) { throw "Required tool not found: $e  (download the NirSoft utilities into $here)" }
}

# --- The worker that does the actual (verified) switching ---
$worker = Join-Path $here 'Switch-Input.ps1'
if (-not (Test-Path $worker)) { throw "Required worker not found: $worker" }

# --- Report-only sanity check: is the panel visible to Windows right now? ---
# NOT fatal. DDC-only switching needs no Monitor ID and no position, so setup
# must still succeed when the panel is currently showing the other machine.
$tmpCsv = Join-Path $env:TEMP ("mmt_setup_{0}.csv" -f $PID)
if (Test-Path $tmpCsv) { Remove-Item $tmpCsv -Force }
Start-Process -FilePath $mmt -ArgumentList "/scomma `"$tmpCsv`"" -Wait -NoNewWindow
$rows = @()
if (Test-Path $tmpCsv) { $rows = @(Import-Csv $tmpCsv) }
Remove-Item $tmpCsv -Force -ErrorAction SilentlyContinue

$panel = $rows | Where-Object { $_.'Short Monitor ID' -eq $ShortId } | Select-Object -First 1

Write-Host "Setup:"
Write-Host "  Short Monitor ID : $ShortId"
Write-Host "  This machine's own input (-OwnInput) : $OwnInput"
Write-Host "  Hotkey method    : $HotkeyMethod"
Write-Host "  Worker           : $worker"
if ($panel) {
    Write-Host ("  Seen by Windows  : yes  (Active={0}, Left-Top={1})" -f $panel.Active, $panel.'Left-Top')
    if ($panel.Active -ne 'Yes') {
        Write-Warning "The panel is present but DISABLED in Windows (Active=$($panel.Active))."
        Write-Warning "DDC/CI cannot reach a detached display. Re-attach it first:"
        Write-Warning "  DisplaySwitch.exe /extend   then   MultiMonitorTool.exe /SetPrimary $ShortId"
    }
} else {
    Write-Warning "Panel '$ShortId' not currently reported by MultiMonitorTool (cable out, or the panel is on the other machine). Hotkeys will still be installed."
}
Write-Host ""

# --- Generate the two switch .cmd files ---
# Ctrl+Alt+1 -> input 17 (HDMI1); Ctrl+Alt+2 -> input 18 (HDMI2).
function Write-SwitchCmd {
    param([string]$FileName, [int]$TargetInput, [string]$Label)
    # Thin wrapper around Switch-Input.ps1. The .cmd names are kept so the AHK
    # script and any existing shortcuts keep working. Read-back verification and
    # retry live in the worker - they are unreasonable to express in batch.
    $role  = if ($TargetInput -eq $OwnInput) { 'CLAIM: take the panel for this machine' }
             else { 'RELEASE: hand the panel to the other machine' }
    $lines = @(
        '@echo off'
        "rem $Label  ($role)"
        'rem DDC/CI only - the Windows display is never disabled. See Switch-Input.ps1.'
        ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Switch-Input.ps1" -TargetInput {0} -OwnInput {1} -ShortId {2}' -f $TargetInput, $OwnInput, $ShortId)
        'exit /b %ERRORLEVEL%'
    )
    $path = Join-Path $here $FileName
    Set-Content -Path $path -Value $lines -Encoding Ascii
    Write-Host "Wrote $FileName :"
    $lines | ForEach-Object { Write-Host "    $_" }
    return $path
}

$cmd1 = Write-SwitchCmd -FileName 'switch-hdmi1.cmd' -TargetInput 17 -Label 'External monitor -> HDMI1'
$cmd2 = Write-SwitchCmd -FileName 'switch-hdmi2.cmd' -TargetInput 18 -Label 'External monitor -> HDMI2'
Write-Host ""

if ($HotkeyMethod -eq 'AutoHotkey') {
    # --- Locate AutoHotkey v2 ---
    $ahk = $null
    $running = Get-CimInstance Win32_Process -Filter "Name='AutoHotkey64.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($running -and $running.ExecutablePath) { $ahk = $running.ExecutablePath }
    if (-not $ahk) {
        foreach ($k in @(
                "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe",
                "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
                "${env:ProgramFiles(x86)}\AutoHotkey\v2\AutoHotkey64.exe")) {
            if (Test-Path $k) { $ahk = $k; break }
        }
    }
    if (-not $ahk) { throw "AutoHotkey v2 (AutoHotkey64.exe) not found. Install it, or run with -HotkeyMethod Lnk." }
    Write-Host "AutoHotkey64.exe: $ahk"

    # --- Write the AHK hotkey script ---
    $ahkScript = Join-Path $here 'MonitorSwitch.ahk'
    # NOTE: inside this double-quoted here-string a literal AutoHotkey `n must be
    # written as a DOUBLE backtick, or PowerShell consumes it as its own escape
    # and emits a real newline into the .ahk (which breaks the string literal).
    $ahkText = @"
#Requires AutoHotkey v2.0
#SingleInstance Force
; Two-machine monitor input switcher (this machine's own input = $OwnInput)
;   Ctrl+Alt+1 -> HDMI1 (release)     Ctrl+Alt+2 -> HDMI2 (claim)
;
; DDC/CI only: the Windows display is NEVER disabled, so the panel can never be
; stranded and "Show only on 1" can never be produced. The tooltip reports the
; REAL result - RunWait captures the .cmd's exit code, which Switch-Input.ps1
; sets from a verified read-back of VCP 0x60.
;
; Generated by Setup-Hotkeys.ps1 - edit that, not this file.

dir := A_ScriptDir

DoSwitch(script, label) {
    logPath := dir . "\switch.log"
    ToolTip(label . "  ...")
    rc := RunWait(A_ComSpec . ' /c "' . script . '"', , "Hide")
    if (rc = 0)
        ToolTip(label . "  OK")
    else
        ToolTip(label . "  FAILED (rc=" . rc . ")``n" . logPath)
    SetTimer(() => ToolTip(), -2500)
}

^!1:: DoSwitch(dir . "\switch-hdmi1.cmd", "Monitor -> HDMI1")
^!2:: DoSwitch(dir . "\switch-hdmi2.cmd", "Monitor -> HDMI2")
"@
    Set-Content -Path $ahkScript -Value $ahkText -Encoding UTF8
    Write-Host "Wrote $ahkScript"

    # --- Startup shortcut ---
    $startup = [Environment]::GetFolderPath('Startup')
    $lnkPath = Join-Path $startup 'MonitorSwitch.lnk'
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnkPath)
    $sc.TargetPath       = $ahk
    $sc.Arguments        = '"' + $ahkScript + '"'
    $sc.WorkingDirectory = $here
    $sc.Description       = 'External monitor input switch hotkeys'
    $sc.Save()
    Write-Host "Startup shortcut: $lnkPath"

    # --- (Re)start the hotkey script now ---
    Get-CimInstance Win32_Process -Filter "Name='AutoHotkey64.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'MonitorSwitch\.ahk' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Process -FilePath $ahk -ArgumentList ('"' + $ahkScript + '"') -WorkingDirectory $here
    Write-Host ""
    Write-Host "AutoHotkey hotkey script started."
}
else {
    # --- Lnk method: Start-Menu shortcuts with native .lnk global hotkeys ---
    $folder = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Monitor Switch'
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $ws = New-Object -ComObject WScript.Shell
    function New-HotkeyLnk {
        param([string]$LnkName, [string]$CmdPath, [string]$Hotkey, [string]$Desc)
        $lnkPath = Join-Path $folder $LnkName
        $sc = $ws.CreateShortcut($lnkPath)
        $sc.TargetPath       = $env:ComSpec
        $sc.Arguments        = '/c "' + $CmdPath + '"'
        $sc.WorkingDirectory = $here
        $sc.WindowStyle      = 7
        $sc.IconLocation     = 'imageres.dll,109'
        $sc.Description       = $Desc
        $sc.Hotkey           = $Hotkey
        $sc.Save()
        Write-Host "Shortcut: $LnkName  [$Hotkey]"
    }
    New-HotkeyLnk -LnkName 'Monitor to HDMI1.lnk' -CmdPath $cmd1 -Hotkey 'Ctrl+Alt+1' -Desc 'Switch the external monitor to HDMI1'
    New-HotkeyLnk -LnkName 'Monitor to HDMI2.lnk' -CmdPath $cmd2 -Hotkey 'Ctrl+Alt+2' -Desc 'Switch the external monitor to HDMI2'
    if (-not $NoRestartExplorer) {
        Write-Host "Restarting explorer.exe to register the .lnk hotkeys..."
        Stop-Process -Name explorer -Force
        Start-Sleep -Seconds 2
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    }
}

Write-Host ""
Write-Host "Done.  Ctrl+Alt+1 = HDMI1,  Ctrl+Alt+2 = HDMI2."
