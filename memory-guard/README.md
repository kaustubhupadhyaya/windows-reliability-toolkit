# memory-guard

Watches Windows commit charge and lowers it before an agent crashes.

## Problem

Windows refuses memory requests when commit charge reaches the commit limit.
A long-running agent then dies with exit code `3221226505` (`0xC0000409`).
Task Manager's CPU and private-working-set numbers do not show this: the number
that matters is committed bytes versus the commit limit, and it can sit close
to the limit on a 16 GB machine with a large page file.

## Fix

`memory-guard.ps1` samples `Memory\Committed Bytes` and `Memory\Commit Limit`
every 20 seconds and appends `committed / limit / free` GB to
`%LOCALAPPDATA%\memory-guard\commit.csv`. Two thresholds act on the free value:

- below `-UnloadFreeGB` (default 5): POST `/models/unload` to a local
  llama.cpp-style router so it releases its loaded model, then toast what was
  freed;
- below `-WarnFreeGB` (default 7): toast the biggest memory users, at most once
  per `-ToastCooldownMin`.

It never kills or suspends a process. A named mutex keeps it to one instance.
`commit.csv` and `memory-guard.log` roll over to `*.prev` at 5 MB.

`pagefile-elevated-once.ps1` (run once, elevated) turns off the
system-managed page file and sets a fixed 30-40 GB one. Windows caps a
system-managed page file at volume/8, which is what keeps the commit limit
low. Takes full effect after a restart.

## Command

```powershell
# run hidden at logon, via runhidden.exe
.\runhidden.exe powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\memory-guard.ps1

# one-time page file change, elevated
powershell -NoProfile -ExecutionPolicy Bypass -File .\pagefile-elevated-once.ps1
```

Windows PowerShell 5.1 is required for the toast path (WinRT projection);
PowerShell 7 can run the rest but the toasts fail unless the WinRT types load.

## Verify

```powershell
Get-Content "$env:LOCALAPPDATA\memory-guard\commit.csv" -Tail 5
```

A new row every `-IntervalSec`, and `free_gb` above your thresholds. Force a
test by raising `-WarnFreeGB` above the current free value for one run; a toast
appears and `memory-guard.log` records it.

For the page file:

```powershell
Get-WmiObject Win32_PageFileSetting | Select-Object Name, InitialSize, MaximumSize
(Get-WmiObject Win32_ComputerSystem).AutomaticManagedPagefile   # expect False
```

## Configuration

All thresholds are parameters; `commit.csv` is gitignored and never published.
