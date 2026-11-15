
"""Register a verified local model in MLflow Model Registry."""

import json
import os
from pathlib import Path

import joblib
import mlflow
import mlflow.sklearn
from mlflow.models import infer_signature
from mlflow.tracking import MlflowClient

ROOT = Path(__file__).resolve().parents[1]
MODEL_PATH = ROOT / "models/model.joblib"
MANIFEST_PATH = ROOT / "models/model-manifest.json"
REGISTRY_NAME = "MiniCRM-Classifier"


def main():
    from ml.manifest import sha256_file

    manifest = json.loads(
        MANIFEST_PATH.read_text(encoding="utf-8")
    )

    if not manifest["quality_gate"]["passed"]:
        raise ValueError("Quality gate failed")

    sha = sha256_file(MODEL_PATH)

    if sha != manifest["model"]["sha256"]:
        raise ValueError("Model SHA-256 mismatch")

    tracking_uri = os.environ.get(
        "MLFLOW_TRACKING_URI",
        f"sqlite:///{ROOT / 'mlflow.db'}",
    )

    mlflow.set_tracking_uri(tracking_uri)
    mlflow.set_registry_uri(tracking_uri)
    mlflow.set_experiment("MiniCRM-Classification")

    model = joblib.load(MODEL_PATH)

    example = ["Python Docker Linux"]
    expected = model.predict(example)
    signature = infer_signature(example, expected)

    with mlflow.start_run(run_name="register-candidate"):
        mlflow.set_tags({
            "git_sha": manifest["git_sha"],
            "dataset_sha256": manifest["dataset"]["sha256"],
            "model_sha256": sha,
            "quality_gate": "passed",
        })

        mlflow.log_metric(
            "f1_macro",
            float(manifest["metrics"]["f1_macro"]),
        )

        mlflow.log_artifact(str(MANIFEST_PATH))

        info = mlflow.sklearn.log_model(
            sk_model=model,
            name="classifier",
            signature=signature,
            input_example=example,
            registered_model_name=REGISTRY_NAME,
        )

    version = info.registered_model_version
    if version is None:
        raise RuntimeError("Registration not confirmed")

    client = MlflowClient()
    client.set_model_version_tag(
        REGISTRY_NAME, str(version), "model_sha256", sha
    )
    client.set_registered_model_alias(
        REGISTRY_NAME, "candidate", str(version)
    )

    # Verify the model can be reloaded from the Registry.
    loaded = mlflow.sklearn.load_model(
        f"models:/{REGISTRY_NAME}@candidate"
    )
    actual = loaded.predict(example)

    if list(actual) != list(expected):
        raise RuntimeError("Registry prediction mismatch")

    print(f"REGISTERED_MODEL={REGISTRY_NAME}")
    print(f"MODEL_VERSION={version}")
    print("ALIAS=candidate")
    print(f"MODEL_SHA256={sha}")
    print("MLFLOW_REGISTRY_VALIDATED")


if __name__ == "__main__":
    main()
