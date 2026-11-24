[CmdletBinding()]
param(
  [switch]$InstallDependencies,
  [switch]$InstallOllamaModel
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$smartGuideDir = Join-Path $root 'OPAS-SmartGuide'
$simulatedOpasDir = Join-Path $root 'Simulated-OPAS'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-EnvSetting([string]$Path, [string]$Name) {
  if (-not (Test-Path $Path)) { return '' }
  $pattern = '^\s*' + [regex]::Escape($Name) + '\s*=\s*(.*)$'
  $found = $null
  foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
    if ($line -match $pattern) { $found = [string]$Matches[1] }
  }
  if ($null -eq $found) { return '' }

  $value = $found.Trim()
  if ($value.Length -ge 2 -and
      (($value[0] -eq '"' -and $value[$value.Length - 1] -eq '"') -or
       ($value[0] -eq "'" -and $value[$value.Length - 1] -eq "'"))) {
    $value = $value.Substring(1, $value.Length - 2)
  }
  if ($value -match '^(?i:REPLACE_WITH|YOUR_|CHANGEME|PLACEHOLDER|TODO)') { return '' }
  return $value
}

function Set-EnvSetting([string]$Path, [string]$Name, [string]$Value) {
  $lines = [System.IO.File]::ReadAllLines($Path)
  $lineIndices = @()
  $pattern = '^\s*' + [regex]::Escape($Name) + '\s*='
  for ($i = 0; $i -lt $lines.Length; $i++) {
    if ($lines[$i] -match $pattern) { $lineIndices += $i }
  }
  if ($lineIndices.Count -gt 1) { throw "Duplicate $Name entries in $Path." }

  $replacement = $Name + '="' + $Value + '"'
  if ($lineIndices.Count -eq 1) {
    $lines[$lineIndices[0]] = $replacement
  } else {
    $lines += $replacement
  }
  [System.IO.File]::WriteAllLines($Path, $lines, $utf8NoBom)
}

function New-RandomSecret {
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $bytes = New-Object byte[] 48
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  return [Convert]::ToBase64String($bytes)
}

function Initialize-LocalEnv([string]$Directory) {
  $localPath = Join-Path $Directory '.env.local'
  if (-not (Test-Path $localPath)) {
    $examplePath = Join-Path $Directory '.env.example'
    if (-not (Test-Path $examplePath)) { throw "Missing environment template: $examplePath" }
    Copy-Item -LiteralPath $examplePath -Destination $localPath
    Write-Host "Created local environment file: $localPath"
  }
  return $localPath
}

function Ensure-SharedIntegrationSecret([string]$SmartGuideEnv, [string]$SimulatedOpasEnv) {
  $smartSecret = Get-EnvSetting $SmartGuideEnv 'OPAS_INTEGRATION_SECRET'
  $opasSecret = Get-EnvSetting $SimulatedOpasEnv 'OPAS_INTEGRATION_SECRET'

  if ($smartSecret -and $smartSecret.Length -lt 32) {
    throw 'OPAS_INTEGRATION_SECRET in SmartGuide must contain at least 32 characters.'
  }
  if ($opasSecret -and $opasSecret.Length -lt 32) {
    throw 'OPAS_INTEGRATION_SECRET in Simulated OPAS must contain at least 32 characters.'
  }
  if ($smartSecret -and $opasSecret -and $smartSecret -cne $opasSecret) {
    throw 'The local OPAS integration secrets do not match. Synchronize them before starting the apps.'
  }

  if (-not $smartSecret -and -not $opasSecret) {
    $smartSecret = New-RandomSecret
  } elseif (-not $smartSecret) {
    $smartSecret = $opasSecret
  }
  if (-not $opasSecret) { $opasSecret = $smartSecret }

  Set-EnvSetting $SmartGuideEnv 'OPAS_INTEGRATION_SECRET' $smartSecret
  Set-EnvSetting $SimulatedOpasEnv 'OPAS_INTEGRATION_SECRET' $opasSecret
}

