# Registers the SSD bridge reset as a scheduled task that runs elevated and hidden.
# Run elevated. Pair with runhidden.exe (see ../runhidden) if a console window appears.
[CmdletBinding()]
param(
    [string]$TaskName = 'SSD-Bridge-Reset',
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'ssd_reset.ps1'),
    [int]$TimeLimitMinutes = 5
)
if (-not (Test-Path $ScriptPath)) { throw "Script not found: $ScriptPath" }
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes $TimeLimitMinutes) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
    -Settings $settings -Force | Out-Null
"registered: $((Get-ScheduledTask -TaskName $TaskName).State)" |
    Out-File (Join-Path $PSScriptRoot 'register_result.txt') -Encoding ascii
