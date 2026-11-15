# KFP on the VMware K3s cluster

## Access

The existing K3s cluster is used; Kubernetes, Minikube, Kubeflow Pipelines and
Argo Workflows are not reinstalled by the project scripts. Argo CD was removed
and is intentionally absent.

From PowerShell, open the API/UI tunnel:

```powershell
ssh -N `
  -L 8888:127.0.0.1:8888 `
  -L 8090:127.0.0.1:8090 `
  farahbenharb@192.168.17.165
```

The KFP UI is then available at `http://localhost:8090` and the API at
`http://localhost:8888`.

The artifact importer also needs SeaweedFS through a local port-forward. On
the VM, run `kubectl port-forward -n kubeflow svc/seaweedfs 9000:9000`, then
open a second local tunnel with `-L 9000:127.0.0.1:9000`. Keep the artifact
access key and secret in environment variables only; never commit them.

## Cluster checks

```bash
kubectl get nodes
kubectl get pods -n kubeflow
kubectl get workflows -n kubeflow
df -h /
kubectl get ns argocd
```

The expected state is a `Ready` node, healthy KFP core services, no `argocd`
namespace, and enough free disk for the five component Pods. The VM is a small
demonstration host, so completed workflows and image cache must be monitored.

## Compile and submit

```powershell
cd C:\Users\Farah\Dev\Mlops-Project
$KfpPython = ".\.venv-kfp\Scripts\python.exe"
& $KfpPython pipelines/kubeflow_pipeline.py compile
```

The validated reference run is:

```text
KFP Run ID: eb3e4326-0052-4912-99d8-25f165358a93
Workflow: mini-crm-training-v2-qldcv
State: SUCCEEDED
```

The component logs contained `MODEL_TRAINED`, `F1_MACRO=1.0000`,
`QUALITY_GATE_PASS` and `CANDIDATE_MANIFEST_CREATED`. A negative run with
`min_f1=1.01` failed in `validate-model` with
`QUALITY_GATE_FAILED: F1=1.0, threshold=1.01`.

## Import KFP artifacts into MLflow

Install the controlled bridge in the normal ML environment:

```powershell
python -m pip install -r requirements-kfp.txt
$env:KFP_ARTIFACT_ACCESS_KEY = "<value from the kubeflow secret>"
$env:KFP_ARTIFACT_SECRET_KEY = "<value from the kubeflow secret>"
python ml/kfp_mlflow.py `
  --run-id eb3e4326-0052-4912-99d8-25f165358a93 `
  --output-dir artifacts\kfp\eb3e4326-0052-4912-99d8-25f165358a93
```

The verified reference produced MLflow Run ID
`00d3027e181043c38f691e65dfaf4b26`, Registry version `3` of
`MiniCRM-Classifier`, and alias `candidate`.
