# ssdtools

Software power-cycle for an RTL9210 USB-to-SATA/NVMe bridge that wedges.

## Problem

The bridge (a Techie RTL9210 enclosure in the original case) occasionally stops
answering: the volume disappears or writes hang until the USB cable is pulled.
A physical replug fixes it, but that is not something a scheduled task or a
remote session can do.

Restarting the device is not enough on its own. `pnputil /restart-device` and
`Disable-PnpDevice` / `Enable-PnpDevice` can block for minutes on a sick
bridge, and a job killed mid-cycle can leave the device administratively
disabled, which survives a physical replug.

## Fix

`ssd_reset.ps1` tries the cheapest reset first, then a full disable/enable:

1. `pnputil /restart-device` (15 s bound), then a 2 MB bounded write probe.
2. If the measured write speed is below `-MinSpeedMBps` (default 15), disable
   and enable the device. `Enable` runs in a `finally` block, and the script
   re-checks `Status` and retries `Enable` if the device is not `OK`.
3. It writes `RESET RUN START` as the first log line, so a caller can reject a
   stale verdict from a previous run.

Every blocking call (external process, `Get-Volume`, the write probe) runs
through `Invoke-Bounded`, a background job with a hard timeout, so total
runtime stays around 160 seconds.

## Command

```powershell
# elevated
pwsh -File .\ssd_reset.ps1

# register it as an elevated scheduled task with a 5-minute limit
pwsh -File .\register_reset_task.ps1
```

## Verify

```powershell
Get-Content .\reset_log.txt -Tail 10
```

Expect `RESET SUCCESS via restart (NN MB/s)` or `RESET SUCCESS via cycle`.
`RESET FAILED ... Physical replug required` means both methods ran and the
bridge is still below the speed threshold.

## Configuration

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-VolumeLabel` | `SSD-BRAIN` | Filesystem label the volume must come back with. |
| `-DriveLetter` | `E` | Expected letter. A different letter is reported, never treated as success. |
| `-HardwareId` | `USB\VID_0BDA&PID_9210*` | PnP ID of the bridge. |
| `-MinSpeedMBps` | `15` | Probe write speed that counts as healthy. |
| `-LogPath` | `reset_log.txt` | Log file. |

`reset_log.txt` and `register_result.txt` are gitignored.

## Caveat

Disabling a USB storage device that holds a mounted volume is disruptive. Do not
point this at a system or boot drive.
