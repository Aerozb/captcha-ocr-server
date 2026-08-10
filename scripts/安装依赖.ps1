$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot '公共-查找Python.ps1')

$root = [string](Resolve-Path (Join-Path $PSScriptRoot '..'))
$venv = Join-Path $root '.venv'
$venvPython = Join-Path $venv 'Scripts\python.exe'
$requirements = Join-Path $root 'requirements.txt'
$baseRuntime = Resolve-PythonRuntime -ProjectRoot $root -SkipProjectVenv
Assert-Python310OrNewer -Runtime $baseRuntime

Write-Host "Using base Python: $(Format-PythonRuntime -Runtime $baseRuntime)"

# 新系统上的 py -3 可能默认指向 Python 3.13/3.14。旧 .venv 即使目录存在，
# 也可能是上一次失败安装留下的不兼容环境；检查解释器版本后自动重建，避免
# 后续把依赖装到错误的环境里。
if (Test-Path -LiteralPath $venvPython) {
  $existingVenv = [pscustomobject]@{ Command = $venvPython; Args = @(); Source = 'project .venv' }
  $existingVersion = Get-PythonVersion -Runtime $existingVenv
  if (-not (Test-PythonRuntime -Runtime $existingVenv)) {
    $versionText = if ($null -eq $existingVersion) { '未知版本' } else { [string]$existingVersion }
    Write-Host "现有项目 .venv 使用 Python $versionText，与 OCR 服务依赖不兼容，正在重建。" -ForegroundColor Yellow
    $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $venvFull = [System.IO.Path]::GetFullPath($venv)
    if (-not $venvFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "虚拟环境路径不在项目目录内：$venvFull"
    }
    [System.IO.Directory]::Delete($venvFull, $true)
  }
}

if (-not (Test-Path -LiteralPath $venvPython)) {
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
  Write-Host '依赖安装失败。请确认使用的是 Python 3.10-3.12；Python 3.13 及以上不满足 rapidocr-onnxruntime 1.4.x 的发布包要求。' -ForegroundColor Red
  throw 'Failed to install OCR dependencies.'
}

Write-Host ''
Write-Host 'Dependencies installed in .venv.'
