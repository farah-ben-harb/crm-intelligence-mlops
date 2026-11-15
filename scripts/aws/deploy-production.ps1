[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('@sha256:[0-9a-f]{64}$')][string]$Image,
    [Parameter(Mandatory=$true)][string]$ModelPath,
    [Parameter(Mandatory=$true)][string]$ModelVersion,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ModelSha256,
    [string]$InstanceId = "i-049bfd217926eb2b2",
    [string]$Profile = "mini-crm",
    [string]$Region = "eu-north-1",
    [string]$LogGroupName = "/mini-crm/api",
    [switch]$UseCloudWatchLogs = $true,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$aws = (Get-Command aws -ErrorAction SilentlyContinue).Source
if (-not $aws -and (Test-Path "C:\Program Files\Amazon\AWSCLIV2\aws.exe")) { $aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe" }
if (-not $aws) { throw "AWS CLI introuvable." }

$identityJson = & $aws sts get-caller-identity --profile $Profile --output json
if ($LASTEXITCODE -ne 0) { throw "Session AWS expirée ou profil invalide." }
$identity = $identityJson | ConvertFrom-Json
if (-not $identity -or $identity.Account -ne "251538491265") { throw "Compte AWS inattendu." }

$parts = $Image -split '@', 2
$repository = $parts[0].Substring($parts[0].LastIndexOf('/') + 1)
$digest = $parts[1]
$account = $identity.Account
$ecr = (& $aws ecr describe-images --profile $Profile --region $Region --registry-id $account --repository-name $repository --image-ids "imageDigest=$digest" --query 'imageDetails[0].imageDigest' --output text | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $ecr -or $ecr -ne $digest) { throw "Digest ECR absent ou différent : $Image" }

$bucket = "mini-crm-models-$account-$Region"
& $aws s3api head-object --profile $Profile --region $Region --bucket $bucket --key models/model.joblib --version-id $ModelVersion --output json | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Version S3 introuvable : $ModelVersion" }

if ($UseCloudWatchLogs) {
    $group = (& $aws logs describe-log-groups --profile $Profile --region $Region --log-group-name-prefix $LogGroupName --query "logGroups[?logGroupName=='$LogGroupName'].logGroupName" --output text | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $group -or $group -ne $LogGroupName) { throw "Le Log Group $LogGroupName n'existe pas encore. Valider Terraform avant d'utiliser awslogs." }
}

$logArgs = if ($UseCloudWatchLogs) {
    $stream = "production-release-$(Get-Date -Format yyyyMMdd-HHmmss)"
    "--log-driver awslogs --log-opt awslogs-region=$Region --log-opt awslogs-group=$LogGroupName --log-opt awslogs-stream=$stream --log-opt awslogs-create-group=false"
} else { "" }
$runCommand = 'docker run -d --name mini-crm-api -p 127.0.0.1:8002:8000 -v "${MODEL_PATH}:/app/models/model.joblib:ro" -e MINI_CRM_MODEL_PATH=/app/models/model.joblib -e MINI_CRM_MODEL_SOURCE=s3://' + $bucket + '/models/model.joblib -e MINI_CRM_MODEL_VERSION="${MODEL_VERSION}" -e MINI_CRM_MODEL_SHA256="${MODEL_SHA}" ${LOG_ARGS} "${IMAGE}"'
$commands = @(
    "set -euo pipefail",
    ("IMAGE='{0}'" -f $Image),
    ("MODEL_PATH='{0}'" -f $ModelPath),
    ("MODEL_VERSION='{0}'" -f $ModelVersion),
    ("MODEL_SHA='{0}'" -f $ModelSha256),
    ("LOG_ARGS='{0}'" -f $logArgs),
    'test -r "$MODEL_PATH"',
    'echo "$MODEL_SHA  $MODEL_PATH" | sha256sum -c -',
    'curl -fsS http://127.0.0.1:8004/health >/dev/null',
    'curl -fsS http://127.0.0.1:8004/ready >/dev/null',
    ('info=$(curl -fsS http://127.0.0.1:8004/model-info); echo "$info" | grep -F ''"version_id":"{0}"'' >/dev/null; echo "$info" | grep -F ''"sha256":"{1}"'' >/dev/null' -f $ModelVersion, $ModelSha256),
    'curl -fsS -X POST -H ''Content-Type: application/json'' -d ''{"skills":"Python Docker Terraform"}'' http://127.0.0.1:8004/predict >/dev/null',
    'backup_dir=/opt/mini-crm/deployments/$(date +%Y%m%d-%H%M%S); mkdir -p "$backup_dir"',
    'docker inspect mini-crm-api > "$backup_dir/production.inspect.json"',
    'previous_image=$(docker inspect --format ''{{.Config.Image}}'' mini-crm-api)',
    'previous_model=$(docker inspect --format ''{{range .Mounts}}{{if eq .Destination "/app/models/model.joblib"}}{{.Source}}{{end}}{{end}}'' mini-crm-api)',
    'printf ''IMAGE=%s\nMODEL=%s\n'' "$previous_image" "$previous_model" > "$backup_dir/rollback.env"',
    'rollback() { if [ -n "$previous_image" ]; then docker rm -f mini-crm-api 2>/dev/null || true; docker run -d --name mini-crm-api -p 127.0.0.1:8002:8000 -v "${previous_model:-$MODEL_PATH}:/app/models/model.joblib:ro" -e MINI_CRM_MODEL_PATH=/app/models/model.joblib "$previous_image" || true; sleep 5; curl -fsS http://127.0.0.1:8002/health >/dev/null || true; curl -fsS http://127.0.0.1:8002/ready >/dev/null || true; fi; }',
    'trap ''rc=$?; if [ "$rc" -ne 0 ]; then rollback; fi; exit "$rc"'' EXIT',
    "docker rm -f mini-crm-api",
    $runCommand,
    "sleep 5",
    'curl -fsS http://127.0.0.1:8002/health',
    'curl -fsS http://127.0.0.1:8002/ready',
    'curl -fsS http://127.0.0.1:8002/model-info',
    'curl -fsS -X POST -H ''Content-Type: application/json'' -d ''{"skills":"Python Docker Terraform"}'' http://127.0.0.1:8002/predict',
    'docker inspect mini-crm-api --format ''IMAGE={{.Config.Image}}''',
    'echo "BACKUP_DIR=$backup_dir"'
)
$params = @{ commands = $commands } | ConvertTo-Json -Compress
if ($WhatIf) {
    $commands | ForEach-Object { Write-Host $_ }
    return
}
$result = & $aws ssm send-command --profile $Profile --region $Region --instance-ids $InstanceId --document-name AWS-RunShellScript --comment "Mini CRM production promotion" --parameters $params --output json
if ($LASTEXITCODE -ne 0) { throw "SSM send-command échoué." }
$commandId = (($result | ConvertFrom-Json).Command.CommandId).ToString()
Write-Host "COMMAND_ID=$commandId"
Write-Host "Promotion contrôlée envoyée. Vérifier le statut et conserver le backup distant avant toute suppression."
