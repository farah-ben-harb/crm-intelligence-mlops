# Déploiement AWS contrôlé

Cette procédure ne lance pas Terraform et ne modifie pas le conteneur de production `127.0.0.1:8002`. Elle publie une image immuable dans le dépôt ECR existant puis exécute un canary temporaire sur `127.0.0.1:8004` via SSM.

## Pré-requis

- Profil AWS CLI `mini-crm` authentifié, région `eu-north-1`.
- Accès au compte `251538491265`.
- Docker Linux disponible (la VM Linux peut être utilisée si Docker Desktop n'est pas installé).
- Aucun credential permanent dans le dépôt.

```powershell
.\scripts\aws\check-environment.ps1
```

Le fichier `infra/aws/terraform.tfstate` est volontairement ignoré par Git. S'il est absent, récupérer le state officiel depuis CloudShell ou le backend autorisé avant toute opération Terraform. Ne jamais en inventer un.

## Validation et publication ECR

```powershell
git switch feat/aws-terraform
git pull --ff-only
pytest -q
python -m ruff check .
.\scripts\aws\build-push-ecr.ps1
```

Le tag par défaut est le SHA Git complet. Le script refuse de remplacer un tag existant et affiche le digest ECR.

## Canary SSM

Utiliser la version S3 et le SHA-256 vérifiés du modèle :

```powershell
.\scripts\aws\deploy-canary.ps1 `
  -Image "251538491265.dkr.ecr.eu-north-1.amazonaws.com/mini-crm-api:<commit-sha>" `
  -ModelPath "/opt/mini-crm/models/RNpfkR7F9N1cdIgR6w2YS2K4G07QnvDz.joblib" `
  -ModelVersion "RNpfkR7F9N1cdIgR6w2YS2K4G07QnvDz" `
  -ModelSha256 "2e78ebc2c60209baaa9b3065ae59e9d92bd06dfdcb2672d18344d0642735e083"
```

Conserver le `CommandId`, puis récupérer stdout/stderr avec `ssm get-command-invocation`. Une erreur arrête le canary ; la promotion vers `8002` n'est pas automatisée.

## Terraform

```powershell
terraform -chdir=infra/aws init -backend=false -input=false
terraform -chdir=infra/aws validate
```

Pendant cette phase, `terraform apply` et `terraform destroy` sont interdits. Les ressources AWS existantes ne doivent pas être recréées ni supprimées.
