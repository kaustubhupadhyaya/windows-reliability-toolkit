@echo off
rem External monitor -> HDMI2  (CLAIM: take the panel for this machine)
rem DDC/CI only - the Windows display is never disabled. See Switch-Input.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Switch-Input.ps1" -TargetInput 18 -OwnInput 18
exit /b %ERRORLEVEL%
