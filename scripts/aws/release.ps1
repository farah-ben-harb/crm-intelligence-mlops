[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('@sha256:[0-9a-f]{64}$')][string]$Image,
    [Parameter(Mandatory=$true)][ValidatePattern('^candidates/[0-9a-f]{40}/model\.joblib$')][string]$ModelKey,
    [Parameter(Mandatory=$true)][string]$ModelVersion,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ModelSha256,
    [Parameter(Mandatory=$true)][string]$ManifestPath,
    [string]$InstanceId = "i-049bfd217926eb2b2",
    [string]$Profile = "mini-crm",
    [string]$Region = "eu-north-1",
    [string]$LogGroupName = "/mini-crm/api",
    [string]$ReportPath = "",
    [switch]$WhatIf,
    [switch]$Promote,
    [switch]$ApproveProduction
)

$ErrorActionPreference = "Stop"
if ($Promote -and -not $ApproveProduction) {
    throw "La promotion production exige -ApproveProduction explicite."
}

$aws = (Get-Command aws -ErrorAction SilentlyContinue).Source
if (-not $aws -and (Test-Path "C:\Program Files\Amazon\AWSCLIV2\aws.exe")) {
    $aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
}
if (-not $aws) { throw "AWS CLI introuvable." }

$Account = "251538491265"
$Repository = "mini-crm-api"
$Bucket = "mini-crm-models-$Account-$Region"
$Registry = "$Account.dkr.ecr.$Region.amazonaws.com"
$ModelSource = "s3://$Bucket/$ModelKey"
$ModelPath = "/opt/mini-crm/models/candidates/$ModelSha256.joblib"

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Manifest introuvable : $ManifestPath"
}
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if (-not $Manifest.quality_gate.passed) { throw "Quality gate du manifeste négative." }
if ($Manifest.model.sha256 -ne $ModelSha256.ToLowerInvariant()) {
    throw "Le SHA du manifeste ne correspond pas au candidat."
}
if ($ModelKey -notmatch [regex]::Escape([string]$Manifest.git_sha)) {
    throw "La clé S3 candidate ne correspond pas au Git SHA du manifeste."
}

$identity = (& $aws sts get-caller-identity --profile $Profile --region $Region --output json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0 -or $identity.Account -ne $Account) {
    throw "Compte AWS incorrect ou session expirée."
}

$parts = $Image -split '@', 2
$repository = $parts[0].Substring($parts[0].LastIndexOf('/') + 1)
$digest = $parts[1]
$foundDigest = (& $aws ecr describe-images --profile $Profile --region $Region --registry-id $Account --repository-name $repository --image-ids "imageDigest=$digest" --query 'imageDetails[0].imageDigest' --output text | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $foundDigest -ne $digest) { throw "Digest ECR non vérifié." }

$head = (& $aws s3api head-object --profile $Profile --region $Region --bucket $Bucket --key $ModelKey --version-id $ModelVersion --output json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0 -or $head.Metadata.sha256 -ne $ModelSha256.ToLowerInvariant()) {
    throw "Candidat S3 absent ou SHA distant incorrect."
}

$report = [ordered]@{
    timestamp_utc = [DateTimeOffset]::UtcNow.ToString("o")
    status = "preflight-validated"
    image = $Image
    model_key = $ModelKey
    model_version = $ModelVersion
    model_sha256 = $ModelSha256.ToLowerInvariant()
    manifest_git_sha = [string]$Manifest.git_sha
    quality_gate = $true
    production_promotion = "not-executed"
    production_unchanged = $true
}

function Write-ReleaseReport {
    $path = $ReportPath
    if (-not $path) { $path = Join-Path $env:TEMP ("mini-crm-release-$([guid]::NewGuid().ToString('N')).json") }
    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8
    Write-Host "RELEASE_REPORT=$path"
}

if ($WhatIf) {
    Write-Host "RELEASE_PREFLIGHT_OK"
    Write-Host "IMAGE=$Image"
    Write-Host "MODEL_SOURCE=$ModelSource"
    Write-Host "MODEL_PATH=$ModelPath"
    Write-ReleaseReport
    return
}

