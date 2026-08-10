$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = [string](Resolve-Path (Join-Path $PSScriptRoot '..'))
$server = [System.IO.Path]::GetFullPath((Join-Path $root 'ocr\exmail_captcha_ocr_server.py'))

function Test-OcrService {
  try {
    $health = Invoke-RestMethod -Uri 'http://127.0.0.1:17898/' -TimeoutSec 1
    return ($health.ok -eq $true)
  } catch {
    return $false
  }
}

function Get-OcrProcesses {
  $allProcesses = Get-CimInstance Win32_Process -ErrorAction Stop
  return @($allProcesses | Where-Object {
    ($_.Name -ieq 'python.exe' -or $_.Name -ieq 'pythonw.exe') -and
    (-not [string]::IsNullOrWhiteSpace($_.CommandLine)) -and
    ($_.CommandLine.IndexOf($server, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
  })
}

$processes = @(Get-OcrProcesses)
if ($processes.Count -eq 0) {
  if (Test-OcrService) {
    throw '17898 端口上的 OCR 服务仍有响应，但没有匹配到本仓库的 Python 进程，请检查端口占用。'
  }
  Write-Host 'OCR 服务未运行，不需要停止。'
  return
}

$processIds = @($processes | Select-Object -ExpandProperty ProcessId)
Write-Host "正在停止 OCR 服务进程：$($processIds -join ', ')"
foreach ($process in $processes) {
  Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
}

for ($round = 0; $round -lt 10; $round++) {
  Start-Sleep -Milliseconds 500

  $remaining = @(Get-OcrProcesses)
  foreach ($process in $remaining) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
  }

  if (-not (Test-OcrService)) {
    Write-Host "OCR 服务已停止。进程 ID：$($processIds -join ', ')"
    return
  }
}

throw '停止操作完成后健康检查仍有响应，请检查 17898 端口占用。'
