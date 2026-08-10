$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$startScript = Join-Path $root 'scripts\启动服务-后台.ps1'
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

# S4U (service-for-user) 而不是默认的 InteractiveToken。
#
# 不指定 -Principal 时 Register-ScheduledTask 默认用 InteractiveToken，语义是
# 「仅在用户已登录时运行」。那样上面的 BootTrigger 形同虚设：开机那一刻还没有
# 人登录，任务无法启动，而它恰恰是为「登录时刻的调度被时钟跳变干扰」准备的
# 后备。实测确认过这一点：同样配 AtStartup，InteractiveToken 在未登录时不会
# 启动，S4U 会。
#
# S4U 不需要在任务里保存密码（比 -LogonType Password 安全），代价是服务会在
# 无人登录时也运行——对一个只监听 127.0.0.1 的本机服务可以接受。
#
# RunLevel 保持 Limited（不用 Highest）：服务只需绑定回环端口和读写自己的目录，
# 不需要管理员权限，能跑就别提权。
$principal = New-ScheduledTaskPrincipal `
  -UserId "$env:USERDOMAIN\$env:USERNAME" `
  -LogonType S4U `
  -RunLevel Limited

Register-ScheduledTask `
  -TaskName $taskName `
  -Action $action `
  -Trigger @($logonTrigger, $bootTrigger) `
  -Settings $settings `
  -Principal $principal `
  -Description 'Start the local captcha OCR service on 127.0.0.1:17898 for auto-login scripts.' `
  -Force | Out-Null

# 复核注册结果：LogonType 必须是 S4U，否则 BootTrigger 依旧无效。
$registered = Get-ScheduledTask -TaskName $taskName
$logonType = $registered.Principal.LogonType
if ($logonType -ne 'S4U') {
  Write-Warning "LogonType 注册为 $logonType 而不是 S4U；开机(未登录)时不会启动，只有登录触发器有效。"
}

Write-Host "Startup task installed: $taskName"
Write-Host "  execute  : $powershell"
Write-Host "  script   : $startScript"
Write-Host "  identity : $($registered.Principal.UserId)  LogonType=$logonType  RunLevel=$($registered.Principal.RunLevel)"
Write-Host '  triggers : at logon, and at startup + 30s delay (works without login thanks to S4U)'
