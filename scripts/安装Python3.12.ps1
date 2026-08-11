param(
  [switch]$DownloadOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot '公共-查找Python.ps1')

$root = [string](Resolve-Path (Join-Path $PSScriptRoot '..'))

if (-not $DownloadOnly) {
  try {
    $existingRuntime = Resolve-PythonRuntime -ProjectRoot $root -SkipProjectVenv
    Assert-Python310OrNewer -Runtime $existingRuntime
    Write-Host "已找到兼容的 Python：$(Format-PythonRuntime -Runtime $existingRuntime)（$(Get-PythonVersion -Runtime $existingRuntime)）" -ForegroundColor Green
    return
  } catch {
    Write-Host '系统中未检测到 Python 3.10-3.12，准备自动安装 Python 3.12.10。' -ForegroundColor Yellow
  }
}

# Python 3.12.10 是 Python 3.12 系列提供 Windows 二进制安装器的稳定版本。
# 安装包固定从 python.org 下载，并使用发布文件的 SHA-256 校验，避免使用到
# 不完整或被替换的缓存文件。
$pythonVersion = '3.12.10'
$architecture = if ($env:PROCESSOR_ARCHITEW6432) {
  [string]$env:PROCESSOR_ARCHITEW6432
} else {
  [string]$env:PROCESSOR_ARCHITECTURE
}
$architecture = $architecture.ToUpperInvariant()

switch -Regex ($architecture) {
  'ARM64' {
    $installerName = "python-$pythonVersion-arm64.exe"
    $expectedHash = '377AC8FD478987940088E879441E702A71B53164D2A1E6F1D51FF77A7E470258'
    break
  }
  'AMD64|X86_64' {
    $installerName = "python-$pythonVersion-amd64.exe"
    $expectedHash = '67B5635E80EA51072B87941312D00EC8927C4DB9BA18938F7AD2D27B328B95FB'
    break
  }
  '^X86$' {
    $installerName = "python-$pythonVersion.exe"
    $expectedHash = 'FDFE385B94F5B8785A0226A886979527FD26EB65DEFDBF29992FD22CC4B0E31E'
    break
  }
  default {
    throw "暂未识别当前 Windows 架构：$architecture"
  }
}

$downloadUri = "https://www.python.org/ftp/python/$pythonVersion/$installerName"
$cacheRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'captcha-ocr-server-python'
$installerPath = Join-Path $cacheRoot $installerName
[void](New-Item -ItemType Directory -Path $cacheRoot -Force)

function Test-InstallerHash {
  if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    return $false
  }
  $actualHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
  return $actualHash -eq $expectedHash
}

if (-not (Test-InstallerHash)) {
  if (Test-Path -LiteralPath $installerPath) {
    Remove-Item -LiteralPath $installerPath -Force
  }

  Write-Host "正在从 Python 官网下载安装包：$installerName"
  Write-Host '下载文件约 26 MB，请保持网络连接。' -ForegroundColor DarkGray

  $previousProgressPreference = $ProgressPreference
  $ProgressPreference = 'SilentlyContinue'
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $downloaded = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
      try {
        Invoke-WebRequest -UseBasicParsing -Uri $downloadUri -OutFile $installerPath
        if (-not (Test-InstallerHash)) {
          throw '安装包 SHA-256 校验未通过。'
        }
        $downloaded = $true
        break
      } catch {
        if (Test-Path -LiteralPath $installerPath) {
          Remove-Item -LiteralPath $installerPath -Force
        }
        if ($attempt -eq 3) {
          throw "Python 安装包下载失败：$($_.Exception.Message)"
        }
        Write-Host "第 $attempt 次下载未完成，2 秒后重试。" -ForegroundColor Yellow
        Start-Sleep -Seconds 2
      }
    }

    if (-not $downloaded) {
      throw 'Python 安装包下载未完成。'
    }
  } finally {
    $ProgressPreference = $previousProgressPreference
  }
} else {
  Write-Host "复用已校验的 Python 安装包：$installerPath"
}

Write-Host '安装包 SHA-256 校验通过。' -ForegroundColor Green
if ($DownloadOnly) {
  Write-Host "仅下载校验完成：$installerPath" -ForegroundColor Green
  return
}

Write-Host '正在静默安装 Python 3.12（当前用户，无需配置 PATH）...'
$installerArguments = @(
  '/quiet'
  'InstallAllUsers=0'
  'PrependPath=0'
  'Include_launcher=0'
  'Include_pip=1'
  'Include_test=0'
  'Include_doc=0'
  'Include_tcltk=0'
  'Shortcuts=0'
  'AssociateFiles=0'
) -join ' '

$installProcess = Start-Process -FilePath $installerPath -ArgumentList $installerArguments -Wait -PassThru
if ($installProcess.ExitCode -notin @(0, 3010)) {
  throw "Python 安装程序退出码：$($installProcess.ExitCode)"
}

Start-Sleep -Seconds 1
$installedRuntime = Resolve-PythonRuntime -ProjectRoot $root -SkipProjectVenv
Assert-Python310OrNewer -Runtime $installedRuntime
Write-Host "Python 安装完成：$(Format-PythonRuntime -Runtime $installedRuntime)（$(Get-PythonVersion -Runtime $installedRuntime)）" -ForegroundColor Green
