[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ModelPath,
    [string]$Bucket = "mini-crm-models-251538491265-eu-north-1",
    [string]$Key = "models/model.joblib",
    [string]$Profile = "mini-crm",
    [string]$Region = "eu-north-1",
    [switch]$AllowNewVersion
)

$ErrorActionPreference = "Stop"
if (-not $AllowNewVersion) { throw "Publier un modèle exige -AllowNewVersion ; la version S3 de production ne sera jamais écrasée." }
if (-not (Test-Path -LiteralPath $ModelPath -PathType Leaf)) { throw "Artefact introuvable : $ModelPath" }
$aws = (Get-Command aws -ErrorAction SilentlyContinue).Source
if (-not $aws -and (Test-Path "C:\Program Files\Amazon\AWSCLIV2\aws.exe")) { $aws = "C:\Program Files\Amazon\AWSCLIV2\aws.exe" }
if (-not $aws) { throw "AWS CLI introuvable." }
$sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $ModelPath).Hash.ToLowerInvariant()
$result = & $aws s3api put-object --profile $Profile --region $Region --bucket $Bucket --key $Key --body $ModelPath --metadata "sha256=$sha" --output json
if ($LASTEXITCODE -ne 0) { throw "Publication S3 échouée." }
$version = ($result | ConvertFrom-Json).VersionId
if (-not $version) { throw "S3 n'a pas retourné de VersionId ; vérifier que le bucket est versionné." }
$head = & $aws s3api head-object --profile $Profile --region $Region --bucket $Bucket --key $Key --version-id $version --output json | ConvertFrom-Json
if ($head.Metadata.sha256 -ne $sha) { throw "La métadonnée SHA-256 S3 ne correspond pas." }
Write-Host "S3_URI=s3://$Bucket/$Key"
Write-Host "VERSION_ID=$version"
Write-Host "SHA256=$sha"
