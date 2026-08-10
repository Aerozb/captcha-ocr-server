$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot '公共-查找Python.ps1')

$root = [string](Resolve-Path (Join-Path $PSScriptRoot '..'))
$ocrServer = Join-Path $root 'ocr\exmail_captcha_ocr_server.py'

$runtime = Resolve-PythonRuntime -ProjectRoot $root
Assert-Python310OrNewer -Runtime $runtime
& $runtime.Command @($runtime.Args) -m py_compile $ocrServer
if ($LASTEXITCODE -ne 0) {
  throw 'OCR server Python syntax check failed.'
}
Write-Host 'Python syntax: OK'

$parseFailed = $false
foreach ($script in Get-ChildItem (Join-Path $root 'scripts') -Filter '*.ps1') {
  $tokens = $null
  $parseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseFile(
    $script.FullName,
    [ref]$tokens,
    [ref]$parseErrors
  ) | Out-Null

  if ($parseErrors.Count -gt 0) {
    $parseFailed = $true
    foreach ($parseError in $parseErrors) {
      Write-Error "$($script.Name): $($parseError.Message)"
    }
  }
}
if ($parseFailed) {
  throw 'PowerShell syntax check failed.'
}
Write-Host 'PowerShell syntax: OK'

$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
  & $git.Source -C $root check-ignore --quiet '.local/live/human.txt'
  if ($LASTEXITCODE -ne 0) {
    throw '.local is not ignored by Git.'
  }
  & $git.Source -C $root check-ignore --quiet 'logs/ocr-server-20260101-000000.log'
  if ($LASTEXITCODE -ne 0) {
    throw 'logs/ is not ignored by Git.'
  }
  Write-Host 'Git local-file ignore rule: OK'
} else {
  Write-Warning 'Git is not installed; skipped the ignore-rule check.'
}

Write-Host 'Repository verification passed.'
