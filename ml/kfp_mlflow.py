"""Import a verified Kubeflow run into the local MLflow Registry.

The KFP components remain responsible for training, evaluation, the quality
gate and the candidate manifest.  This module is deliberately an external,
operator-controlled bridge: it reads the completed KFP run and its S3-
compatible artifact store through local SSH tunnels, then records the exact
provenance in the local MLflow Tracking/Registry database.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path
from typing import Any

import boto3
import joblib
import mlflow
import mlflow.sklearn
from mlflow.models import infer_signature
from mlflow.tracking import MlflowClient
from sklearn.metrics import accuracy_score, confusion_matrix, f1_score

REGISTRY_NAME = "MiniCRM-Classifier"
DEFAULT_ARTIFACT_BUCKET = "mlpipeline"
DEFAULT_ARTIFACT_ENDPOINT = "http://127.0.0.1:9000"
DEFAULT_KFP_HOST = "http://127.0.0.1:8888"
_METRIC_PATTERN = re.compile(
    r"^(?P<name>ACCURACY|F1_MACRO)=(?P<value>[0-9]+(?:\.[0-9]+)?)$",
    re.MULTILINE,
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _single_object(s3: Any, bucket: str, prefix: str, suffix: str) -> str:
    response = s3.list_objects_v2(Bucket=bucket, Prefix=prefix)
    keys = [
        item["Key"]
        for item in response.get("Contents", [])
        if item["Key"].endswith(suffix)
    ]
    if len(keys) != 1:
        raise RuntimeError(
            f"Objet KFP attendu une fois: prefix={prefix!r}, suffix={suffix!r}, "
            f"trouvé={keys!r}"
        )
    return keys[0]


def _download(s3: Any, bucket: str, key: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    s3.download_file(bucket, key, str(destination))


def _parse_component_metrics(log_text: str) -> dict[str, float]:
    values = {
        match.group("name").lower(): float(match.group("value"))
        for match in _METRIC_PATTERN.finditer(log_text)
    }
    if set(values) != {"accuracy", "f1_macro"}:
        raise RuntimeError("Les métriques KFP ACCURACY/F1_MACRO sont absentes des logs")
    return values


def _get_run(client: Any, run_id: str) -> dict[str, Any]:
    run = client.get_run(run_id).to_dict()
    history = run.get("state_history") or []
    state = history[-1].get("state") if history else run.get("state")
    if state != "SUCCEEDED":
        raise RuntimeError(f"Le run KFP {run_id} n'est pas valide: état={state}")
    return run


def import_kfp_run(
    *,
    run_id: str,
    kfp_host: str,
    artifact_endpoint: str,
    artifact_access_key: str,
    artifact_secret_key: str,
    artifact_bucket: str,
    output_dir: Path,
    tracking_uri: str,
    registry_name: str = REGISTRY_NAME,
) -> dict[str, Any]:
    """Retrieve a successful KFP run and register its model in MLflow."""
    from kfp import Client

    kfp_client = Client(host=kfp_host)
    run = _get_run(kfp_client, run_id)
    pipeline_name = run["pipeline_spec"]["pipelineInfo"]["name"]
    prefix = f"v2/artifacts/{pipeline_name}/{run_id}/"

    s3 = boto3.client(
        "s3",
        endpoint_url=artifact_endpoint,
        aws_access_key_id=artifact_access_key,
        aws_secret_access_key=artifact_secret_key,
        region_name="us-east-1",
    )

    paths = {
        "trained_model": _single_object(s3, artifact_bucket, prefix, "/trained_model"),
        "test_set": _single_object(s3, artifact_bucket, prefix, "/test_set"),
        "source": _single_object(s3, artifact_bucket, prefix, "/source"),
        "gate": _single_object(s3, artifact_bucket, prefix, "/gate"),
        "manifest": _single_object(s3, artifact_bucket, prefix, "/manifest"),
        "evaluate_logs": _single_object(
            s3, artifact_bucket, prefix, "/executor-logs-0"
        ),
    }

    output_dir.mkdir(parents=True, exist_ok=True)
    local_paths = {
        name: output_dir / {
            "trained_model": "model.joblib",
            "test_set": "test_set.json",
            "source": "source.json",
            "gate": "gate.json",
            "manifest": "kfp-manifest.json",
            "evaluate_logs": "evaluate.log",
        }[name]
        for name in paths
    }
    for name, key in paths.items():
        _download(s3, artifact_bucket, key, local_paths[name])

    model_sha = sha256_file(local_paths["trained_model"])
    manifest = json.loads(local_paths["manifest"].read_text(encoding="utf-8"))
    gate = json.loads(local_paths["gate"].read_text(encoding="utf-8"))
    source = json.loads(local_paths["source"].read_text(encoding="utf-8"))
    if not gate.get("passed"):
        raise RuntimeError("Le quality gate KFP n'est pas positif")
    if manifest.get("model_sha256") != model_sha:
        raise RuntimeError("Le SHA-256 du modèle ne correspond pas au manifeste KFP")
    if manifest.get("quality_gate", {}).get("passed") is not True:
        raise RuntimeError("Le manifeste KFP n'indique pas une quality gate positive")

    log_metrics = _parse_component_metrics(
        local_paths["evaluate_logs"].read_text(encoding="utf-8")
    )
    test_rows = json.loads(local_paths["test_set"].read_text(encoding="utf-8"))
    model = joblib.load(local_paths["trained_model"])
    y_true = [row["domain"] for row in test_rows]
    y_pred = model.predict([row["skills"] for row in test_rows])
    labels = sorted(set(y_true))
    metrics = {
        "accuracy": float(accuracy_score(y_true, y_pred)),
        "f1_macro": float(f1_score(y_true, y_pred, average="macro")),
        "confusion_matrix": confusion_matrix(y_true, y_pred, labels=labels).tolist(),
        "labels": labels,
        "test_rows": len(test_rows),
    }
    for name in ("accuracy", "f1_macro"):
        if abs(metrics[name] - log_metrics[name]) > 1e-9:
            raise RuntimeError(f"Métrique {name} différente entre logs et artefact")

    runtime_parameters = (run.get("runtime_config") or {}).get("parameters") or {}
    git_sha = str(runtime_parameters.get("git_sha") or manifest.get("git_sha"))
    dataset_sha = str(source.get("sha256") or "")
    if not re.fullmatch(r"[0-9a-f]{40}", git_sha):
        raise RuntimeError(f"Git SHA KFP invalide: {git_sha!r}")
    if not re.fullmatch(r"[0-9a-f]{64}", dataset_sha):
        raise RuntimeError("Dataset SHA-256 absent du manifeste KFP")

    mlflow.set_tracking_uri(tracking_uri)
    mlflow.set_registry_uri(tracking_uri)
    mlflow.set_experiment("MiniCRM-KFP")
    example = ["Python Docker Linux"]
    expected = model.predict(example)
    with mlflow.start_run(run_name=f"kfp-{run_id}") as active_run:
        mlflow.set_tags(
            {
                "kfp_run_id": run_id,
                "git_sha": git_sha,
                "dataset_sha256": dataset_sha,
                "model_sha256": model_sha,
                "quality_gate": "passed",
                "pipeline_name": pipeline_name,
            }
        )
        mlflow.log_metrics(
            {"accuracy": metrics["accuracy"], "f1_macro": metrics["f1_macro"]}
        )
        mlflow.log_params(
            {"test_rows": metrics["test_rows"], "labels": ",".join(labels)}
        )
        evaluation_path = output_dir / "evaluation.json"
        evaluation_path.write_text(
            json.dumps(metrics, indent=2) + "\n", encoding="utf-8"
        )
        mlflow.log_artifact(str(local_paths["manifest"]), artifact_path="kfp")
        mlflow.log_artifact(str(local_paths["gate"]), artifact_path="kfp")
        mlflow.log_artifact(str(evaluation_path), artifact_path="kfp")
        info = mlflow.sklearn.log_model(
            sk_model=model,
            name="classifier",
            signature=infer_signature(example, expected),
            input_example=example,
            registered_model_name=registry_name,
        )
        mlflow_run_id = active_run.info.run_id

    version = str(info.registered_model_version or "")
    if not version:
        raise RuntimeError("MLflow n'a pas retourné de version Registry")
    mlflow_client = MlflowClient(tracking_uri=tracking_uri)
    mlflow_client.set_model_version_tag(registry_name, version, "kfp_run_id", run_id)
    mlflow_client.set_model_version_tag(registry_name, version, "git_sha", git_sha)
    mlflow_client.set_model_version_tag(
        registry_name, version, "dataset_sha256", dataset_sha
    )
    mlflow_client.set_model_version_tag(
        registry_name, version, "model_sha256", model_sha
    )
    mlflow_client.set_registered_model_alias(registry_name, "candidate", version)

    loaded = mlflow.sklearn.load_model(f"models:/{registry_name}@candidate")
    reloaded = loaded.predict(example)
    if list(reloaded) != list(expected):
        raise RuntimeError("Prédiction différente après rechargement Registry")

    evidence = {
        "schema_version": 1,
        "kfp": {
            "run_id": run_id,
            "pipeline_name": pipeline_name,
            "state": "SUCCEEDED",
            "host": kfp_host,
            "artifact_prefix": prefix,
        },
        "mlflow": {
            "tracking_uri": tracking_uri,
            "run_id": mlflow_run_id,
            "registry_name": registry_name,
            "registry_version": version,
            "alias": "candidate",
        },
        "git_sha": git_sha,
        "dataset_sha256": dataset_sha,
        "model_sha256": model_sha,
        "metrics": metrics,
        "quality_gate": gate,
        "artifact_keys": paths,
        "model_path": str(local_paths["trained_model"]),
        "registry_prediction": str(reloaded[0]),
    }
    evidence_path = output_dir / "evidence.json"
    evidence_path.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    return evidence


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--kfp-host", default=os.getenv("KFP_HOST", DEFAULT_KFP_HOST))
    parser.add_argument(
        "--artifact-endpoint",
        default=os.getenv("KFP_ARTIFACT_ENDPOINT", DEFAULT_ARTIFACT_ENDPOINT),
    )
    parser.add_argument("--artifact-bucket", default=DEFAULT_ARTIFACT_BUCKET)
    parser.add_argument("--access-key", default=os.getenv("KFP_ARTIFACT_ACCESS_KEY"))
    parser.add_argument("--secret-key", default=os.getenv("KFP_ARTIFACT_SECRET_KEY"))
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument(
        "--tracking-uri",
        default=os.getenv("MLFLOW_TRACKING_URI", "sqlite:///mlflow.db"),
    )
    parser.add_argument("--registry-name", default=REGISTRY_NAME)
    return parser


def main() -> None:
    args = _parser().parse_args()
    if not args.access_key or not args.secret_key:
        raise SystemExit(
            "KFP_ARTIFACT_ACCESS_KEY et KFP_ARTIFACT_SECRET_KEY sont requis "
            "et doivent rester dans l'environnement local."
        )
    evidence = import_kfp_run(
        run_id=args.run_id,
        kfp_host=args.kfp_host,
        artifact_endpoint=args.artifact_endpoint,
        artifact_access_key=args.access_key,
        artifact_secret_key=args.secret_key,
        artifact_bucket=args.artifact_bucket,
        output_dir=args.output_dir,
        tracking_uri=args.tracking_uri,
        registry_name=args.registry_name,
    )
    print(f"KFP_RUN_ID={evidence['kfp']['run_id']}")
    print(f"MLFLOW_RUN_ID={evidence['mlflow']['run_id']}")
    print(f"REGISTRY_NAME={evidence['mlflow']['registry_name']}")
    print(f"REGISTRY_VERSION={evidence['mlflow']['registry_version']}")
    print("ALIAS=candidate")
    print(f"MODEL_SHA256={evidence['model_sha256']}")
    print("KFP_MLFLOW_IMPORT_OK")


if __name__ == "__main__":
    main()
