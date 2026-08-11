Set-StrictMode -Version 2.0

# rapidocr-onnxruntime 1.4.x 的发布包要求 Python < 3.13；当前仓库因此支持
# Python 3.10、3.11、3.12。优先选明确的小版本，避免 py -3 在新系统上选到
# Python 3.13/3.14，导致 pip 解析依赖时才报错。
$MinimumPythonVersion = [version]'3.10'
$MaximumPythonVersionExclusive = [version]'3.13'
$SupportedPythonText = 'Python 3.10-3.12'

function Get-PythonVersion {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Runtime
  )

  try {
    $raw = @(& $Runtime.Command @($Runtime.Args) -c 'import sys; print(chr(46).join(map(str, sys.version_info[:3])))' 2>$null)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or $raw.Count -eq 0) {
      return $null
    }

    $versionText = ([string]$raw[0]).Trim()
    if ([string]::IsNullOrWhiteSpace($versionText)) {
      return $null
    }
    return [version]$versionText
  } catch {
    return $null
  }
}

function Test-PythonRuntime {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Runtime
  )

  $version = Get-PythonVersion -Runtime $Runtime
  return ($null -ne $version -and
    $version -ge $MinimumPythonVersion -and
    $version -lt $MaximumPythonVersionExclusive)
}

function Add-PythonPathCandidate {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [System.Collections.Generic.List[object]]$Candidates,

    [string]$PythonPath,

    [Parameter(Mandatory = $true)]
    [string]$Source
  )

  if ([string]::IsNullOrWhiteSpace($PythonPath)) {
    return
  }

  try {
    $fullPath = [System.IO.Path]::GetFullPath($PythonPath)
  } catch {
    return
  }

  if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
    $Candidates.Add([pscustomobject]@{ Command = $fullPath; Args = @(); Source = $Source })
  }
}

function Resolve-PythonRuntime {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [switch]$SkipProjectVenv
  )

  $candidates = New-Object System.Collections.Generic.List[object]

  if (-not $SkipProjectVenv) {
    Add-PythonPathCandidate -Candidates $candidates `
      -PythonPath (Join-Path $ProjectRoot '.venv\Scripts\python.exe') `
      -Source 'project .venv'
  }

  if ($env:PYTHON) {
    Add-PythonPathCandidate -Candidates $candidates -PythonPath $env:PYTHON -Source 'PYTHON environment variable'
  }

  # 安装器使用当前用户默认目录且不依赖 PATH。显式扫描这些位置，保证 Python
  # 刚静默安装完成后，当前 PowerShell 窗口无需重开就能继续创建 .venv。
  foreach ($minor in @(12, 11, 10)) {
    $folderName = "Python3$minor"
    if ($env:LOCALAPPDATA) {
      Add-PythonPathCandidate -Candidates $candidates `
        -PythonPath (Join-Path $env:LOCALAPPDATA "Programs\Python\$folderName\python.exe") `
        -Source "current-user Python 3.$minor"
    }

    foreach ($programFilesRoot in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
      if ($programFilesRoot) {
        Add-PythonPathCandidate -Candidates $candidates `
          -PythonPath (Join-Path $programFilesRoot "$folderName\python.exe") `
          -Source "installed Python 3.$minor"
      }
    }

    if ($env:SystemDrive) {
      Add-PythonPathCandidate -Candidates $candidates `
        -PythonPath (Join-Path $env:SystemDrive "$folderName\python.exe") `
        -Source "root Python 3.$minor"
    }
  }

  # 同时读取 python.org 安装器使用的 PEP 514 注册表项，兼容自定义安装目录。
  $registryRoots = @(
    'HKCU:\Software\Python\PythonCore',
    'HKLM:\Software\Python\PythonCore',
    'HKLM:\Software\WOW6432Node\Python\PythonCore'
  )
  foreach ($minor in @(12, 11, 10)) {
    foreach ($registryRoot in $registryRoots) {
      foreach ($tag in @("3.$minor", "3.$minor-64", "3.$minor-32", "3.$minor-arm64")) {
        $installPathKey = Join-Path (Join-Path $registryRoot $tag) 'InstallPath'
        try {
          if (Test-Path -LiteralPath $installPathKey) {
            $installDirectory = [string](Get-Item -LiteralPath $installPathKey).GetValue('')
            if ($installDirectory) {
              Add-PythonPathCandidate -Candidates $candidates `
                -PythonPath (Join-Path $installDirectory 'python.exe') `
                -Source "Python registry $tag"
            }
          }
        } catch {
          # 某些受管系统会限制读取个别注册表分支，继续检查其他候选即可。
        }
      }
    }
  }

  $py = Get-Command py -ErrorAction SilentlyContinue
  if ($py) {
    # 先尝试仓库依赖已验证过的小版本，再尝试系统默认版本。
    foreach ($minor in @(12, 11, 10)) {
      $candidates.Add([pscustomobject]@{ Command = $py.Source; Args = @("-3.$minor"); Source = "Python launcher 3.$minor" })
    }
    $candidates.Add([pscustomobject]@{ Command = $py.Source; Args = @('-3'); Source = 'Python launcher default' })
  }

  $python = Get-Command python -ErrorAction SilentlyContinue
  if ($python) {
    $candidates.Add([pscustomobject]@{ Command = $python.Source; Args = @(); Source = 'PATH' })
  }

  foreach ($runtime in $candidates) {
    if (Test-PythonRuntime -Runtime $runtime) {
      return $runtime
    }
  }

  throw "找不到可用的 $SupportedPythonText。请通过 OCR服务管理.bat 选择 [1]，安装器会自动部署 Python 3.12。"
}

function Assert-Python310OrNewer {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Runtime
  )

  $version = Get-PythonVersion -Runtime $Runtime
  if ($null -eq $version) {
    throw '读取 Python 版本失败。'
  }
  if ($version -lt $MinimumPythonVersion -or $version -ge $MaximumPythonVersionExclusive) {
    throw "当前 Python $version 不在 OCR 服务支持范围 $SupportedPythonText 内。请通过 OCR服务管理.bat 选择 [1]，自动部署 Python 3.12。"
  }
}

function Format-PythonRuntime {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Runtime
  )

  return (@([string]$Runtime.Command) + @($Runtime.Args)) -join ' '
}
