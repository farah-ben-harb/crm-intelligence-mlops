
"""Mini CRM — Kubeflow Pipelines v2 (local and compilable)."""

import argparse
import os
import subprocess
from pathlib import Path

try:
    from kfp import compiler, dsl, local
    from kfp.dsl import Artifact, Dataset, Input, Metrics, Model, Output

    KFP_AVAILABLE = True
except ModuleNotFoundError:  # pragma: no cover - exercised by the base venv
    KFP_AVAILABLE = False

    class _KfpType:
        @classmethod
        def __class_getitem__(cls, _item):
            return cls

    class _DslFallback:
        @staticmethod
        def component(*_args, **_kwargs):
            return lambda function: function

        @staticmethod
        def pipeline(*_args, **_kwargs):
            return lambda function: function

    compiler = None
    dsl = _DslFallback()
    local = None
    Artifact = Dataset = Input = Metrics = Model = Output = _KfpType

PIPELINE_STEPS = (
    "prepare_data",
    "train",
    "evaluate",
    "validate",
    "register",
)


def pipeline_steps() -> tuple[str, ...]:
    """Return the stable ordered contract of the training pipeline."""
    return PIPELINE_STEPS


def _require_kfp() -> None:
    if not KFP_AVAILABLE:
        raise RuntimeError(
            "KFP n'est pas installé. Utilisez .venv-kfp pour compiler ou "
            "exécuter le pipeline."
        )


class _LocalArtifact:
    """Minimal artifact implementation for the Windows in-process runner."""

    def __init__(self, path: Path):
        self.path = str(path)
        self.metadata = {}


class _LocalMetrics(_LocalArtifact):
    def log_metric(self, name: str, value: float):
        self.metadata[name] = value


@dsl.component(base_image="python:3.12-slim")
def prepare_data(
    raw_csv: str,
    train_set: Output[Dataset],
    test_set: Output[Dataset],
    source: Output[Artifact],
):
    import csv
    import hashlib
    import io
    import json
    import random

    rows = list(csv.DictReader(io.StringIO(raw_csv)))
    if len(rows) < 30:
        raise ValueError("Dataset trop petit")

    if any(not r["skills"] or not r["domain"] for r in rows):
        raise ValueError("Valeur manquante")

    ids = [r["id"] for r in rows]
    if len(set(ids)) != len(ids):
        raise ValueError("IDs dupliqués")

    groups = {}
    for row in rows:
        groups.setdefault(row["domain"], []).append(row)

    if set(groups) != {"DevOps", "Backend", "MLOps"}:
        raise ValueError("Classes inattendues")

    rng = random.Random(42)
    training, testing = [], []

    for label in sorted(groups):
        group = groups[label]
        rng.shuffle(group)
        n_test = max(1, round(len(group) * 0.30))
        testing.extend(group[:n_test])
        training.extend(group[n_test:])

    with open(train_set.path, "w", encoding="utf-8") as f:
        json.dump(training, f)

    with open(test_set.path, "w", encoding="utf-8") as f:
        json.dump(testing, f)

    with open(source.path, "w", encoding="utf-8") as f:
        json.dump({
            "sha256": hashlib.sha256(
                raw_csv.encode("utf-8")
            ).hexdigest(),
            "rows": len(rows),
        }, f)

    print(f"Train: {len(training)}, Test: {len(testing)}")


@dsl.component(
    base_image="python:3.12-slim",
    packages_to_install=["scikit-learn==1.9.1", "joblib==1.6.0"],
)
def train_model(
    train_set: Input[Dataset],
    trained_model: Output[Model],
):
    import json

    import joblib
    from sklearn.feature_extraction.text import TfidfVectorizer
    from sklearn.linear_model import LogisticRegression
    from sklearn.pipeline import Pipeline

    with open(train_set.path, encoding="utf-8") as f:
        rows = json.load(f)

    model = Pipeline([
        ("tfidf", TfidfVectorizer()),
        ("classifier", LogisticRegression(
            C=0.1, max_iter=1000, random_state=42
        )),
    ])

    model.fit(
        [r["skills"] for r in rows],
        [r["domain"] for r in rows],
    )

    joblib.dump(model, trained_model.path)
    trained_model.metadata["framework"] = "scikit-learn"
    trained_model.metadata["training_rows"] = len(rows)

    print("MODEL_TRAINED")


@dsl.component(
    base_image="python:3.12-slim",
    packages_to_install=["scikit-learn==1.9.1", "joblib==1.6.0"],
)
def evaluate_model(
    trained_model: Input[Model],
    test_set: Input[Dataset],
    metrics: Output[Metrics],
):
    import json

    import joblib
    from sklearn.metrics import (
        accuracy_score,
        confusion_matrix,
        f1_score,
    )

    with open(test_set.path, encoding="utf-8") as f:
        rows = json.load(f)

    model = joblib.load(trained_model.path)
    y_true = [r["domain"] for r in rows]
    y_pred = model.predict([r["skills"] for r in rows])

    accuracy = float(accuracy_score(y_true, y_pred))
    f1 = float(f1_score(y_true, y_pred, average="macro"))

    metrics.log_metric("accuracy", accuracy)
    metrics.log_metric("f1_macro", f1)
    metrics.metadata["test_rows"] = len(rows)
    metrics.metadata["labels"] = sorted(set(y_true))
    metrics.metadata["confusion_matrix"] = confusion_matrix(
        y_true, y_pred, labels=sorted(set(y_true))
    ).tolist()

    print(f"ACCURACY={accuracy:.4f}")
    print(f"F1_MACRO={f1:.4f}")


