$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$startScript = Join-Path $root 'scripts\start-ocr-server-hidden.ps1'
$taskName = 'ExmailCaptchaOcrServer'

if (-not (Test-Path -LiteralPath $startScript)) {
  throw "Start script not found: $startScript"
}

# Use the absolute path to powershell.exe. A bare 'powershell.exe' failed at boot
# with 0x80070001 (ERROR_INVALID_FUNCTION) because the task's environment does not
# reliably resolve it that early in logon.
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powershell)) {
  $resolved = Get-Command powershell.exe -ErrorAction SilentlyContinue
  if (-not $resolved) {
    throw 'Could not locate powershell.exe.'
  }
  $powershell = $resolved.Source
}

$action = New-ScheduledTaskAction `
  -Execute $powershell `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startScript`"" `
  -WorkingDirectory $root

# Two triggers on purpose:
#  - AtLogOn fires on the normal path.
#  - AtStartup with a delay is the backstop. This machine's RTC boots with a stale
#    clock (jumps years once NTP corrects it), and that jump can disturb logon-time
#    scheduling; a delayed startup trigger still gets the service up.
# The script itself is idempotent (it exits early if the port is already healthy),
# so both triggers firing is harmless.
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
$bootTrigger = New-ScheduledTaskTrigger -AtStartup
$bootTrigger.Delay = 'PT30S'

# StartWhenAvailable lets Windows run a missed trigger instead of skipping it,
# which also covers the clock-jump case. Battery limits off so a laptop/UPS
# transition never silently blocks startup.
$settings = New-ScheduledTaskSettingsSet `
  -StartWhenAvailable `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask `
  -TaskName $taskName `
  -Action $action `
  -Trigger @($logonTrigger, $bootTrigger) `
  -Settings $settings `
  -Description 'Start the local captcha OCR service on 127.0.0.1:17898 for auto-login scripts.' `
  -Force | Out-Null

Write-Host "Startup task installed: $taskName"
Write-Host "  execute : $powershell"
Write-Host "  script  : $startScript"
Write-Host '  triggers: at logon, and at startup + 30s delay (backstop)'
