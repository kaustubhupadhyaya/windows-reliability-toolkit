# windows-reliability-toolkit

Five small tools for Windows problems that are annoying enough to automate and
too niche to have a clean built-in fix. Each one is self-contained, takes its
machine-specific values as parameters or in a small `config.psd1`, and has a
revert or an exit code that tells you whether it worked.

| Folder | Fixes |
| --- | --- |
| [`displayfix`](displayfix/) | A monitor that keeps falling back to interlaced 1080i |
| [`monitorswitch`](monitorswitch/) | Switching one panel between two machines over DDC/CI |
| [`runhidden`](runhidden/) | Console windows flashing up from scheduled tasks |
| [`memory-guard`](memory-guard/) | An agent dying when Windows hits the commit limit |
| [`ssdtools`](ssdtools/) | A wedged RTL9210 USB SSD bridge |

Everything targets Windows 10/11 and PowerShell 5.1 or 7. Registry and device
operations need an elevated shell.

---

## displayfix

**Problem.** A Dell 1080p panel over HDMI kept landing on 1920x1080i at about
29 Hz. Windows stored that mode in `GraphicsDrivers\Configuration`, so it came
back after every reboot, while the EDID kept re-advertising interlaced VICs as
the preferred modes.

**Fix.** Rewrite each interlaced VIC in the EDID's CEA SVD list to its
progressive equivalent, write the patched EDID as `EDID_OVERRIDE` under both
the devnode and the monitor driver's class key, delete the poisoned
`GraphicsDrivers\Configuration` SetIds, and restart the devnodes.

```powershell
pwsh -File .\fix-edid.ps1
pwsh -File .\purge-and-reenum.ps1
```

**Verify.** `pwsh -File .\Get-DisplayModes.ps1` shows
`1920x1080 @ 60Hz interlaced=False` and `INTERLACED modes ... NONE - override
is live`. Undo with `revert-edid-fix.ps1`.

---

## monitorswitch

**Problem.** One panel, two machines. Switching the input in software is easy;
the trap is that disabling the detached display makes it unreachable, because
the DDC tool only enumerates attached monitors. The panel then stays on the
other machine.

**Fix.** Send VCP 0x60 only, never touch the Windows display topology, and poll
the value back until it reports the target. Retries happen only on a concrete
wrong value, not while the link is re-negotiating.

```powershell
.\switch-hdmi1.cmd
.\switch-hdmi2.cmd
pwsh -File .\Setup-Hotkeys.ps1 -OwnInput 18
```

**Verify.** `switch.log` ends with `OK verified input=18 after Ns` for a claim,
or `OK released (monitor stopped answering DDC ...)` for a release. Exit code 0
means verified.

Needs `ControlMyMonitor.exe` and `MultiMonitorTool.exe` from NirSoft (not
redistributed here) and AutoHotkey v2 for the default hotkey method.

---

## runhidden

**Problem.** Task Scheduler starts a console program, Windows Terminal becomes
its terminal, and the window appears before `-WindowStyle Hidden` can hide it.

**Fix.** A GUI-subsystem launcher that calls `CreateProcessW` with
`CREATE_NO_WINDOW` and waits for the child, returning its exit code.

```powershell
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /target:winexe /out:.\runhidden.exe .\runhidden.cs
.\runhidden.exe pwsh.exe -NoProfile -File C:\tools\job.ps1
```

**Verify.** `.\runhidden.exe cmd.exe /c exit 7 | Out-Null; $LASTEXITCODE` prints 7. The
scheduled task's last run result matches the child's exit code, and no window
appears.

---

## memory-guard

**Problem.** Commit charge reaches the commit limit during a spike and the
agent dies with `3221226505`. The system-managed page file is capped at
volume/8, which keeps the limit low.

**Fix.** Sample committed bytes and commit limit every 20 seconds, write them
to `commit.csv`, unload a local router's model below 5 GB free, and toast the
top memory users below 7 GB. A one-time elevated script sets a fixed 30-40 GB
page file.

```powershell
.\runhidden.exe powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\memory-guard.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\pagefile-elevated-once.ps1
```

**Verify.** A row every interval in `%LOCALAPPDATA%\memory-guard\commit.csv`,
and `Win32_PageFileSetting` shows the new initial/maximum size after a reboot.
`commit.csv` is never published.

---

## ssdtools

**Problem.** An RTL9210 USB bridge wedges until the cable is pulled, and a
reset job killed mid disable/enable can leave the device disabled even after a
replug.

**Fix.** Bounded restart, then a measured 2 MB write; if the speed is below
15 MB/s, a disable/enable cycle with `Enable` in a `finally` block plus a status
re-check. Every blocking call has a hard timeout.

```powershell
pwsh -File .\ssd_reset.ps1
pwsh -File .\register_reset_task.ps1
```

**Verify.** `reset_log.txt` ends with `RESET SUCCESS via restart (NN MB/s)` or
`RESET SUCCESS via cycle (NN MB/s)`; exit 0. `RESET FAILED` means a physical
replug is needed.

---

## Layout notes

Vendor binaries, compiled `.exe` files, logs, registry backups and the
`commit.csv` data are not committed. See `.gitignore`. The EDID `.bin` files in
`displayfix/edid/` are the reference originals and patched overrides from the
machine this was built on; they are 256-byte EDIDs, not personal data.

## License

MIT. See [LICENSE](LICENSE).
