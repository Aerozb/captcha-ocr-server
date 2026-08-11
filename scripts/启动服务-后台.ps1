$ErrorActionPreference = 'Stop'

# 用共享的 公共-查找Python.ps1，不要在这里内联一份解析逻辑：共享版把项目
# .venv 排在第一候选并做 Python 3.10-3.12 版本校验，内联版两者都没有。内联的后果是
# 依赖装在 .venv、自启服务却用系统 Python，装了等于没装。已验证共享模块在
# -NoProfile -WindowStyle Hidden 的自启上下文下能正常 dot-source。
. (Join-Path $PSScriptRoot '公共-查找Python.ps1')

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$server = Join-Path $root 'ocr\exmail_captcha_ocr_server.py'
$logs = Join-Path $root 'logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null

# Append-only startup history so every boot leaves evidence, even after the
# RTC clock corrects itself post-NTP. Use this to diagnose "service missing at boot".
$history = Join-Path $logs 'startup-history.log'
function Write-History($message) {
  $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  Add-Content -LiteralPath $history -Value "[$stamp] $message"
}

Write-History "start-ocr-server (background) invoked (user=$env:USERNAME)"

# Fast path: already running.
try {
  $health = Invoke-RestMethod 'http://127.0.0.1:17898/' -TimeoutSec 2
  if ($health.ok) {
    Write-History 'OCR service already running; nothing to do'
    Write-Host 'OCR service is already running on http://127.0.0.1:17898/'
    return
  }
} catch {
}

try {
  $runtime = Resolve-PythonRuntime -ProjectRoot $root
  Assert-Python310OrNewer -Runtime $runtime
} catch {
  Write-History "FAILED to resolve Python: $($_.Exception.Message)"
  throw
}
$python = $runtime.Command
$pythonArgs = $runtime.Args
Write-History "using python: $(Format-PythonRuntime -Runtime $runtime) (source: $($runtime.Source))"

# Timestamped per-launch logs so a crashing boot launch is not overwritten by a
# later manual launch. Keeps forensic trail; prune old files below.
$stampForFile = (Get-Date).ToString('yyyyMMdd-HHmmss')
$log = Join-Path $logs "ocr-server-$stampForFile.log"
$err = Join-Path $logs "ocr-server-$stampForFile.err.log"

# Start-Process 配合 RedirectStandardOutput/RedirectStandardError 会让后台 Python
# 继承调用链中的管道句柄。管理菜单虽然已经收到“服务可访问”，仍会等待该句柄关闭，
# 表现为选项 [2] 一直停在成功消息后。通过 Win32_Process.Create 让 WMI 服务创建
# 独立进程，再由 cmd.exe 把输出写入文件，可彻底断开菜单与常驻 Python 的句柄关系。
function ConvertTo-CmdQuotedValue {
  param([Parameter(Mandatory = $true)][string]$Value)

  if ($Value.Contains('"')) {
    throw "后台启动参数包含不受支持的双引号：$Value"
  }
  return '"' + $Value + '"'
}

$pythonCommandParts = New-Object System.Collections.Generic.List[string]
$pythonCommandParts.Add((ConvertTo-CmdQuotedValue -Value $python))
foreach ($argument in @($pythonArgs) + @([string]$server)) {
  $pythonCommandParts.Add((ConvertTo-CmdQuotedValue -Value ([string]$argument)))
}
$pythonCommand = $pythonCommandParts -join ' '
$commandLine = '"{0}" /d /s /c "{1} 1>>"{2}" 2>>"{3}""' -f `
  $env:ComSpec, $pythonCommand, $log, $err

try {
  $startup = New-CimInstance `
    -ClassName Win32_ProcessStartup `
    -Namespace 'root/cimv2' `
    -ClientOnly `
    -Property @{ ShowWindow = [uint16]0 }
  $launchResult = Invoke-CimMethod `
    -ClassName Win32_Process `
    -Namespace 'root/cimv2' `
    -MethodName Create `
    -Arguments @{
      CommandLine = $commandLine
      CurrentDirectory = [string]$root
      ProcessStartupInformation = $startup
    }
} catch {
  Write-History "FAILED to create detached process: $($_.Exception.Message)"
  throw "创建 OCR 后台进程失败：$($_.Exception.Message)"
}

if ([int]$launchResult.ReturnValue -ne 0 -or [int]$launchResult.ProcessId -le 0) {
  Write-History "FAILED Win32_Process.Create return=$($launchResult.ReturnValue) pid=$($launchResult.ProcessId)"
  throw "创建 OCR 后台进程失败，Win32_Process.Create 返回码：$($launchResult.ReturnValue)"
}

$launcherPid = [int]$launchResult.ProcessId
Write-History "launched detached command pid=$launcherPid; stdout=$([System.IO.Path]::GetFileName($log)) stderr=$([System.IO.Path]::GetFileName($err))"

# Model loading takes a few seconds. Poll the health endpoint so the history
# records whether the service actually became reachable, and whether the
# detached cmd/Python process survived startup.
$ready = $false
$launcherExited = $false
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Milliseconds 1000
  $launcherProcess = Get-Process -Id $launcherPid -ErrorAction SilentlyContinue
  if ($null -eq $launcherProcess) {
    $launcherExited = $true
    $errText = ''
    try { $errText = (Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue) } catch {}
    Write-History "detached command EXITED early after ~$($i + 1)s; stderr: $($errText.Trim())"
    break
  }
  try {
    $h = Invoke-RestMethod 'http://127.0.0.1:17898/' -TimeoutSec 2
    if ($h.ok) {
      $ready = $true
      Write-History "OCR service READY after ~$($i + 1)s (launcher-pid=$launcherPid)"
      break
    }
  } catch {
  }
}

if (-not $ready -and -not $launcherExited) {
  Write-History "OCR service not reachable within 30s but detached command pid=$launcherPid is still running"
}
# Prune startup logs older than 7 days to bound disk usage.
Get-ChildItem -LiteralPath $logs -Filter 'ocr-server-*.log' -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
  Remove-Item -Force -ErrorAction SilentlyContinue

if ($ready) {
  Write-Host "OCR service started and reachable. Log: $log"
} else {
  Write-Host "OCR service launch attempted. See history: $history and log: $log"
}