@dsl.component(base_image="python:3.12-slim")
def validate_model(
    metrics: Input[Metrics],
    min_f1: float,
    gate: Output[Artifact],
):
    import json

    f1 = float(metrics.metadata["f1_macro"])
    passed = f1 >= min_f1

    with open(gate.path, "w", encoding="utf-8") as f:
        json.dump({
            "passed": passed,
            "f1_macro": f1,
            "min_f1": min_f1,
        }, f)

    if not passed:
        raise ValueError(
            f"QUALITY_GATE_FAILED: F1={f1}, threshold={min_f1}"
        )

    print("QUALITY_GATE_PASS")


@dsl.component(base_image="python:3.12-slim")
def register_candidate(
    trained_model: Input[Model],
    metrics: Input[Metrics],
    gate: Input[Artifact],
    source: Input[Artifact],
    git_sha: str,
    manifest: Output[Artifact],
):
    import hashlib
    import json

    with open(gate.path, encoding="utf-8") as f:
        verdict = json.load(f)

    if not verdict["passed"]:
        raise ValueError("Candidat refusé")

    with open(source.path, encoding="utf-8") as f:
        dataset = json.load(f)

    with open(trained_model.path, "rb") as f:
        model_sha = hashlib.sha256(f.read()).hexdigest()

    result = {
        "status": "candidate_only",
        "git_sha": git_sha,
        "dataset": dataset,
        "model_sha256": model_sha,
        "metrics": dict(metrics.metadata),
        "quality_gate": verdict,
        "publication_s3": False,
        "mlflow_registry": False,
    }

    with open(manifest.path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2)

    print("CANDIDATE_MANIFEST_CREATED")


@dsl.pipeline(name="mini-crm-training-v2")
def training_pipeline(
    dataset_csv: str,
    git_sha: str,
    min_f1: float = 0.60,
):
    prep = prepare_data(raw_csv=dataset_csv)

    train = train_model(
        train_set=prep.outputs["train_set"]
    )

    evaluation = evaluate_model(
        trained_model=train.outputs["trained_model"],
        test_set=prep.outputs["test_set"],
    )

    validation = validate_model(
        metrics=evaluation.outputs["metrics"],
        min_f1=min_f1,
    )

    register_candidate(
        trained_model=train.outputs["trained_model"],
        metrics=evaluation.outputs["metrics"],
        gate=validation.outputs["gate"],
        source=prep.outputs["source"],
        git_sha=git_sha,
    )


def _run_python_pipeline(dataset_csv: str, git_sha: str, min_f1: float):
    """Run component Python functions directly when Unix shell tools are absent."""
    output_root = Path("pipelines/local_outputs").resolve()
    output_root.mkdir(parents=True, exist_ok=True)

    train_set = _LocalArtifact(output_root / "train_set.json")
    test_set = _LocalArtifact(output_root / "test_set.json")
    source = _LocalArtifact(output_root / "source.json")
    trained_model = _LocalArtifact(output_root / "model.joblib")
    metrics = _LocalMetrics(output_root / "metrics.json")
    gate = _LocalArtifact(output_root / "gate.json")
    manifest = _LocalArtifact(output_root / "manifest.json")

    prepare_data.python_func(dataset_csv, train_set, test_set, source)
    train_model.python_func(train_set, trained_model)
    evaluate_model.python_func(trained_model, test_set, metrics)
    validate_model.python_func(metrics, min_f1, gate)
    register_candidate.python_func(
        trained_model,
        metrics,
        gate,
        source,
        git_sha,
        manifest,
    )

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["compile", "run"])
    parser.add_argument(
        "--runner", choices=["python", "subprocess", "docker"],
        default="python" if os.name == "nt" else "subprocess",
    )
    parser.add_argument("--min-f1", type=float, default=0.60)
    args = parser.parse_args()

    if args.action == "compile":
        _require_kfp()
        destination = Path("pipelines/mini_crm_pipeline.yaml")
        compiler.Compiler().compile(
            pipeline_func=training_pipeline,
            package_path=str(destination),
        )
        print(f"PIPELINE_COMPILED={destination}")
        return

    git_sha = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], text=True
    ).strip()
    dataset_csv = Path("data/profiles.csv").read_text(encoding="utf-8")

    if args.runner == "python":
        _require_kfp()
        _run_python_pipeline(
            dataset_csv=dataset_csv,
            git_sha=git_sha,
            min_f1=args.min_f1,
        )
        print("KFP_LOCAL_RUN_COMPLETE")
        return

    _require_kfp()
    runner = (
        local.DockerRunner()
        if args.runner == "docker"
        else local.SubprocessRunner(use_venv=False)
    )

    local.init(
        runner=runner,
        pipeline_root=str(
            Path("pipelines/local_outputs").resolve()
        ),
    )

    training_pipeline(
        dataset_csv=dataset_csv,
        git_sha=git_sha,
        min_f1=args.min_f1,
    )

    print("KFP_LOCAL_RUN_COMPLETE")


if __name__ == "__main__":
    main()
