$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot '公共-查找Python.ps1')

$root = [string](Resolve-Path (Join-Path $PSScriptRoot '..'))
$venv = Join-Path $root '.venv'
$requirements = Join-Path $root 'requirements.txt'
$baseRuntime = Resolve-PythonRuntime -ProjectRoot $root -SkipProjectVenv
Assert-Python310OrNewer -Runtime $baseRuntime

Write-Host "Using base Python: $(Format-PythonRuntime -Runtime $baseRuntime)"
if (-not (Test-Path -LiteralPath (Join-Path $venv 'Scripts\python.exe'))) {
  Write-Host "Creating project virtual environment: $venv"
  & $baseRuntime.Command @($baseRuntime.Args) -m venv $venv
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to create the project virtual environment.'
  }
}

$runtime = Resolve-PythonRuntime -ProjectRoot $root
Assert-Python310OrNewer -Runtime $runtime
Write-Host "Installing dependencies with: $(Format-PythonRuntime -Runtime $runtime)"

& $runtime.Command @($runtime.Args) -m pip install --upgrade pip setuptools wheel
if ($LASTEXITCODE -ne 0) {
  throw 'Failed to update pip tooling.'
}

& $runtime.Command @($runtime.Args) -m pip install -r $requirements
if ($LASTEXITCODE -ne 0) {
  throw 'Failed to install OCR dependencies.'
}

Write-Host ''
Write-Host 'Dependencies installed in .venv.'
