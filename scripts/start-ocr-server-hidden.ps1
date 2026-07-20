$ErrorActionPreference = 'Stop'

Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'python-runtime.ps1')

$root = [string](Resolve-Path (Join-Path $PSScriptRoot '..'))
$runtime = Resolve-PythonRuntime -ProjectRoot $root
Assert-Python310OrNewer -Runtime $runtime

$server = Join-Path $root 'ocr\exmail_captcha_ocr_server.py'
$logs = Join-Path $root '.local\logs'
$log = Join-Path $logs 'ocr-server.log'
$err = Join-Path $logs 'ocr-server.err.log'

try {
  $health = Invoke-RestMethod 'http://127.0.0.1:17898/' -TimeoutSec 2
  if ($health.ok) {
    Write-Host 'OCR service is already running on http://127.0.0.1:17898/'
    return
  }
} catch {
}

New-Item -ItemType Directory -Path $logs -Force | Out-Null
$argumentList = @($runtime.Args + @("`"$server`"")) -join ' '

Start-Process `
  -FilePath $runtime.Command `
  -ArgumentList $argumentList `
  -WorkingDirectory $root `
  -RedirectStandardOutput $log `
  -RedirectStandardError $err `
  -WindowStyle Hidden

Write-Host "OCR service started in background. Logs: $log"

