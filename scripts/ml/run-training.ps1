[CmdletBinding()]
param(
    [double]$MinF1Macro = 0.60
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $repoRoot
$env:GIT_SHA = (git rev-parse HEAD).Trim()
$env:MODEL_VERSION = $env:GIT_SHA
$env:MODEL_MIN_F1_MACRO = $MinF1Macro.ToString(
    [System.Globalization.CultureInfo]::InvariantCulture
)
$env:MLFLOW_DISABLE_AGENT_HINT = "1"

python ml/validate_data.py
python -m ml.train
if ($LASTEXITCODE -ne 0) { throw "Training ou quality gate échoué." }

$manifestPath = Join-Path $repoRoot "models\model-manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Manifest absent : $manifestPath" }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if (-not $manifest.quality_gate.passed) { throw "Le manifest indique une quality gate négative." }
Write-Host "MODEL_SHA256=$($manifest.model.sha256)"
Write-Host "DATASET_SHA256=$($manifest.dataset.sha256)"
Write-Host "GIT_SHA=$($manifest.git_sha)"
