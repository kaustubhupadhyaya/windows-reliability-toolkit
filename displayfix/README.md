# displayfix

Stops a monitor from repeatedly falling back to an interlaced 1080i mode.

## Problem

On a Dell 1080p panel connected over HDMI, Windows kept landing on 1920x1080i at
about 29 Hz instead of 1080p60: blurry text, visible flicker, and the mode
came back after every reboot or resolution change. The panel's stored EDID
advertised interlaced VICs in its CEA extension, and Windows saved the
resulting mode in `GraphicsDrivers\Configuration`. Restarting the driver
fixed it for a while, then the stored mode won again.

## Fix

`fix-edid.ps1` does three things:

1. Reads the stored EDID from every devnode of the configured product codes,
   maps each interlaced VIC in the CEA-861 SVD list to its progressive
   equivalent (`5->16`, `20->31`, `6->2`, `7->3`, `21->17`, `22->18`),
   recomputes the block-1 checksum, and writes the result as `EDID_OVERRIDE`
   under both `Device Parameters` and the monitor driver's class key.
2. Deletes `GraphicsDrivers\Configuration` SetIds for that panel that recorded
   an interlaced or sub-35 Hz 1080 mode. A `.reg` backup is written first.
3. Restarts the monitor devnodes with `pnputil` so the override goes live.

Run elevated:

```powershell
pwsh -File .\fix-edid.ps1
# second pass: deep audit, GPU restart, mode sweep
pwsh -File .\purge-and-reenum.ps1
```

## Verify

```powershell
pwsh -File .\Get-DisplayModes.ps1
```

Expect the current mode to be `1920x1080 @ 60Hz interlaced=False` and:

```
INTERLACED modes on \\.\DISPLAY2: NONE - override is live
```

`switch.log`-style transcripts (`fix-log.txt`, `fix2-log.txt`) are written next
to the scripts and are gitignored.

## Revert

```powershell
pwsh -File .\revert-edid-fix.ps1
```

Removes both `EDID_OVERRIDE` keys and restarts the devnodes. To restore the
purged display configuration, `reg import Configuration-backup.reg` (normally
not needed).

## Configuration

Edit `config.psd1`:

| Key | Meaning |
| --- | --- |
| `MonitorIds` | EDID product codes to patch. Find yours under `HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY`. |
| `ConfigurationIdPattern` | Prefix used to match that panel's `GraphicsDrivers\Configuration` SetIds. |
| `InstanceSuffix` | Device instance suffix. Empty = auto-detect the devnode with a stored EDID. |
| `BaseDir` | Where logs and EDID dumps go. Empty = the script folder. |

The four `.bin` files in `edid/` are the originals and patched overrides captured
on the machine this was built for. They are 256-byte EDIDs and serve as
reference; your panel will produce its own.

`purge-and-reenum.ps1` auto-detects an Intel GPU for the re-enumeration step.
Pass `-GpuInstanceId` to force a specific device.

## Caveat

This edits the registry under `HKLM`. Everything is backed up, and the revert
script removes the overrides, but read both scripts before running them.
