[CmdletBinding()]
param(
    [string]$Profile = "mini-crm",
    [string]$Region = "eu-north-1"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $repoRoot

function Resolve-Executable([string]$Name, [string[]]$Fallbacks = @()) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($candidate in $Fallbacks) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

$terraform = Resolve-Executable "terraform"
$gh = Resolve-Executable "gh"
$aws = Resolve-Executable "aws" @("C:\Program Files\Amazon\AWSCLIV2\aws.exe")
$docker = Resolve-Executable "docker" @("C:\Program Files\Docker\Docker\resources\bin\docker.exe")

Write-Host "Repository: $repoRoot"
$branch = (git branch --show-current).Trim()
Write-Host "Branch: $branch"
Write-Host "Commit: $(git rev-parse HEAD)"
Write-Host "Remote branch: $(git ls-remote origin "refs/heads/$branch")"
Write-Host "Terraform: $(if ($terraform) { $terraform } else { 'NOT FOUND' })"
Write-Host "GitHub CLI: $(if ($gh) { $gh } else { 'NOT FOUND' })"
Write-Host "AWS CLI: $(if ($aws) { $aws } else { 'NOT FOUND' })"
Write-Host "Docker CLI: $(if ($docker) { $docker } else { 'NOT FOUND (use the Linux VM for build)' })"

if (-not $aws) {
    throw "AWS CLI introuvable. Installez AWS CLI v2 ou ouvrez un terminal avec C:\Program Files\Amazon\AWSCLIV2 dans le PATH."
}

& $aws sts get-caller-identity --profile $Profile --output json
if ($LASTEXITCODE -ne 0) { throw "Le profil AWS '$Profile' n'est pas authentifié." }

terraform -chdir=infra/aws init -backend=false -input=false
terraform -chdir=infra/aws validate
if ($LASTEXITCODE -ne 0) { throw "Validation Terraform échouée." }

$state = Join-Path $repoRoot "infra\aws\terraform.tfstate"
if (Test-Path -LiteralPath $state) {
    Write-Warning "Un state local existe : ne pas l'écraser; vérifier son origine avant toute utilisation."
} else {
    Write-Host "Aucun state local présent (aucun state inventé ou restauré automatiquement)."
}

Write-Host "Environnement vérifié. Aucun apply/destroy n'a été exécuté."
