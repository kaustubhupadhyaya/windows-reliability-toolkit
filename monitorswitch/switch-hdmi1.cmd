@echo off
rem External monitor -> HDMI1  (RELEASE: hand the panel to the other machine)
rem DDC/CI only - the Windows display is never disabled. See Switch-Input.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Switch-Input.ps1" -TargetInput 17 -OwnInput 18
exit /b %ERRORLEVEL%
