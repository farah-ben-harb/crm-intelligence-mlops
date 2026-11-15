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
    [string]$ModelSource = "",
    [string]$LockPath = "/opt/mini-crm/deployments/.production-release.lock",
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
if (-not $ModelSource) { $ModelSource = "s3://$bucket/models/model.joblib" }
if ($ModelSource -notmatch '^s3://([^/]+)/(.+)$') { throw "ModelSource doit être une URI s3:// valide." }
$sourceBucket = $Matches[1]
$sourceKey = $Matches[2]
if ($sourceBucket -ne $bucket) { throw "Le bucket du modèle ne correspond pas au compte/région attendus." }
& $aws s3api head-object --profile $Profile --region $Region --bucket $sourceBucket --key $sourceKey --version-id $ModelVersion --output json | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Version S3 introuvable : $ModelVersion" }

if ($UseCloudWatchLogs) {
    $group = (& $aws logs describe-log-groups --profile $Profile --region $Region --log-group-name-prefix $LogGroupName --query "logGroups[?logGroupName=='$LogGroupName'].logGroupName" --output text | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $group -or $group -ne $LogGroupName) { throw "Le Log Group $LogGroupName n'existe pas encore. Valider Terraform avant d'utiliser awslogs." }
}

$logArgs = if ($UseCloudWatchLogs) {
    $stream = "production-release-$(Get-Date -Format yyyyMMdd-HHmmss)"
    "--log-driver awslogs --log-opt awslogs-region=$Region --log-opt awslogs-group=$LogGroupName --log-opt awslogs-stream=$stream --log-opt awslogs-create-group=false"
} else { "" }
$sanitizeBackup = @'
python3 - "$backup_dir/production.inspect.sanitized.json" <<'PY'
import json
import subprocess
import sys

obj = json.loads(subprocess.check_output(["docker", "inspect", "mini-crm-api"], text=True))[0]
env = {}
for item in obj.get("Config", {}).get("Env") or []:
    key, _, value = item.partition("=")
    upper = key.upper()
    if any(token in upper for token in ("SECRET", "TOKEN", "PASSWORD", "PRIVATE_KEY", "ACCESS_KEY")):
        env[key] = "<redacted>"
    else:
        env[key] = value

safe = {
    "name": obj.get("Name"),
    "image": obj.get("Config", {}).get("Image"),
    "state": obj.get("State", {}).get("Status"),
    "environment": env,
    "mounts": obj.get("Mounts", []),
    "ports": obj.get("HostConfig", {}).get("PortBindings", {}),
    "restart_policy": obj.get("HostConfig", {}).get("RestartPolicy", {}),
    "log_config": obj.get("HostConfig", {}).get("LogConfig", {}),
    "network_mode": obj.get("HostConfig", {}).get("NetworkMode"),
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(safe, handle, indent=2)
PY
chmod 600 "$backup_dir/production.inspect.sanitized.json"
'@
$runCommand = 'docker run -d --name mini-crm-api -p 127.0.0.1:8002:8000 -v "${MODEL_PATH}:/app/models/model.joblib:ro" -e MINI_CRM_MODEL_PATH=/app/models/model.joblib -e MINI_CRM_MODEL_SOURCE="${MODEL_SOURCE}" -e MINI_CRM_MODEL_VERSION="${MODEL_VERSION}" -e MINI_CRM_MODEL_SHA256="${MODEL_SHA}" ${LOG_ARGS} "${IMAGE}"'
$commands = @(
    "set -euo pipefail",
    ("LOCK_PATH='{0}'" -f $LockPath),
    'mkdir "$LOCK_PATH"',
    'cleanup_lock() { rmdir "$LOCK_PATH" 2>/dev/null || true; }',
    'trap cleanup_lock EXIT',
    ("IMAGE='{0}'" -f $Image),
    ("MODEL_PATH='{0}'" -f $ModelPath),
    ("MODEL_SOURCE='{0}'" -f $ModelSource),
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
    $sanitizeBackup,
    'previous_image=$(docker inspect --format ''{{.Config.Image}}'' mini-crm-api)',
    'previous_model=$(docker inspect --format ''{{range .Mounts}}{{if eq .Destination "/app/models/model.joblib"}}{{.Source}}{{end}}{{end}}'' mini-crm-api)',
    'printf ''IMAGE=%s\nMODEL=%s\nMODEL_SOURCE=%s\n'' "$previous_image" "$previous_model" "$(docker inspect --format ''{{range .Config.Env}}{{println .}}{{end}}'' mini-crm-api | grep -E ''^MINI_CRM_MODEL_(SOURCE|VERSION|SHA256)='' | tr ''\n'' '' '')" > "$backup_dir/rollback.env"',
    'backup_container=mini-crm-api-rollback-$(date +%Y%m%d-%H%M%S); DEPLOY_SUCCESS=0',
    'rollback_on_exit() { rc=$?; trap - EXIT; if [ "$DEPLOY_SUCCESS" -eq 1 ]; then rmdir "$LOCK_PATH" 2>/dev/null || true; exit "$rc"; fi; set +e; restore_ok=0; if docker inspect "$backup_container" >/dev/null 2>&1; then docker rm -f mini-crm-api >/dev/null 2>&1 || true; if docker rename "$backup_container" mini-crm-api >/dev/null 2>&1 && docker start mini-crm-api >/dev/null 2>&1; then sleep 5; curl -fsS http://127.0.0.1:8002/health >/dev/null && curl -fsS http://127.0.0.1:8002/ready >/dev/null && curl -fsS http://127.0.0.1:8002/model-info >/dev/null && curl -fsS -X POST -H ''Content-Type: application/json'' -d ''{"skills":"Python Docker Terraform"}'' http://127.0.0.1:8002/predict >/dev/null && restore_ok=1; fi; else curl -fsS http://127.0.0.1:8002/health >/dev/null && restore_ok=1; fi; rmdir "$LOCK_PATH" 2>/dev/null || true; if [ "$restore_ok" -ne 1 ]; then echo ''ROLLBACK_FAILED''; exit 90; fi; echo ''ROLLBACK_SUCCESS''; exit "$rc"; }',
    'trap rollback_on_exit EXIT',
    'docker rename mini-crm-api "$backup_container"',
    'printf ''BACKUP_CONTAINER=%s\n'' "$backup_container" >> "$backup_dir/rollback.env"',
    'docker stop "$backup_container" >/dev/null',
    "docker rm -f mini-crm-api >/dev/null 2>&1 || true",
    $runCommand,
    "sleep 5",
    'curl -fsS http://127.0.0.1:8002/health',
    'curl -fsS http://127.0.0.1:8002/ready',
    'curl -fsS http://127.0.0.1:8002/model-info',
    'curl -fsS -X POST -H ''Content-Type: application/json'' -d ''{"skills":"Python Docker Terraform"}'' http://127.0.0.1:8002/predict',
    'docker inspect mini-crm-api --format ''IMAGE={{.Config.Image}}''',
    'DEPLOY_SUCCESS=1',
    'echo "BACKUP_DIR=$backup_dir"',
    'echo "BACKUP_CONTAINER=$backup_container"'
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
