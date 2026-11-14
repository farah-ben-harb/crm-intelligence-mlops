[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Image,
    [Parameter(Mandatory=$true)][string]$ModelPath,
    [Parameter(Mandatory=$true)][string]$ModelVersion,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ModelSha256,
    [string]$InstanceId = "i-049bfd217926eb2b2",
    [string]$Profile = "mini-crm",
    [string]$Region = "eu-north-1"
)

$ErrorActionPreference = "Stop"
$aws = (Get-Command aws -ErrorAction SilentlyContinue).Source
if (-not $aws -and (Test-Path "C:\Program Files\Amazon\AWSCLIV2\aws.exe")) { $aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe" }
if (-not $aws) { throw "AWS CLI introuvable." }

$commands = @(
    "set -euo pipefail",
    "echo 'Inspecting existing canary'",
    "docker ps -a --filter name=mini-crm-api-v2-canary --format '{{.ID}} {{.Status}}' || true",
    ("test -r '{0}'" -f $ModelPath),
    ("echo '{0}  {1}' | sha256sum -c -" -f $ModelSha256, $ModelPath),
    ("docker pull '{0}'" -f $Image),
    "docker rm -f mini-crm-api-v2-canary 2>/dev/null || true",
    ("docker run -d --name mini-crm-api-v2-canary -p 127.0.0.1:8004:8000 -v '{0}:/models/model.joblib:ro' -e MINI_CRM_MODEL_PATH=/models/model.joblib -e MINI_CRM_MODEL_SOURCE=s3://mini-crm-models/models/model.joblib -e MINI_CRM_MODEL_VERSION='{1}' -e MINI_CRM_MODEL_SHA256='{2}' '{3}'" -f $ModelPath, $ModelVersion, $ModelSha256, $Image),
    'for i in $(seq 1 30); do curl -fsS http://127.0.0.1:8004/ready >/dev/null && break || sleep 2; done',
    'curl -fsS http://127.0.0.1:8004/health',
    'curl -fsS http://127.0.0.1:8004/ready',
    'curl -fsS http://127.0.0.1:8004/model-info',
    'curl -fsS -X POST -H ''Content-Type: application/json'' -d ''{"skills":"Python Docker Terraform"}'' http://127.0.0.1:8004/predict',
    'curl -fsS http://127.0.0.1:8002/health',
    'curl -fsS http://127.0.0.1:8002/ready',
    "docker ps --filter name=mini-crm-api-v2-canary --format '{{.Names}} {{.Status}}'"
)
$parameterJson = @{ commands = $commands } | ConvertTo-Json -Compress
$result = & $aws ssm send-command --profile $Profile --region $Region --instance-ids $InstanceId --document-name AWS-RunShellScript --comment "Mini CRM immutable ECR canary" --parameters $parameterJson --output json
if ($LASTEXITCODE -ne 0) { throw "SSM send-command échoué." }
$commandId = (($result | ConvertFrom-Json).Command.CommandId).ToString()
Write-Host "COMMAND_ID=$commandId"
Write-Host "Consultez le statut avec : aws ssm get-command-invocation --command-id $commandId --instance-id $InstanceId --profile $Profile --region $Region"
