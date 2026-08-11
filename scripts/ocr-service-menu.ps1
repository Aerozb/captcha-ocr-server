$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot '公共-查找Python.ps1')

$root = [string](Resolve-Path (Join-Path $PSScriptRoot '..'))
$scriptsRoot = Join-Path $root 'scripts'
$logsRoot = Join-Path $root 'logs'
$taskName = 'ExmailCaptchaOcrServer'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powershell)) {
  $resolvedPowerShell = Get-Command powershell.exe -ErrorAction Stop
  $powershell = $resolvedPowerShell.Source
}

try {
  $Host.UI.RawUI.WindowTitle = '验证码 OCR 服务管理'
} catch {
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8

function Test-OcrService {
  try {
    $health = Invoke-RestMethod -Uri 'http://127.0.0.1:17898/' -TimeoutSec 2
    return ($health.ok -eq $true)
  } catch {
    return $false
  }
}

function Get-StartupTaskStateText {
  try {
    $command = Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue
    if (-not $command) {
      return '未检测'
    }
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) {
      return '未安装'
    }
    switch ([string]$task.State) {
      'Running' { return '已安装（运行中）' }
      'Ready' { return '已安装（就绪）' }
      'Disabled' { return '已安装（已禁用）' }
      default { return "已安装（$($task.State)）" }
    }
  } catch {
    return '状态未知'
  }
}

function Show-DependencyEnvironmentState {
  Write-Host -NoNewline '依赖环境：'
  $venvRoot = Join-Path $root '.venv'
  $venvPython = Join-Path $venvRoot 'Scripts\python.exe'

  if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    if (Test-Path -LiteralPath $venvRoot) {
      Write-Host '.venv 未完成（选择 [1] 自动修复）' -ForegroundColor Yellow
    } else {
      Write-Host '尚未安装' -ForegroundColor Yellow
    }
    return
  }

  $runtime = [pscustomobject]@{ Command = $venvPython; Args = @(); Source = 'project .venv' }
  $version = Get-PythonVersion -Runtime $runtime
  if ($null -eq $version) {
    Write-Host '.venv 已损坏（选择 [1] 自动修复）' -ForegroundColor Red
  } elseif (-not (Test-PythonRuntime -Runtime $runtime)) {
    Write-Host ".venv Python $version 不兼容（选择 [1] 自动修复）" -ForegroundColor Red
  } else {
    Write-Host ".venv Python $version" -ForegroundColor Green
  }
}

function Show-Menu {
  Clear-Host
  Write-Host ('=' * 68) -ForegroundColor DarkCyan
  Write-Host '                     验证码 OCR 服务管理' -ForegroundColor Cyan
  Write-Host ('=' * 68) -ForegroundColor DarkCyan
  Write-Host "项目目录：$root"

  Write-Host -NoNewline '服务状态：'
  if (Test-OcrService) {
    Write-Host '运行中（http://127.0.0.1:17898/）' -ForegroundColor Green
  } else {
    Write-Host '未运行' -ForegroundColor Yellow
  }

  Show-DependencyEnvironmentState

  Write-Host "开机自启：$(Get-StartupTaskStateText)"
  Write-Host ''
  Write-Host '  [1] 一键安装或更新（Python + OCR 依赖）'
  Write-Host '  [2] 后台启动服务（推荐）'
  Write-Host '  [3] 前台调试启动（新窗口）'
  Write-Host '  [4] 停止服务'
  Write-Host '  [5] 重启后台服务'
  Write-Host '  [6] 部署自检'
  Write-Host '  [7] 安装开机自启'
  Write-Host '  [8] 卸载开机自启'
  Write-Host '  [9] 打开日志目录'
  Write-Host '  [0] 退出'
  Write-Host ''
  Write-Host '首次使用推荐顺序：1 → 6 → 2 → 7' -ForegroundColor DarkGray
  Write-Host '普通任务在当前窗口执行；前台调试会打开新窗口，当前窗口仍会报告启动结果。' -ForegroundColor DarkGray
  Write-Host ''
}

function Wait-ForEnter {
  Write-Host ''
  [void](Read-Host '按回车返回主菜单')
}

