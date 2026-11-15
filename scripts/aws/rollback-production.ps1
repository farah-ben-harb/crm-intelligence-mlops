[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PreviousImage,
    [Parameter(Mandatory=$true)][string]$ModelPath,
    [string]$ModelVersion = "",
    [string]$ModelSha256 = "",
    [string]$InstanceId = "i-049bfd217926eb2b2",
    [string]$Profile = "mini-crm",
    [string]$Region = "eu-north-1",
    [switch]$UseCloudWatchLogs = $true,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$aws = (Get-Command aws -ErrorAction SilentlyContinue).Source
if (-not $aws -and (Test-Path "C:\Program Files\Amazon\AWSCLIV2\aws.exe")) { $aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe" }
if (-not $aws) { throw "AWS CLI introuvable." }
if ($PreviousImage -notmatch '@sha256:[0-9a-f]{64}$') { throw "Le rollback exige une image ECR par digest." }
if ($ModelSha256 -and $ModelSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "SHA-256 du modèle invalide." }

$envArgs = "-e MINI_CRM_MODEL_PATH=/app/models/model.joblib"
if ($ModelVersion) { $envArgs += " -e MINI_CRM_MODEL_VERSION='$ModelVersion'" }
if ($ModelSha256) { $envArgs += " -e MINI_CRM_MODEL_SHA256='$ModelSha256'" }
$checksumCommand = if ($ModelSha256) { "echo '$ModelSha256  $ModelPath' | sha256sum -c -" } else { "echo 'Model SHA non fourni : rollback vers la configuration historique.'" }
$logArgs = if ($UseCloudWatchLogs) {
    $stream = "rollback-$(Get-Date -Format yyyyMMdd-HHmmss)"
    "--log-driver awslogs --log-opt awslogs-region=$Region --log-opt awslogs-group=/mini-crm/api --log-opt awslogs-stream=$stream --log-opt awslogs-create-group=false"
} else { "" }

$commands = @(
    "set -euo pipefail",
    ("IMAGE='{0}'" -f $PreviousImage),
    ("MODEL_PATH='{0}'" -f $ModelPath),
    ("ENV_ARGS='{0}'" -f $envArgs),
    ("LOG_ARGS='{0}'" -f $logArgs),
    'test -r "$MODEL_PATH"',
    $checksumCommand,
    'docker pull "$IMAGE"',
    'docker rm -f mini-crm-api 2>/dev/null || true',
    'docker run -d --name mini-crm-api -p 127.0.0.1:8002:8000 -v "${MODEL_PATH}:/app/models/model.joblib:ro" ${ENV_ARGS} ${LOG_ARGS} "${IMAGE}"',
    "sleep 5",
    'curl -fsS http://127.0.0.1:8002/health',
    'curl -fsS http://127.0.0.1:8002/ready',
    'curl -fsS http://127.0.0.1:8002/model-info',
    'curl -fsS -X POST -H ''Content-Type: application/json'' -d ''{"skills":"Python Docker Terraform"}'' http://127.0.0.1:8002/predict',
    'docker inspect mini-crm-api --format ''IMAGE={{.Config.Image}}'''
)
$params = @{ commands = $commands } | ConvertTo-Json -Compress
if ($WhatIf) {
    $commands | ForEach-Object { Write-Host $_ }
    return
}
$result = & $aws ssm send-command --profile $Profile --region $Region --instance-ids $InstanceId --document-name AWS-RunShellScript --comment "Mini CRM production rollback" --parameters $params --output json
if ($LASTEXITCODE -ne 0) { throw "SSM send-command échoué." }
$commandId = (($result | ConvertFrom-Json).Command.CommandId).ToString()
Write-Host "COMMAND_ID=$commandId"
Write-Host "Le rollback n'est considéré réussi qu'après statut Success et validation des quatre endpoints."