function Ensure-ProjectDependencies([string]$Directory, [string[]]$RequiredModules) {
  $missing = @($RequiredModules | Where-Object {
    -not (Test-Path (Join-Path $Directory ("node_modules\" + $_ + "\package.json")))
  })
  if (-not $InstallDependencies -and $missing.Count -eq 0) { return }
  if (-not (Test-Path (Join-Path $Directory 'package-lock.json'))) {
    throw "Missing package-lock.json in $Directory; cannot restore pinned dependencies."
  }

  Write-Host "Restoring dependencies in $Directory..."
  Push-Location $Directory
  try {
    & $npmCommand.Source ci
    if ($LASTEXITCODE -ne 0) { throw "npm ci failed in $Directory." }
  } finally {
    Pop-Location
  }
}

function Test-HttpEndpoint([string]$Url) {
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 5
    return $response.StatusCode -ge 200 -and $response.StatusCode -lt 400
  } catch {
    return $false
  }
}

function Wait-ForEndpoint([string]$Url, [string]$Name) {
  for ($attempt = 0; $attempt -lt 30; $attempt++) {
    if (Test-HttpEndpoint $Url) {
      Write-Host "$Name is ready at $Url"
      return
    }
    Start-Sleep -Seconds 2
  }
  throw "$Name did not become ready. Check its PowerShell window for startup errors."
}

function Start-Project([string]$Name, [string]$Directory, [int]$Port, [string]$Url) {
  $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
  if ($listeners.Count -gt 0) {
    if (Test-HttpEndpoint $Url) {
      Write-Host "$Name is already responding at $Url; reusing it."
      return
    }
    $processIds = ($listeners | Select-Object -ExpandProperty OwningProcess -Unique) -join ', '
    throw "Port $Port is occupied by process $processIds but $Name is not responding at $Url."
  }

  $escapedDirectory = $Directory.Replace("'", "''")
  $command = "Set-Location -LiteralPath '$escapedDirectory'; npm.cmd run dev"
  $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
  $shellPath = (Get-Process -Id $PID).Path
  Start-Process -FilePath $shellPath -ArgumentList @(
    '-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand
  ) | Out-Null
  Wait-ForEndpoint $Url $Name
}

$nodeCommand = Get-Command node -ErrorAction SilentlyContinue
$npmCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue
if (-not $nodeCommand -or -not $npmCommand) {
  throw 'Install Node.js LTS (including npm) before running this setup. Node 20.19+ or 22.12+ is required.'
}

$nodeVersionText = (& node -p 'process.versions.node').Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not determine the installed Node.js version.' }
$nodeVersion = [version]$nodeVersionText
$supportedNode = ($nodeVersion.Major -eq 20 -and $nodeVersion -ge [version]'20.19.0') -or
  ($nodeVersion.Major -ge 22 -and $nodeVersion -ge [version]'22.12.0')
if (-not $supportedNode) {
  throw "Node.js $nodeVersionText is unsupported by the Vite version in this folder. Install Node 20.19+ or 22.12+."
}

foreach ($directory in @($smartGuideDir, $simulatedOpasDir)) {
  if (-not (Test-Path (Join-Path $directory 'package.json'))) {
    throw "Expected project folder not found: $directory"
  }
}

$smartGuideEnv = Initialize-LocalEnv $smartGuideDir
$simulatedOpasEnv = Initialize-LocalEnv $simulatedOpasDir
Ensure-SharedIntegrationSecret $smartGuideEnv $simulatedOpasEnv
if (-not (Get-EnvSetting $smartGuideEnv 'OPAS_AUTH_SECRET') -or
    (Get-EnvSetting $smartGuideEnv 'OPAS_AUTH_SECRET').Length -lt 32) {
  Set-EnvSetting $smartGuideEnv 'OPAS_AUTH_SECRET' (New-RandomSecret)
}
if (-not (Get-EnvSetting $smartGuideEnv 'SIMULATED_OPAS_API_BASE_URL')) {
  Set-EnvSetting $smartGuideEnv 'SIMULATED_OPAS_API_BASE_URL' 'http://127.0.0.1:3000'
}
if (-not (Get-EnvSetting $simulatedOpasEnv 'SMARTGUIDE_API_BASE_URL')) {
  Set-EnvSetting $simulatedOpasEnv 'SMARTGUIDE_API_BASE_URL' 'http://127.0.0.1:3001'
}

Ensure-ProjectDependencies $simulatedOpasDir @('vite')
Ensure-ProjectDependencies $smartGuideDir @('vite', 'tsx', 'better-sqlite3')

$groqKey = Get-EnvSetting $smartGuideEnv 'GROQ_API_KEY'
$geminiKey = Get-EnvSetting $smartGuideEnv 'GEMINI_API_KEY'
if (-not $groqKey -and -not $geminiKey) {
  Write-Warning 'No online AI key is configured. Add provider keys to OPAS-SmartGuide/.env.local or use the local Ollama model.'
} elseif (-not $groqKey) {
  Write-Warning 'Groq is not configured; Gemini will be the first available cloud provider.'
}

$ollamaCommand = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollamaCommand) {
  Write-Warning 'Ollama is not installed. Cloud guidance can still work with valid API keys; offline guidance needs Ollama and ravok:latest.'
} else {
  $ollamaModels = & ollama list 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Warning 'Ollama is installed but its local service is not responding.'
  } elseif (($ollamaModels -join "`n") -notmatch '(?m)^ravok:latest\s') {
    if ($InstallOllamaModel) {
      Push-Location $root
      try {
        & ollama pull llama3.2:1b
        if ($LASTEXITCODE -ne 0) { throw 'Could not download the llama3.2:1b base model.' }
        & ollama create ravok:latest -f (Join-Path $root 'Modelfile')
        if ($LASTEXITCODE -ne 0) { throw 'Could not create ravok:latest from the project Modelfile.' }
      } finally {
        Pop-Location
      }
    } else {
      Write-Warning 'ravok:latest is not installed. Run this script with -InstallOllamaModel after installing and starting Ollama to enable offline guidance.'
    }
  }
}

Start-Project 'Simulated OPAS' $simulatedOpasDir 3000 'http://127.0.0.1:3000/'
Start-Project 'OPAS SmartGuide' $smartGuideDir 3001 'http://127.0.0.1:3001/'

Write-Host ''
Write-Host 'Demo is ready:'
Write-Host '  Simulated OPAS: http://localhost:3000'
Write-Host '  OPAS SmartGuide: http://localhost:3001'
Write-Host 'Keep both app windows open while using the demo.'