function Invoke-RepositoryScript {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptName,
    [Parameter(Mandatory = $true)][string]$DisplayName
  )

  $scriptPath = Join-Path $scriptsRoot $ScriptName
  Write-Host ''
  Write-Host "正在执行：$DisplayName" -ForegroundColor Cyan
  Write-Host "脚本路径：$scriptPath" -ForegroundColor DarkGray
  Write-Host ('-' * 68) -ForegroundColor DarkGray

  if (-not (Test-Path -LiteralPath $scriptPath)) {
    Write-Host "[失败] 脚本不存在：$scriptPath" -ForegroundColor Red
    return $false
  }

  try {
    # 直接调用子 PowerShell，让输出直接写入当前控制台。这里不要接 `| Out-Host`：
    # 管道会创建匿名输出句柄，后台 Python 继承该句柄后，菜单会一直等待管道关闭。
    # 直接调用只等待当前功能脚本退出，不等待它启动的后台服务进程。
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)
    Push-Location -LiteralPath $root
    try {
      & $powershell @arguments
      $exitCode = $LASTEXITCODE
    } finally {
      Pop-Location
    }
  } catch {
    Write-Host "[失败] $DisplayName 启动异常：$($_.Exception.Message)" -ForegroundColor Red
    return $false
  }

  Write-Host ('-' * 68) -ForegroundColor DarkGray
  if ($exitCode -eq 0) {
    Write-Host "[成功] $DisplayName 已完成。" -ForegroundColor Green
    return $true
  }

  Write-Host "[失败] $DisplayName 退出码：$exitCode" -ForegroundColor Red
  return $false
}

function Wait-OcrService {
  param([int]$TimeoutSeconds = 35)

  Write-Host -NoNewline "正在等待 OCR 服务就绪（最长 $TimeoutSeconds 秒）"
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    if (Test-OcrService) {
      Write-Host ''
      return $true
    }
    Write-Host -NoNewline '.'
    Start-Sleep -Seconds 1
  }
  Write-Host ''
  return $false
}

function Invoke-BackgroundStart {
  $scriptOk = Invoke-RepositoryScript -ScriptName '启动服务-后台.ps1' -DisplayName '后台启动服务'
  if (-not $scriptOk) {
    return $false
  }

  if (Wait-OcrService -TimeoutSeconds 8) {
    Write-Host '[成功] 当前窗口已确认 OCR 服务可以访问。' -ForegroundColor Green
    return $true
  }

  Write-Host "[失败] 服务尚未就绪，请查看：$logsRoot\startup-history.log" -ForegroundColor Red
  return $false
}

function Invoke-StopService {
  $scriptOk = Invoke-RepositoryScript -ScriptName '停止服务.ps1' -DisplayName '停止服务'
  if (-not $scriptOk) {
    return $false
  }

  Start-Sleep -Milliseconds 500
  if (Test-OcrService) {
    Write-Host '[失败] 健康检查仍然有响应，请查看端口占用。' -ForegroundColor Red
    return $false
  }

  Write-Host '[成功] 当前窗口已确认 OCR 服务停止。' -ForegroundColor Green
  return $true
}

function Invoke-RestartService {
  Write-Host ''
  Write-Host '准备重启 OCR 服务。' -ForegroundColor Cyan
  if (-not (Invoke-StopService)) {
    Write-Host '[失败] 停止步骤未完成，本次重启已结束。' -ForegroundColor Red
    return $false
  }
  return (Invoke-BackgroundStart)
}