$downloadBash = @(
    "set -euo pipefail",
    'mkdir -p "/opt/mini-crm/models/candidates"',
    "aws s3api get-object --region '$Region' --bucket '$Bucket' --key '$ModelKey' --version-id '$ModelVersion' '$ModelPath' >/dev/null",
    "echo '$ModelSha256  $ModelPath' | sha256sum -c -",
    "echo CANDIDATE_ARTIFACT_OK"
) -join "`n"
$payload = @{ DocumentName = "AWS-RunShellScript"; InstanceIds = @($InstanceId); Parameters = @{ commands = @($downloadBash) }; TimeoutSeconds = 180 } | ConvertTo-Json -Depth 8
$payloadPath = Join-Path $env:TEMP "mini-crm-release-download.json"
[System.IO.File]::WriteAllText($payloadPath, $payload, [System.Text.UTF8Encoding]::new($false))
$downloadId = (& $aws ssm send-command --profile $Profile --region $Region --cli-input-json "file://$payloadPath" --query Command.CommandId --output text).Trim()
if ($LASTEXITCODE -ne 0 -or -not $downloadId) { throw "Téléchargement SSM non envoyé." }
& $aws ssm wait command-executed --profile $Profile --region $Region --command-id $downloadId --instance-id $InstanceId
$downloadResult = (& $aws ssm get-command-invocation --profile $Profile --region $Region --command-id $downloadId --instance-id $InstanceId --output json | ConvertFrom-Json)
if ($downloadResult.Status -ne "Success" -or $downloadResult.StandardOutputContent -notmatch "CANDIDATE_ARTIFACT_OK") {
    Write-Host $downloadResult.StandardErrorContent
    throw "Artefact candidate non vérifié sur EC2."
}
$report.download_command_id = $downloadId

$canaryOutput = @(& (Join-Path $PSScriptRoot "deploy-canary.ps1") -Image $Image -ModelPath $ModelPath -ModelVersion $ModelVersion -ModelSha256 $ModelSha256 -ModelSource $ModelSource -InstanceId $InstanceId -Profile $Profile -Region $Region)
$canaryLine = $canaryOutput | Where-Object { $_ -match '^COMMAND_ID=' } | Select-Object -Last 1
if (-not $canaryLine) { throw "COMMAND_ID canary absent." }
$canaryId = $canaryLine -replace '^COMMAND_ID=', ''
$report.canary_command_id = $canaryId
& $aws ssm wait command-executed --profile $Profile --region $Region --command-id $canaryId --instance-id $InstanceId
$canaryResult = (& $aws ssm get-command-invocation --profile $Profile --region $Region --command-id $canaryId --instance-id $InstanceId --output json | ConvertFrom-Json)
if ($canaryResult.Status -ne "Success" -or $canaryResult.StandardOutputContent -notmatch [regex]::Escape($ModelVersion) -or $canaryResult.StandardOutputContent -notmatch [regex]::Escape($ModelSha256)) {
    Write-Host $canaryResult.StandardErrorContent
    throw "Canary candidate non validé."
}

$group = (& $aws logs describe-log-groups --profile $Profile --region $Region --log-group-name-prefix $LogGroupName --query "logGroups[?logGroupName=='$LogGroupName'].logGroupName" --output text | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $group -ne $LogGroupName) { throw "Log Group CloudWatch absent." }
$start = [DateTimeOffset]::UtcNow.AddMinutes(-15).ToUnixTimeMilliseconds()
$eventText = (& $aws logs filter-log-events --profile $Profile --region $Region --log-group-name $LogGroupName --start-time $start --query "length(events)" --output text | Out-String).Trim()
$eventCounts = @($eventText -split '\s+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
$events = if ($eventCounts.Count) { ($eventCounts | Measure-Object -Sum).Sum } else { 0 }
if ($events -eq 0) { throw "Aucun événement CloudWatch récent confirmé." }
$report.cloudwatch_events = $events
$report.status = "canary-validated"

if ($Promote) {
    $promotionOutput = @(& (Join-Path $PSScriptRoot "promote-production.ps1") -Image $Image -ModelPath $ModelPath -ModelVersion $ModelVersion -ModelSha256 $ModelSha256 -ModelSource $ModelSource -InstanceId $InstanceId -Profile $Profile -Region $Region -UseCloudWatchLogs)
    $promotionLine = $promotionOutput | Where-Object { $_ -match '^COMMAND_ID=' } | Select-Object -Last 1
    if (-not $promotionLine) { throw "COMMAND_ID promotion absent." }
    $promotionId = $promotionLine -replace '^COMMAND_ID=', ''
    $report.promotion_command_id = $promotionId
    & $aws ssm wait command-executed --profile $Profile --region $Region --command-id $promotionId --instance-id $InstanceId
    $promotionResult = (& $aws ssm get-command-invocation --profile $Profile --region $Region --command-id $promotionId --instance-id $InstanceId --output json | ConvertFrom-Json)
    if ($promotionResult.Status -ne "Success") { Write-Host $promotionResult.StandardErrorContent; throw "Promotion production échouée." }
    $report.status = "production-promoted"
    $report.production_unchanged = $false
}

Write-ReleaseReport
Write-Host "RELEASE_GATE_VALIDATED"
