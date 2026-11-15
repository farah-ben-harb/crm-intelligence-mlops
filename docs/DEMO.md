# Mini CRM Intelligence — 10-minute demonstration

This script uses evidence produced by the platform. It does not promote a
candidate to production.

## 1. Repository and CI — 1 minute

```powershell
cd C:\Users\Farah\Dev\Mlops-Project
git switch feat/aws-terraform
git log --oneline -6
git status --short
```

Explain that pushes to `feat/aws-terraform` and `main` run validation, while
the `publish` job remains restricted to `main`. `cd-preflight.yml` is manual
and validates immutable inputs only; it has no AWS credentials and cannot
promote production.

## 2. K3s and KFP — 2 minutes

```powershell
ssh -N -L 8888:127.0.0.1:8888 -L 8090:127.0.0.1:8090 `
  farahbenharb@192.168.17.165
```

Open `http://localhost:8090`, then show:

```powershell
kubectl get nodes
kubectl get pods -n kubeflow
```

The reference run is `eb3e4326-0052-4912-99d8-25f165358a93`. Show its five
components and the logs containing:

```text
MODEL_TRAINED
F1_MACRO=1.0000
QUALITY_GATE_PASS
CANDIDATE_MANIFEST_CREATED
```

The negative proof is a separate run with `min_f1=1.01`; it failed at
`validate-model` and never registered a candidate.

## 3. MLflow — 2 minutes

Run the controlled importer from `docs/KFP_CLUSTER.md`, or show the generated
evidence file. The reference values are:

```text
MLflow Run ID: 00d3027e181043c38f691e65dfaf4b26
Registry: MiniCRM-Classifier
Version: 3
Alias: candidate
F1 macro: 1.0
Model SHA-256: 8652266ea0fef5690c633955e31fcc654efd2357abd538f9c6d4f511e27431d5
```

The bridge reloads `models:/MiniCRM-Classifier@candidate` and verifies an
independent prediction before reporting success. `champion` is not changed.

## 4. S3 candidate and canary — 3 minutes

The verified candidate is immutable and versioned:

```text
S3 key: candidates/6af74e6521b1b9a278dfea83504b9c4e3dc0cbac/model.joblib
Model VersionId: cDCVIV7AwE.FPmDXdcwuVFN8CkdmuRGv
Manifest VersionId: euQqQvqLxfymTxXHA8gv2VKjMTqW.f6h
```

The controlled commands are:

```powershell
.\scripts\aws\publish-kfp-candidate.ps1 `
  -EvidencePath .\artifacts\kfp\eb3e4326-0052-4912-99d8-25f165358a93\evidence.json `
  -ModelPath .\artifacts\kfp\eb3e4326-0052-4912-99d8-25f165358a93\model.joblib

.\scripts\aws\release.ps1 `
  -Image "251538491265.dkr.ecr.eu-north-1.amazonaws.com/mini-crm-api@sha256:b84ca59f9aa5aa9800d3c4c7075a9e075fa6d21fa8b37daf1aae8d5079ee57cc" `
  -ModelKey "candidates/6af74e6521b1b9a278dfea83504b9c4e3dc0cbac/model.joblib" `
  -ModelVersion "cDCVIV7AwE.FPmDXdcwuVFN8CkdmuRGv" `
  -ModelSha256 "8652266ea0fef5690c633955e31fcc654efd2357abd538f9c6d4f511e27431d5" `
  -ManifestPath .\artifacts\s3-candidate-manifest-final.json `
  -ReportPath .\artifacts\release-canary-report-final.json
```

The verified canary SSM command was
`54b08f6f-820a-4ec9-809e-2afc3b18965c`. It validated the model checksum, ECR
digest, `8004` endpoints and the unchanged production health on `8002`.

## 5. Observability and rollback — 2 minutes

```powershell
aws logs describe-log-groups --profile mini-crm --region eu-north-1 `
  --log-group-name-prefix /mini-crm/api
aws logs describe-log-streams --profile mini-crm --region eu-north-1 `
  --log-group-name /mini-crm/api --order-by LastEventTime --descending
aws cloudwatch describe-alarms --profile mini-crm --region eu-north-1 `
  --alarm-names MiniCRM-EC2-CPUHigh
```

The observed Log Group retention is 7 days, the alarm is `OK`, and recent API
events include successful `/health`, `/ready`, `/model-info` and `/predict`
requests. `deploy-production.ps1` and `rollback-production.ps1` were inspected
with `-WhatIf`; the real production path remains behind `-Promote` plus
`-ApproveProduction`.

## Fallback plan

If KFP is unavailable, show the committed pipeline YAML and the last verified
run/evidence IDs. If AWS is unavailable, show the local MLflow evidence and the
release preflight report; do not invent a canary result or run a production
command. If the SSH tunnel closes, reopen it and keep the artifact port-forward
separate from the KFP API/UI tunnel.
