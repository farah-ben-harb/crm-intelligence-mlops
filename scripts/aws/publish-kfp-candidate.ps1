[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$EvidencePath,
    [Parameter(Mandatory=$true)][string]$ModelPath,
    [string]$Bucket = "mini-crm-models-251538491265-eu-north-1",
    [string]$Profile = "mini-crm",
    [string]$Region = "eu-north-1",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $repoRoot

if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) {
    throw "Preuve KFP/MLflow introuvable : $EvidencePath"
}
if (-not (Test-Path -LiteralPath $ModelPath -PathType Leaf)) {
    throw "Modèle KFP introuvable : $ModelPath"
}
$evidence = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json
if ($evidence.kfp.state -ne "SUCCEEDED") { throw "Le run KFP n'est pas réussi." }
if (-not $evidence.quality_gate.passed) { throw "Quality gate négative : publication refusée." }
if ($evidence.git_sha -notmatch '^[0-9a-f]{40}$') { throw "Git SHA invalide." }
$modelSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $ModelPath).Hash.ToLowerInvariant()
if ($modelSha -ne [string]$evidence.model_sha256.ToLowerInvariant()) {
    throw "Le SHA local ne correspond pas à la preuve MLflow/KFP."
}

$aws = (Get-Command aws -ErrorAction SilentlyContinue).Source
if (-not $aws -and (Test-Path "C:\Program Files\Amazon\AWSCLIV2\aws.exe")) {
    $aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
}
if (-not $aws) { throw "AWS CLI introuvable." }

$identity = (& $aws sts get-caller-identity --profile $Profile --region $Region --output json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0 -or $identity.Account -ne "251538491265") {
    throw "Compte AWS inattendu ou session expirée."
}

$modelKey = "candidates/$($evidence.git_sha)/model.joblib"
$manifestKey = "candidates/$($evidence.git_sha)/manifest.json"
foreach ($key in @($modelKey, $manifestKey)) {
    & $aws s3api head-object --profile $Profile --region $Region --bucket $Bucket --key $key 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { throw "La clé S3 existe déjà ; aucun écrasement autorisé : $key" }
}

$metadata = "sha256=$modelSha,kfp_run_id=$($evidence.kfp.run_id),mlflow_run_id=$($evidence.mlflow.run_id),registry_version=$($evidence.mlflow.registry_version)"
$modelResult = & $aws s3api put-object --profile $Profile --region $Region --bucket $Bucket --key $modelKey --body $ModelPath --content-type "application/octet-stream" --metadata $metadata --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $modelResult.VersionId) { throw "Publication du modèle candidat échouée." }
$modelVersion = [string]$modelResult.VersionId

$head = & $aws s3api head-object --profile $Profile --region $Region --bucket $Bucket --key $modelKey --version-id $modelVersion --output json | ConvertFrom-Json
if ($head.Metadata.sha256 -ne $modelSha) { throw "Le SHA-256 S3 du modèle ne correspond pas." }

$manifest = [ordered]@{
    schema_version = 2
    status = "candidate_only"
    git_sha = [string]$evidence.git_sha
    dataset_sha256 = [string]$evidence.dataset_sha256
    model_sha256 = $modelSha
    metrics = $evidence.metrics
    quality_gate = $evidence.quality_gate
    kfp = $evidence.kfp
    mlflow = $evidence.mlflow
    s3 = [ordered]@{
        bucket = $Bucket
        model_key = $modelKey
        model_version_id = $modelVersion
        manifest_key = $manifestKey
    }
    production = [ordered]@{
        changed = $false
        alias = "candidate"
    }
}
$tempManifest = Join-Path $env:TEMP "mini-crm-kfp-manifest-$([guid]::NewGuid().ToString('N')).json"
$manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tempManifest -Encoding utf8
try {
    $manifestResult = & $aws s3api put-object --profile $Profile --region $Region --bucket $Bucket --key $manifestKey --body $tempManifest --content-type "application/json" --metadata "kfp_run_id=$($evidence.kfp.run_id),mlflow_run_id=$($evidence.mlflow.run_id),model_sha256=$modelSha" --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $manifestResult.VersionId) { throw "Publication du manifeste candidat échouée." }
    $manifestVersion = [string]$manifestResult.VersionId
} finally {
    Remove-Item -LiteralPath $tempManifest -Force -ErrorAction SilentlyContinue
}

$downloadPath = Join-Path $env:TEMP "mini-crm-kfp-verify-$([guid]::NewGuid().ToString('N')).joblib"
try {
    & $aws s3api get-object --profile $Profile --region $Region --bucket $Bucket --key $modelKey --version-id $modelVersion $downloadPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Téléchargement de vérification S3 échoué." }
    $downloadSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloadPath).Hash.ToLowerInvariant()
    if ($downloadSha -ne $modelSha) { throw "Le SHA du téléchargement S3 ne correspond pas." }
} finally {
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
}

$report = [ordered]@{
    status = "candidate-published"
    timestamp_utc = [DateTimeOffset]::UtcNow.ToString("o")
    kfp_run_id = [string]$evidence.kfp.run_id
    mlflow_run_id = [string]$evidence.mlflow.run_id
    registry_name = [string]$evidence.mlflow.registry_name
    registry_version = [string]$evidence.mlflow.registry_version
    registry_alias = "candidate"
    git_sha = [string]$evidence.git_sha
    dataset_sha256 = [string]$evidence.dataset_sha256
    model_sha256 = $modelSha
    s3_bucket = $Bucket
    s3_model_key = $modelKey
    s3_model_version_id = $modelVersion
    s3_manifest_key = $manifestKey
    s3_manifest_version_id = $manifestVersion
    downloaded_sha256 = $downloadSha
    production_changed = $false
}
if (-not $ReportPath) { $ReportPath = Join-Path $repoRoot "artifacts\s3-candidate-report.json" }
$reportParent = Split-Path -Parent $ReportPath
if ($reportParent -and -not (Test-Path -LiteralPath $reportParent)) {
    New-Item -ItemType Directory -Force -Path $reportParent | Out-Null
}
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReportPath -Encoding utf8

Write-Host "S3_CANDIDATE_KEY=$modelKey"
Write-Host "S3_MODEL_VERSION_ID=$modelVersion"
Write-Host "S3_MANIFEST_VERSION_ID=$manifestVersion"
Write-Host "MODEL_SHA256=$modelSha"
Write-Host "REPORT_PATH=$ReportPath"
Write-Host "S3_CANDIDATE_PUBLISHED"
