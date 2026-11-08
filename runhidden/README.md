# runhidden

A GUI-subsystem launcher that starts a console program with no window.

## Problem

A console program started by Task Scheduler (or by a `Start-Process` from a
task) gets a console. On Windows 11, Windows Terminal is the default terminal,
so that console appears as a real Windows Terminal window. `-WindowStyle
Hidden` only hides it after it has already flashed on screen, and it does not
stop Windows Terminal from being launched.

## Fix

`runhidden.exe <program> [args...]` calls `CreateProcessW` with
`CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT` and
`STARTF_USESHOWWINDOW`/`SW_HIDE`, from an executable that has no console of its
own. The child still has a working console (stdout, Ctrl events, console
children), it just never has a window and is never handed to Windows Terminal.
The launcher waits for the child and returns its exit code, so a scheduled
task's "Last Run Result" still means something. Everything after the launcher
on the command line is passed through untouched, quotes included.

## Build

No .NET SDK needed. The in-box .NET Framework compiler builds it as a
GUI-subsystem exe:

```powershell
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /target:winexe /out:.\runhidden.exe .\runhidden.cs
```

On 32-bit Windows use `Framework` instead of `Framework64`. `Add-Type` also
works, but only on Windows PowerShell 5.1: PowerShell 7 rejects
`-OutputType WindowsApplication`.

## Command

```powershell
.\runhidden.exe pwsh.exe -NoProfile -File C:\tools\job.ps1
```

In a scheduled task, make `runhidden.exe` the action's program and put the real
command (with its arguments) in the arguments field.

## Verify

```powershell
.\runhidden.exe cmd.exe /c exit 7 | Out-Null; $LASTEXITCODE   # expect 7
```

The `| Out-Null` matters: PowerShell does not wait for a GUI-subsystem exe
otherwise, so `$LASTEXITCODE` would be stale. Run the first command from a
task and confirm no window appears. The task's last run result equals the
child's exit code.

## Notes

`runhidden.exe` is gitignored; build it locally.
