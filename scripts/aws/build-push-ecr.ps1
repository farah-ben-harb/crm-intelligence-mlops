[CmdletBinding()]
param(
    [string]$Profile = "mini-crm",
    [string]$Region = "eu-north-1",
    [string]$RepositoryName = "mini-crm-api",
    [string]$Tag = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $repoRoot
$aws = (Get-Command aws -ErrorAction SilentlyContinue).Source
if (-not $aws -and (Test-Path "C:\Program Files\Amazon\AWSCLIV2\aws.exe")) { $aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe" }
if (-not $aws) { throw "AWS CLI introuvable." }
$docker = (Get-Command docker -ErrorAction SilentlyContinue).Source
if (-not $docker) { throw "Docker CLI introuvable sur Windows. Exécutez ce script depuis une VM Linux avec Docker ou installez Docker Desktop." }

if (-not $Tag) { $Tag = (git rev-parse HEAD).Trim() }
if ($Tag -notmatch '^[0-9a-f]{40}$') { throw "Le tag doit être le SHA Git complet (40 caractères). Tag reçu: $Tag" }
$account = (& $aws sts get-caller-identity --profile $Profile --query Account --output text).Trim()
if ($LASTEXITCODE -ne 0 -or -not $account) { throw "Impossible de vérifier l'identité AWS." }
$registry = "$account.dkr.ecr.$Region.amazonaws.com"
$image = "$registry/$RepositoryName`:$Tag"

& $docker build --platform linux/amd64 -t $image .
if ($LASTEXITCODE -ne 0) { throw "Build Docker échoué." }
& $docker run --rm --entrypoint python $image -c "from app.main import app; assert any(r.path == '/model-info' for r in app.routes); print('MODEL-INFO PRESENT')"
if ($LASTEXITCODE -ne 0) { throw "L'image ne contient pas /model-info." }

& $aws ecr get-login-password --profile $Profile --region $Region | & $docker login --username AWS --password-stdin $registry
if ($LASTEXITCODE -ne 0) { throw "Connexion ECR échouée." }

$existing = (& $aws ecr describe-images --profile $Profile --region $Region --repository-name $RepositoryName --image-ids "imageTag=$Tag" --query "imageDetails[0].imageDigest" --output text 2>$null).Trim()
if ($LASTEXITCODE -eq 0 -and $existing -and $existing -ne "None") {
    Write-Host "Tag immuable déjà présent : $existing"
} else {
    & $docker push $image
    if ($LASTEXITCODE -ne 0) { throw "Push ECR échoué." }
    $existing = (& $aws ecr describe-images --profile $Profile --region $Region --repository-name $RepositoryName --image-ids "imageTag=$Tag" --query "imageDetails[0].imageDigest" --output text).Trim()
}

& $docker logout $registry | Out-Null
Write-Host "IMAGE=$image"
Write-Host "DIGEST=$existing"