function Start-ForegroundDebugWindow {
  if (Test-OcrService) {
    Write-Host ''
    Write-Host '[提示] OCR 服务已经运行，未重复打开调试实例。需要调试时请先选择“停止服务”。' -ForegroundColor Yellow
    return $true
  }

  $scriptPath = Join-Path $scriptsRoot '启动服务-前台调试.ps1'
  if (-not (Test-Path -LiteralPath $scriptPath)) {
    Write-Host "[失败] 脚本不存在：$scriptPath" -ForegroundColor Red
    return $false
  }

  $escapedRoot = $root.Replace("'", "''")
  $escapedScript = $scriptPath.Replace("'", "''")
  $childLines = @(
    '$ErrorActionPreference = ''Stop'''
    "Set-Location -LiteralPath '$escapedRoot'"
    'try { $Host.UI.RawUI.WindowTitle = ''验证码 OCR 前台调试'' } catch {}'
    'try {'
    "  & '$escapedScript'"
    '  $exitCode = 0'
    '} catch {'
    "  Write-Host ''"
    '  Write-Host ''[失败] 前台调试脚本异常结束。'' -ForegroundColor Red'
    '  Write-Host $_.Exception.Message -ForegroundColor Red'
    '  $exitCode = 1'
    '}'
    'if ($exitCode -ne 0) {'
    "  Write-Host ''"
    '  [void](Read-Host ''按回车关闭此窗口'')'
    '}'
    'exit $exitCode'
  )
  $childCommand = $childLines -join [Environment]::NewLine
  $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))

  try {
    $arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
    $startParameters = @{
      FilePath = $powershell
      ArgumentList = $arguments
      WorkingDirectory = $root
      WindowStyle = 'Normal'
      PassThru = $true
    }
    $child = Start-Process @startParameters
  } catch {
    Write-Host "[失败] 调试窗口启动异常：$($_.Exception.Message)" -ForegroundColor Red
    return $false
  }

  Write-Host ''
  Write-Host "[提示] 调试窗口已打开，进程 PID：$($child.Id)" -ForegroundColor Cyan
  if (Wait-OcrService -TimeoutSeconds 35) {
    Write-Host '[成功] 当前窗口已确认新窗口中的 OCR 服务启动完成。' -ForegroundColor Green
    Write-Host '实时输出保留在调试窗口中；在该窗口按 Ctrl+C 可以结束前台服务。' -ForegroundColor DarkGray
    return $true
  }

  if ($child.HasExited) {
    Write-Host "[失败] 调试窗口已经结束，退出码：$($child.ExitCode)" -ForegroundColor Red
  } else {
    Write-Host '[失败] 35 秒内未检测到健康响应，请查看调试窗口中的输出。' -ForegroundColor Red
  }
  return $false
}

function Open-LogsDirectory {
  try {
    New-Item -ItemType Directory -Path $logsRoot -Force | Out-Null
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $logsRoot) | Out-Null
    Write-Host ''
    Write-Host "[成功] 已打开日志目录：$logsRoot" -ForegroundColor Green
    return $true
  } catch {
    Write-Host "[失败] 日志目录打开异常：$($_.Exception.Message)" -ForegroundColor Red
    return $false
  }
}

try {
  while ($true) {
    Set-Location -LiteralPath $root
    Show-Menu
    $selection = Read-Host '请选择操作 [0-9]'
    if ($null -eq $selection) {
      continue
    }

    switch ($selection.Trim()) {
      '1' {
        [void](Invoke-RepositoryScript -ScriptName '安装依赖.ps1' -DisplayName '安装或更新依赖')
        Wait-ForEnter
      }
      '2' {
        [void](Invoke-BackgroundStart)
        Wait-ForEnter
      }
      '3' {
        [void](Start-ForegroundDebugWindow)
        Wait-ForEnter
      }
      '4' {
        [void](Invoke-StopService)
        Wait-ForEnter
      }
      '5' {
        [void](Invoke-RestartService)
        Wait-ForEnter
      }
      '6' {
        [void](Invoke-RepositoryScript -ScriptName '部署自检.ps1' -DisplayName '部署自检')
        Wait-ForEnter
      }
      '7' {
        [void](Invoke-RepositoryScript -ScriptName '安装开机自启.ps1' -DisplayName '安装开机自启')
        Wait-ForEnter
      }
      '8' {
        [void](Invoke-RepositoryScript -ScriptName '卸载开机自启.ps1' -DisplayName '卸载开机自启')
        Wait-ForEnter
      }
      '9' {
        [void](Open-LogsDirectory)
        Wait-ForEnter
      }
      '0' {
        Write-Host ''
        Write-Host '已退出 OCR 服务管理。' -ForegroundColor Cyan
        exit 0
      }
      default {
        Write-Host ''
        Write-Host '输入不在菜单范围内，请重新选择。' -ForegroundColor Yellow
        Start-Sleep -Seconds 1
      }
    }
  }
} catch {
  Write-Host ''
  Write-Host "[失败] 管理入口异常结束：$($_.Exception.Message)" -ForegroundColor Red
  Write-Host "位置：$($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkRed
  [void](Read-Host '按回车关闭窗口')
  exit 1
}
