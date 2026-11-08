<#
    Switch-Input.ps1  --  external monitor input switcher (DDC/CI only)

    Sends VCP 0x60 (Input Select) to the monitor and VERIFIES the result by
    reading the value back. The Windows display topology is NEVER touched:
    no /disable, no /EnableAtPosition.

    Why DDC-only: the older design ran `MultiMonitorTool /disable` after the
    input switch. That detaches the monitor from the Windows desktop, which is
    literally the "Show only on 1" state, and it is a one-way trapdoor:
    ControlMyMonitor enumerates displays with EnumDisplayMonitors, which only
    sees desktop-attached monitors, so once the panel was disabled the
    recovery hotkey could never reach it again. The monitor's HPD stays
    asserted on the idle input, so tearing the display down was never needed.

    Exit codes:  0 = switch verified (or already there).   1 = failed.

    -TargetInput / -OwnInput : 15 = DisplayPort1, 17 = HDMI1, 18 = HDMI2
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet(15, 17, 18)][int]$TargetInput,
    [ValidateSet(15, 17, 18)][int]$OwnInput = 18,
    [string]$ShortId,
    [int]$Retries = 2,
    [int]$TimeoutSeconds = 30,
    [string]$ToolPath = (Join-Path $PSScriptRoot 'ControlMyMonitor.exe'),
    [string]$LogPath,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.psd1')
)

$cfg = @{}
if (Test-Path $ConfigPath) { $cfg = Import-PowerShellDataFile -Path $ConfigPath }
if (-not $PSBoundParameters.ContainsKey('OwnInput') -and $cfg.OwnInput) { $OwnInput = [int]$cfg.OwnInput }
if (-not $ShortId) { $ShortId = $cfg.ShortId }
if (-not $ShortId) { throw "No ShortId. Set it in $ConfigPath or pass -ShortId." }
if (-not $LogPath) { $LogPath = if ($cfg.LogPath) { $cfg.LogPath } else { Join-Path $PSScriptRoot 'switch.log' } }

$cmm = $ToolPath
$log = $LogPath

function Write-Log {
    param([string]$Message)
    $line = '{0}  [->{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $TargetInput, $Message
    try { Add-Content -LiteralPath $log -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    Write-Host $line
}

if (-not (Test-Path -LiteralPath $cmm)) {
    Write-Log "FAIL ControlMyMonitor.exe not found at $cmm"
    exit 1
}

function Get-MonitorInput {
    # ControlMyMonitor /GetValue encodes its result in the EXIT CODE as
    #     current + (max * 256)          e.g. 4626 = 0x1212 -> current 18
    # Exit code 0 means the monitor is UNREACHABLE over DDC/CI - it does NOT
    # mean "the value is zero", because 0 is not a valid input-source value.
    try {
        $p = Start-Process -FilePath $cmm -ArgumentList @('/GetValue', $ShortId, '60') `
                           -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        if ($p.ExitCode -eq 0) { return $null }
        return ($p.ExitCode % 256)
    } catch { return $null }
}

function Set-MonitorInput {
    param([int]$Value)
    # /SetValue always exits 0 whether or not it reached the panel, so its
    # exit code is deliberately ignored. Read-back is the only real check.
    try {
        Start-Process -FilePath $cmm -ArgumentList @('/SetValue', $ShortId, '60', "$Value") `
                      -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop | Out-Null
    } catch { }
}

$claiming = ($TargetInput -eq $OwnInput)

# Initial read. Tolerate a TRANSIENT unreachable: the link may still be
# re-negotiating from a previous switch, during which DDC/CI does not answer.
# One failed read does not mean the monitor is gone.
$before = $null
for ($i = 1; $i -le 5; $i++) {
    $before = Get-MonitorInput
    if ($null -ne $before) { break }
    if ($i -lt 5) {
        Write-Log "  initial read unreachable ($i/5), waiting for the link to settle..."
        Start-Sleep -Milliseconds 1300
    }
}

if ($null -eq $before) {
    if (-not $claiming) {
        # Releasing and it already will not talk to us => already on another input.
        Write-Log 'OK already released (monitor not answering DDC - already on another input)'
        exit 0
    }
    # Claiming, and we still cannot read it. Do NOT give up here: a panel can
    # accept a write while its reads are still failing mid-resync. Fall through
    # and attempt the switch; the poll below is what decides success or failure.
    Write-Log 'initial read unreachable after 5 tries; attempting the switch anyway'
}
elseif ($before -eq $TargetInput) {
    Write-Log "OK already on input $TargetInput"
    exit 0
}

Write-Log "current=$before target=$TargetInput claiming=$claiming"

# Send the switch ONCE, then POLL for the result.
#
# Do NOT re-send on every poll. Changing the input makes the monitor
# re-negotiate the link, and DDC/CI is unreachable for several seconds while
# it does. Re-sending restarts that blackout, so a send-every-retry loop never
# converges: it reports failure while the switch has in fact already
# succeeded. A concrete wrong value - not "unreachable" - is the only thing
# worth re-sending for.

Set-MonitorInput $TargetInput

$settleStart = Get-Date
$deadline    = $settleStart.AddSeconds($TimeoutSeconds)
$resends     = 0
$polls       = 0

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 1500
    $polls++
    $now     = Get-MonitorInput
    $elapsed = [int]((Get-Date) - $settleStart).TotalSeconds

    if ($now -eq $TargetInput) {
        Write-Log "OK verified input=$now after ${elapsed}s ($polls polls, $resends resends)"
        exit 0
    }

    if ($null -eq $now) {
        # Unreachable == the link is still re-syncing. On RELEASE it also means
        # the panel has handed itself to the other machine and stopped
        # answering us, which IS the goal - but only trust that after it has
        # had time to settle.
        if (-not $claiming -and $elapsed -ge 6) {
            Write-Log "OK released (monitor stopped answering DDC after ${elapsed}s - panel is on the other input)"
            exit 0
        }
        Write-Log "  settling... ${elapsed}s (unreachable)"
        continue
    }

    # A real value that is not the target: the write genuinely did not take.
    Write-Log "  readback=$now (wanted $TargetInput) at ${elapsed}s"
    if ($resends -lt $Retries) {
        $resends++
        Write-Log "  resending SetValue ($resends/$Retries)"
        Set-MonitorInput $TargetInput
    }
}

# Last chance: one final read after the loop, in case the settle finished just
# past the deadline.
$final = Get-MonitorInput
if ($final -eq $TargetInput) {
    Write-Log "OK verified input=$final on final check"
    exit 0
}
if (-not $claiming -and $null -eq $final) {
    Write-Log 'OK released (monitor not answering DDC on final check)'
    exit 0
}

$seen = if ($null -eq $final) { 'unreachable' } else { "$final" }
Write-Log "FAIL could not verify switch to $TargetInput after ${TimeoutSeconds}s (last readback=$seen)"
if ($null -eq $final) {
    Write-Log "     $ShortId never answered DDC/CI. Check it is attached in Windows display settings (it must NOT be disabled) and that DDC/CI is enabled in the monitor's OSD menu."
}
exit 1
