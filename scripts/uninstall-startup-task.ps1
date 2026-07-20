$ErrorActionPreference = 'Stop'

$taskName = 'ExmailCaptchaOcrServer'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  Write-Host "Startup task removed: $taskName"
} else {
  Write-Host "Startup task is not installed: $taskName"
}
