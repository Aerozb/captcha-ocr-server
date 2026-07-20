Set-StrictMode -Version 2.0

function Test-PythonRuntime {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Runtime
  )

  try {
    & $Runtime.Command @($Runtime.Args) -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' 2>$null
    return $LASTEXITCODE -eq 0
  } catch {
    return $false
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
    $candidates.Add([pscustomobject]@{ Command = $py.Source; Args = @('-3'); Source = 'Python launcher' })
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

  throw 'Python 3.10+ was not found. Install Python, add it to PATH, or set $env:PYTHON to python.exe.'
}

function Assert-Python310OrNewer {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Runtime
  )

  & $Runtime.Command @($Runtime.Args) -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'
  if ($LASTEXITCODE -ne 0) {
    throw 'Python 3.10 or newer is required.'
  }
}

function Format-PythonRuntime {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Runtime
  )

  return (@([string]$Runtime.Command) + @($Runtime.Args)) -join ' '
}


