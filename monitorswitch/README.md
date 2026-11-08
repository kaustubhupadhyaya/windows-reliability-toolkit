# monitorswitch

Switches an external monitor between two machines over DDC/CI, with read-back
verification.

## Problem

One panel, two laptops. Pressing the panel's OSD buttons is slow, and the
obvious software shortcut (switch the input, then disable the display in
Windows so windows migrate back) is a trap: disabling the monitor detaches it
from the desktop, and the DDC tool can only enumerate attached displays. Once
detached it cannot be reached again, so the recovery hotkey does nothing. The
panel is stranded on the other machine, showing "Show only on 1".

## Fix

`Switch-Input.ps1` sends VCP 0x60 (Input Select) and nothing else. The Windows
display topology is never touched. After writing, it polls `/GetValue` until
it reads the target back. ControlMyMonitor encodes the value in its exit code
as `current + max*256`, and exit code 0 means unreachable, so the script
distinguishes "still re-negotiating" from "the write did not take". It only
re-sends on a concrete wrong value, because re-sending during the HDMI
re-sync blackout restarts the blackout and never converges.

`Setup-Hotkeys.ps1` generates the two `.cmd` wrappers and binds
Ctrl+Alt+1 / Ctrl+Alt+2 through AutoHotkey v2 (or native `.lnk` hotkeys).

## Prerequisites

Download the two NirSoft utilities into this folder (they are not redistributed
here):

- `ControlMyMonitor.exe` - https://www.nirsoft.net/utils/control_my_monitor.html
- `MultiMonitorTool.exe` - https://www.nirsoft.net/utils/multi_monitor_tool.html

Enable DDC/CI in the monitor's OSD menu. AutoHotkey v2 is needed for the
default hotkey method.

## Command

```powershell
# one-off, both directions
.\switch-hdmi1.cmd     # hand the panel to the other machine
.\switch-hdmi2.cmd     # take the panel back

# install Ctrl+Alt+1 / Ctrl+Alt+2, own input = HDMI2
pwsh -File .\Setup-Hotkeys.ps1 -OwnInput 18
```

Exit code 0 means the switch was verified (or the panel was already there).
Exit code 1 means it could not be verified; `switch.log` records every read.

## Verify

Run a switch, then check the log:

```powershell
Get-Content .\switch.log -Tail 5
```

A successful claim ends with `OK verified input=18 after Ns`. A successful
release ends with `OK released (monitor stopped answering DDC ...)`, which is
the expected result once the other machine owns the panel.

## Configuration

`config.psd1` holds the panel's EDID Short Monitor ID and this machine's own
input. Get the Short ID from:

```powershell
.\MultiMonitorTool.exe /scomma monitors.csv
```

VCP 0x60 values: `15` = DisplayPort1, `17` = HDMI1, `18` = HDMI2.

## Notes

- Do not disable or detach the panel while scripting the switch.
- `switch.log` is gitignored.
