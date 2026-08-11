$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot '公共-查找Python.ps1')

$root = [string](Resolve-Path (Join-Path $PSScriptRoot '..'))
$venv = Join-Path $root '.venv'
$venvPython = Join-Path $venv 'Scripts\python.exe'
$requirements = Join-Path $root 'requirements.txt'
$runtime = $null

# 已有且可运行的项目虚拟环境可以直接更新依赖，不强制要求系统 PATH 中另有
# Python。移动目录、安装中断或使用 Python 3.13 创建的旧环境则自动重建。
if (Test-Path -LiteralPath $venvPython -PathType Leaf) {
  $existingVenv = [pscustomobject]@{ Command = $venvPython; Args = @(); Source = 'project .venv' }
  $existingVersion = Get-PythonVersion -Runtime $existingVenv
  if (Test-PythonRuntime -Runtime $existingVenv) {
    $runtime = $existingVenv
    Write-Host "使用现有项目环境：$venvPython（$existingVersion）" -ForegroundColor Green
  } else {
    $versionText = if ($null -eq $existingVersion) { '解释器已损坏' } else { "Python $existingVersion" }
    Write-Host "现有 .venv 为 $versionText，准备自动重建。" -ForegroundColor Yellow
  }
} elseif (Test-Path -LiteralPath $venv) {
  Write-Host '检测到未完成的 .venv，准备自动重建。' -ForegroundColor Yellow
}

if ($null -eq $runtime) {
  try {
    $baseRuntime = Resolve-PythonRuntime -ProjectRoot $root -SkipProjectVenv
  } catch {
    Write-Host ''
    Write-Host '未检测到兼容的 Python，开始自动部署 Python 3.12。' -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot '安装Python3.12.ps1')
    $baseRuntime = Resolve-PythonRuntime -ProjectRoot $root -SkipProjectVenv
  }
  Assert-Python310OrNewer -Runtime $baseRuntime
  Write-Host "使用基础 Python：$(Format-PythonRuntime -Runtime $baseRuntime)（$(Get-PythonVersion -Runtime $baseRuntime)）"

  if (Test-Path -LiteralPath $venv) {
    $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $venvFull = [System.IO.Path]::GetFullPath($venv)
    $expectedVenvFull = [System.IO.Path]::GetFullPath((Join-Path $root '.venv'))
    if (-not $venvFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $venvFull.Equals($expectedVenvFull, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "虚拟环境路径校验失败：$venvFull"
    }

    Write-Host "正在清理旧虚拟环境：$venv"
    $venvItem = Get-Item -LiteralPath $venv -Force
    if ($venvItem.PSIsContainer) {
      [System.IO.Directory]::Delete($venvFull, $true)
    } else {
      Remove-Item -LiteralPath $venvFull -Force
    }
  }

  Write-Host "正在创建项目虚拟环境：$venv"
  & $baseRuntime.Command @($baseRuntime.Args) -m venv $venv
  if ($LASTEXITCODE -ne 0) {
    throw '创建项目虚拟环境失败。'
  }

  $runtime = Resolve-PythonRuntime -ProjectRoot $root
  Assert-Python310OrNewer -Runtime $runtime
}

Write-Host "正在使用以下环境安装依赖：$(Format-PythonRuntime -Runtime $runtime)"
& $runtime.Command @($runtime.Args) -m pip install --upgrade pip setuptools wheel
if ($LASTEXITCODE -ne 0) {
  throw '更新 pip、setuptools、wheel 失败。'
}

& $runtime.Command @($runtime.Args) -m pip install -r $requirements
if ($LASTEXITCODE -ne 0) {
  Write-Host '依赖安装失败，请检查网络连接以及上方 pip 错误信息。' -ForegroundColor Red
  throw 'OCR 依赖安装失败。'
}

Write-Host ''
Write-Host '依赖已安装到项目 .venv。' -ForegroundColor Green
