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

$argumentList = @($pythonArgs + @("`"$server`"")) -join ' '

$process = Start-Process `
  -FilePath $python `
  -ArgumentList $argumentList `
  -WorkingDirectory $root `
  -RedirectStandardOutput $log `
  -RedirectStandardError $err `
  -WindowStyle Hidden `
  -PassThru

Write-History "launched python pid=$($process.Id); stdout=$([System.IO.Path]::GetFileName($log)) stderr=$([System.IO.Path]::GetFileName($err))"

# Model loading takes a few seconds. Poll the health endpoint so the history
# records whether the service actually became reachable, and whether the
# process survived startup.
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Milliseconds 1000
  if ($process.HasExited) {
    $errText = ''
    try { $errText = (Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue) } catch {}
    Write-History "python EXITED early with code $($process.ExitCode) after ~$($i + 1)s; stderr: $($errText.Trim())"
    break
  }
  try {
    $h = Invoke-RestMethod 'http://127.0.0.1:17898/' -TimeoutSec 2
    if ($h.ok) {
      $ready = $true
      Write-History "OCR service READY after ~$($i + 1)s (pid=$($process.Id))"
      break
    }
  } catch {
  }
}

if (-not $ready -and -not $process.HasExited) {
  Write-History "OCR service not reachable within 30s but python pid=$($process.Id) still running"
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
