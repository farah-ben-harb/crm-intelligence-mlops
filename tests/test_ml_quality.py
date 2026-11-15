from pathlib import Path

import pytest

from ml.manifest import build_manifest, sha256_file
from ml.quality import assert_quality, evaluate_quality


def test_quality_gate_accepts_candidate_beating_baseline():
    metrics = {"f1_macro": 0.90, "accuracy": 0.90, "baseline_accuracy": 0.50}
    result = evaluate_quality(metrics, min_f1_macro=0.80)
    assert result["passed"] is True
    assert_quality(metrics, min_f1_macro=0.80)


def test_quality_gate_rejects_low_f1():
    metrics = {"f1_macro": 0.40, "accuracy": 0.80, "baseline_accuracy": 0.50}
    with pytest.raises(ValueError, match="quality gate failed"):
        assert_quality(metrics, min_f1_macro=0.80)


def test_quality_gate_rejects_impossible_threshold():
    metrics = {"f1_macro": 1.0, "accuracy": 1.0, "baseline_accuracy": 0.50}
    result = evaluate_quality(metrics, min_f1_macro=1.01)
    assert result["passed"] is False
    with pytest.raises(ValueError, match="quality gate failed"):
        assert_quality(metrics, min_f1_macro=1.01)


def test_manifest_contains_dataset_and_model_hashes(tmp_path, monkeypatch):
    dataset = Path(tmp_path / "profiles.csv")
    model = Path(tmp_path / "model.joblib")
    dataset.write_text("id,skills,domain\n1,Python,Backend\n", encoding="utf-8")
    model.write_bytes(b"model")
    monkeypatch.setenv("GIT_SHA", "abc123")
    metrics = {"rows": 1, "f1_macro": 1.0, "accuracy": 1.0}
    quality = {"passed": True}

    manifest = build_manifest(
        base_dir=tmp_path,
        dataset_path=dataset,
        model_path=model,
        metrics=metrics,
        quality_gate=quality,
    )

    assert manifest["git_sha"] == "abc123"
    assert manifest["dataset"]["sha256"] == sha256_file(dataset)
    assert manifest["model"]["sha256"] == sha256_file(model)
