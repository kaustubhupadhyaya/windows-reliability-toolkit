# Software power-cycle for an RTL9210-based USB SSD enclosure.
#
# Every potentially-blocking step (external process, Get-Volume, the write probe) runs inside
# Invoke-Bounded, which enforces a hard timeout via a background job and force-kills it on overrun.
# A 16 MB probe with no timeout can run for minutes on a crippled bridge, blowing past a task's
# execution limit and getting hard-killed mid-Disable/Enable, which risks leaving the device
# permanently disabled.
#
# The run marker is the FIRST line written, before any device work, so callers can reject a stale
# leftover verdict by comparing its timestamp to their own trigger time.
#
# Exit codes: 0 = reset verified, 1 = bridge not present, 2 = reset failed.
param(
    [string]$VolumeLabel = 'SSD-BRAIN',
    [string]$DriveLetter = 'E',
    [string]$HardwareId = 'USB\VID_0BDA&PID_9210*',
    [int]$MinSpeedMBps = 15,
    [string]$LogPath = (Join-Path $PSScriptRoot 'reset_log.txt')
)
$log = $LogPath

function L($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') $m" | Out-File $log -Append -Encoding ascii }

function Invoke-Bounded {
    param([scriptblock]$Script, [array]$ArgumentList = @(), [int]$TimeoutSec, [string]$What)
    $job = Start-Job -ScriptBlock $Script -ArgumentList $ArgumentList
    try {
        if (Wait-Job $job -Timeout $TimeoutSec) {
            $out = Receive-Job $job -ErrorAction SilentlyContinue
            return @{ TimedOut = $false; Result = $out }
        } else {
            L "  TIMEOUT after ${TimeoutSec}s: $What"
            return @{ TimedOut = $true; Result = $null }
        }
    } finally {
        Stop-Job $job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
}

"" | Out-File $log -Encoding ascii
L "RESET RUN START"

$dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
       Where-Object { $_.InstanceId -like $HardwareId } |
       Select-Object -First 1
if (-not $dev) { L "Bridge not present on USB - physical replug required"; exit 1 }
L "Found bridge: $($dev.InstanceId) status=$($dev.Status)"

function Get-SsdVolume {
    $label = $VolumeLabel
    Invoke-Bounded -TimeoutSec 8 -What "Get-Volume" -ArgumentList @($label) -Script {
        param($l)
        Get-Volume -FileSystemLabel $l -ErrorAction SilentlyContinue
    }
}

function Wait-ForVolume {
    # Poll (each poll itself bounded) instead of one blind fixed sleep.
    for ($i = 0; $i -lt 5; $i++) {
        $r = Get-SsdVolume
        if (-not $r.TimedOut -and $r.Result -and $r.Result.DriveLetter) { return $r.Result }
        Start-Sleep -Seconds 3
    }
    return $null
}

function Probe {
    # Small (2MB) bounded write+flush. Returns MB/s, -1 (not mounted),
    # or a hashtable if the drive letter changed.
    $vol = Wait-ForVolume
    if (-not $vol) { return -1 }
    if ($vol.DriveLetter -ne $DriveLetter) {
        L "  WARNING: $VolumeLabel remounted as $($vol.DriveLetter): not ${DriveLetter}: - path assumptions break"
        return @{ LetterChanged = $vol.DriveLetter }
    }
    $probePath = '{0}:\_reset_probe.bin' -f $DriveLetter
    $w = Invoke-Bounded -TimeoutSec 15 -What "probe write" -ArgumentList @($probePath) -Script {
        param($f)
        $buf = New-Object byte[] (2*1MB)
        $t = [System.Diagnostics.Stopwatch]::StartNew()
        $fs = [System.IO.File]::Open($f, "Create", "Write", "None")
        $fs.Write($buf, 0, $buf.Length)
        $fs.Flush($true)
        $fs.Close()
        $t.Stop()
        [math]::Round(2 / [math]::Max($t.Elapsed.TotalSeconds, 0.001), 1)
    }
    Remove-Item $probePath -Force -ErrorAction SilentlyContinue
    if ($w.TimedOut -or $null -eq $w.Result) { return -1 }
    return [double]$w.Result
}

function Run-Bounded-Exe {
    param([string]$Exe, [string]$Args, [int]$TimeoutSec)
    $p = Start-Process -FilePath $Exe -ArgumentList $Args -NoNewWindow -PassThru
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch {}
        L "  $Exe timed out after ${TimeoutSec}s - killed"
        return $false
    }
    L "  $Exe exit=$($p.ExitCode)"
    return $true
}

function Report($rate) {
    if ($rate -is [hashtable] -and $rate.ContainsKey('LetterChanged')) {
        L "RESET LETTER-CHANGED: $VolumeLabel is now $($rate.LetterChanged): - update paths, do not treat as success"
        return $false
    }
    return ($rate -ge $MinSpeedMBps)
}

# Attempt 1: lightweight restart-device
L "Attempt 1: pnputil restart-device"
Run-Bounded-Exe -Exe "pnputil.exe" -Args "/restart-device `"$($dev.InstanceId)`"" -TimeoutSec 15 | Out-Null
$rate = Probe
L "Post-restart probe: $rate MB/s"
if (Report $rate) { L "RESET SUCCESS via restart ($rate MB/s)"; exit 0 }

# Attempt 2: full disable/enable cycle. Enable is guaranteed via finally: an unguarded Enable that
# gets skipped or killed leaves the device administratively disabled (which persists across a
# physical replug too).
L "Attempt 2: disable/enable cycle"
$disabled = $false
try {
    $d = Invoke-Bounded -TimeoutSec 10 -What "Disable-PnpDevice" -ArgumentList @($dev.InstanceId) -Script {
        param($id) Disable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction Stop
    }
    $disabled = -not $d.TimedOut
    if ($d.TimedOut) { L "  Disable-PnpDevice timed out" }
} finally {
    Start-Sleep -Seconds 4
    $e = Invoke-Bounded -TimeoutSec 10 -What "Enable-PnpDevice" -ArgumentList @($dev.InstanceId) -Script {
        param($id) Enable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction Stop
    }
    if ($e.TimedOut) { L "  ENABLE TIMED OUT - device may be left disabled, verifying..." }
    Start-Sleep -Seconds 2
    $check = Get-PnpDevice -InstanceId $dev.InstanceId -ErrorAction SilentlyContinue
    if ($check -and $check.Status -ne 'OK' -and $check.Status -ne 'Unknown') {
        L "  device status after enable attempt: $($check.Status) - forcing a second Enable"
        Invoke-Bounded -TimeoutSec 10 -What "Enable-PnpDevice retry" -ArgumentList @($dev.InstanceId) -Script {
            param($id) Enable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction SilentlyContinue
        } | Out-Null
    }
}
$rate = Probe
L "Post-cycle probe: $rate MB/s"
if (Report $rate) { L "RESET SUCCESS via cycle ($rate MB/s)"; exit 0 }

L "RESET FAILED - bridge still sick after both methods. Physical replug required."
exit 2
