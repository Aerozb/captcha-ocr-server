$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = [string](Resolve-Path (Join-Path $PSScriptRoot '..'))
$startScript = Join-Path $root 'scripts\start-ocr-server-hidden.ps1'
$taskName = 'ExmailCaptchaOcrServer'

$action = New-ScheduledTaskAction `
  -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$startScript`""
$trigger = New-ScheduledTaskTrigger -AtLogOn

Register-ScheduledTask `
  -TaskName $taskName `
  -Action $action `
  -Trigger $trigger `
  -Description 'Start local OCR service for Tencent Exmail Tampermonkey auto-login.' `
  -Force | Out-Null

Start-ScheduledTask -TaskName $taskName
for ($attempt = 0; $attempt -lt 60; $attempt += 1) {
  Start-Sleep -Milliseconds 500
  try {
    $health = Invoke-RestMethod 'http://127.0.0.1:17898/' -TimeoutSec 2
    if ($health.ok) {
      Write-Host "Startup task installed and OCR service is ready: $taskName"
      return
    }
  } catch {
  }
}

$err = Join-Path $root '.local\logs\ocr-server.err.log'
throw "Startup task was installed, but OCR did not become ready. Check $err"
