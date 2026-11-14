[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$VersionId,
    [string]$Bucket = "mini-crm-models-251538491265-eu-north-1",
    [string]$Key = "models/model.joblib",
    [string]$ExpectedSha256 = "",
    [string]$LocalPath = "",
    [string]$Profile = "mini-crm",
    [string]$Region = "eu-north-1"
)

$ErrorActionPreference = "Stop"
$aws = (Get-Command aws -ErrorAction SilentlyContinue).Source
if (-not $aws -and (Test-Path "C:\Program Files\Amazon\AWSCLIV2\aws.exe")) { $aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe" }
if (-not $aws) { throw "AWS CLI introuvable." }
$head = & $aws s3api head-object --profile $Profile --region $Region --bucket $Bucket --key $Key --version-id $VersionId --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Version S3 introuvable." }
$remoteSha = $head.Metadata.sha256
if ($ExpectedSha256 -and $remoteSha -ne $ExpectedSha256.ToLowerInvariant()) { throw "SHA-256 distant inattendu." }
if ($LocalPath) {
    $localSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $LocalPath).Hash.ToLowerInvariant()
    if ($remoteSha -and $localSha -ne $remoteSha) { throw "SHA-256 local/distant différent." }
    Write-Host "LOCAL_SHA256=$localSha"
}
Write-Host "VERSION_ID=$VersionId"
Write-Host "REMOTE_SHA256=$remoteSha"
