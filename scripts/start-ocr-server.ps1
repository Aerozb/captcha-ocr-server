$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'python-runtime.ps1')

$root = [string](Resolve-Path (Join-Path $PSScriptRoot '..'))
$server = Join-Path $root 'ocr\exmail_captcha_ocr_server.py'
$runtime = Resolve-PythonRuntime -ProjectRoot $root
Assert-Python310OrNewer -Runtime $runtime

try {
  $health = Invoke-RestMethod 'http://127.0.0.1:17898/' -TimeoutSec 2
  if ($health.ok) {
    Write-Host 'OCR service is already running on http://127.0.0.1:17898/'
    return
  }
} catch {
}

Write-Host "Using Python: $(Format-PythonRuntime -Runtime $runtime)"
Write-Host 'Starting Exmail captcha OCR service on http://127.0.0.1:17898/'
& $runtime.Command @($runtime.Args) $server
if ($LASTEXITCODE -ne 0) {
  throw "OCR service exited with code $LASTEXITCODE."
}
