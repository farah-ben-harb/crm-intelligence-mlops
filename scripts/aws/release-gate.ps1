[CmdletBinding()]
param(
    [string]$Profile = "mini-crm",
    [string]$Region = "eu-north-1"
)

$ErrorActionPreference = "Stop"

$Account = "251538491265"
$Instance = "i-049bfd217926eb2b2"
$Registry = "$Account.dkr.ecr.$Region.amazonaws.com"
$Repository = "mini-crm-api"
$Digest = "sha256:b84ca59f9aa5aa9800d3c4c7075a9e075fa6d21fa8b37daf1aae8d5079ee57cc"
$Image = "$Registry/$Repository@$Digest"

$Version = "RNpfkR7F9N1cdIgR6w2YS2K4G07QnvDz"
$Sha = "2e78ebc2c60209baaa9b3065ae59e9d92bd06dfdcb2672d18344d0642735e083"
$Bucket = "mini-crm-models-$Account-$Region"
$Group = "/mini-crm/api"

Write-Host "=== AWS IDENTITY ==="

$Current = (& aws sts get-caller-identity `
    --profile $Profile --query Account --output text).Trim()

if ($LASTEXITCODE -ne 0 -or $Current -ne $Account) {
    throw "Compte AWS incorrect."
}

Write-Host "=== ECR IMMUTABLE IMAGE ==="

$FoundDigest = (& aws ecr describe-images `
    --repository-name $Repository `
    --image-ids "imageDigest=$Digest" `
    --profile $Profile --region $Region `
    --query "imageDetails[0].imageDigest" `
    --output text).Trim()

if ($LASTEXITCODE -ne 0 -or $FoundDigest -ne $Digest) {
    throw "Image ECR non verifiee."
}

Write-Host "=== S3 MODEL VERSION ==="

$FoundVersion = (& aws s3api head-object `
    --bucket $Bucket `
    --key "models/model.joblib" `
    --version-id $Version `
    --profile $Profile --region $Region `
    --query VersionId --output text).Trim()

if ($LASTEXITCODE -ne 0 -or $FoundVersion -ne $Version) {
    throw "Version S3 non verifiee."
}

Write-Host "=== CLOUDWATCH GROUP ==="

$GroupsJson = & aws logs describe-log-groups `
    --log-group-name-prefix $Group `
    --profile $Profile --region $Region --output json

if ($LASTEXITCODE -ne 0) { throw "CloudWatch inaccessible." }

$Groups = ($GroupsJson | ConvertFrom-Json).logGroups
$LogGroup = @($Groups | Where-Object {
    $_.logGroupName -eq $Group
})

if ($LogGroup.Count -ne 1 -or
    $LogGroup[0].retentionInDays -ne 7) {
    throw "Log Group ou retention incorrecte."
}

Write-Host "=== EC2 RUNTIME CHECK ==="

$Bash = @'
set -euo pipefail

IMAGE="__IMAGE__"
VERSION="__VERSION__"
SHA="__SHA__"
MODEL="/opt/mini-crm/models/${VERSION}.joblib"

echo "$SHA  $MODEL" | sha256sum -c -

for pair in "mini-crm-api:8002" "mini-crm-api-v2-canary:8004"; do
    NAME="${pair%:*}"
    PORT="${pair##*:}"

    echo "=== VERIFY $NAME ==="

    test "$(docker inspect -f '{{.State.Running}}' "$NAME")" = true
    test "$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$NAME")" = awslogs

    IMAGE_ID=$(docker inspect -f '{{.Image}}' "$NAME")
    docker image inspect -f '{{json .RepoDigests}}' "$IMAGE_ID" |
        grep -F "$IMAGE" >/dev/null

    docker inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' "$NAME" |
        grep -Fx "$MODEL" >/dev/null

    curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null
    curl -fsS "http://127.0.0.1:${PORT}/ready" >/dev/null

    curl -fsS "http://127.0.0.1:${PORT}/model-info" |
      python3 -c '
import json,sys
data=json.load(sys.stdin)
assert data["version_id"] == "__VERSION__"
assert data["sha256"] == "__SHA__"
'

    curl -fsS -X POST \
      "http://127.0.0.1:${PORT}/predict" \
      -H "Content-Type: application/json" \
      -d '{"skills":"Python Docker Linux"}' |
      python3 -c '
import json,sys
assert "domain" in json.load(sys.stdin)
'

    echo "PASS $NAME"
done

echo "RELEASE_GATE_PASS"
'@

$Bash = $Bash.Replace("__IMAGE__", $Image).
    Replace("__VERSION__", $Version).
    Replace("__SHA__", $Sha)

$Payload = @{
    DocumentName = "AWS-RunShellScript"
    InstanceIds = @($Instance)
    Parameters = @{ commands = @($Bash) }
    TimeoutSeconds = 180
} | ConvertTo-Json -Depth 8

$Path = Join-Path $env:TEMP "mini-crm-release-gate.json"

[System.IO.File]::WriteAllText(
    $Path, $Payload, [System.Text.UTF8Encoding]::new($false)
)

$CommandId = (& aws ssm send-command `
    --cli-input-json "file://$Path" `
    --profile $Profile --region $Region `
    --query Command.CommandId --output text).Trim()

if ($LASTEXITCODE -ne 0 -or !$CommandId) {
    throw "SSM send-command echoue."
}

Write-Host "SSM COMMAND ID: $CommandId"

aws ssm wait command-executed `
    --command-id $CommandId --instance-id $Instance `
    --profile $Profile --region $Region

$ResultJson = & aws ssm get-command-invocation `
    --command-id $CommandId --instance-id $Instance `
    --profile $Profile --region $Region --output json

if ($LASTEXITCODE -ne 0) {
    throw "Lecture du resultat SSM echouee."
}

$Result = $ResultJson | ConvertFrom-Json
Write-Host $Result.StandardOutputContent

if ($Result.Status -ne "Success" -or
    $Result.StandardOutputContent -notmatch "RELEASE_GATE_PASS") {
    Write-Host $Result.StandardErrorContent
    throw "Release Gate refuse. Aucune production modifiee."
}

Write-Host "=== CLOUDWATCH EVENTS ==="

$Start = [DateTimeOffset]::UtcNow.AddMinutes(-30).ToUnixTimeMilliseconds()

$EventsText = (& aws logs filter-log-events `
    --log-group-name $Group `
    --start-time $Start `
    --profile $Profile --region $Region `
    --query "length(events)" --output text | Out-String).Trim()

if ($LASTEXITCODE -ne 0 -or !$EventsText) {
    throw "Aucun evenement CloudWatch recent confirme."
}

$EventCounts = @(
    $EventsText -split '\s+' |
        Where-Object { $_ -match '^\d+$' } |
        ForEach-Object { [int]$_ }
)
$Events = if ($EventCounts.Count -gt 0) {
    ($EventCounts | Measure-Object -Sum).Sum
} else {
    0
}

if ($Events -eq 0) {
    throw "Aucun evenement CloudWatch recent confirme."
}

Write-Host "CLOUDWATCH_EVENTS=$Events"
Write-Host "RELEASE GATE VALIDATED"
