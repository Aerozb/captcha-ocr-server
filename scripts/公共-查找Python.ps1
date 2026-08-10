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

function Resolve-PythonRuntime {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [switch]$SkipProjectVenv
  )

  $candidates = New-Object System.Collections.Generic.List[object]

  if (-not $SkipProjectVenv) {
    $venvPython = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
    if (Test-Path -LiteralPath $venvPython) {
      $candidates.Add([pscustomobject]@{ Command = $venvPython; Args = @(); Source = 'project .venv' })
    }
  }

  if ($env:PYTHON) {
    $candidates.Add([pscustomobject]@{ Command = $env:PYTHON; Args = @(); Source = 'PYTHON environment variable' })
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

  throw "找不到可用的 $SupportedPythonText。rapidocr-onnxruntime 1.4.x 要求 Python 低于 3.13，请安装 Python 3.12 后重新运行 OCR服务管理.bat。"
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
    throw "当前 Python $version 不在 OCR 服务支持范围 $SupportedPythonText 内。rapidocr-onnxruntime 1.4.x 要求 Python 低于 3.13，请安装 Python 3.12 后重试。"
  }
}

function Format-PythonRuntime {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Runtime
  )

  return (@([string]$Runtime.Command) + @($Runtime.Args)) -join ' '
}

