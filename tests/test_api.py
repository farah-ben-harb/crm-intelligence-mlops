import hashlib
from pathlib import Path

import joblib
import pytest
from fastapi.testclient import TestClient
from sklearn.dummy import DummyClassifier

from app import model
from app.main import app

client = TestClient(app)


@pytest.fixture(autouse=True)
def clear_model_cache():
    model.get_model.cache_clear()
    yield
    model.get_model.cache_clear()


def test_health():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "healthy", "service": "mini-crm"}


def test_profiles():
    response = client.get("/profiles")
    assert response.status_code == 200
    assert len(response.json()) == 3
    assert response.json()[0]["skills"] == ["Python", "Docker", "Linux"]


def test_predict_with_packaged_model():
    assert client.get("/ready").json() == {"status": "ready", "model": "loaded"}
    response = client.post(
        "/predict", json={"skills": "Python Docker Kubernetes Terraform"}
    )
    assert response.status_code == 200
    assert response.json()["domain"] == "DevOps"


@pytest.mark.parametrize(
    "payload",
    [{}, {"skills": ""}, {"skills": "   "}, {"skills": 123}, {"skills": "x" * 1001}],
)
def test_predict_rejects_invalid_input(payload):
    response = client.post("/predict", json=payload)
    assert response.status_code == 422


def test_missing_model_keeps_liveness_but_blocks_readiness(tmp_path, monkeypatch):
    monkeypatch.setattr(model, "MODEL_PATH", tmp_path / "missing.joblib")
    assert client.get("/health").status_code == 200
    assert client.get("/ready").status_code == 503
    response = client.post("/predict", json={"skills": "Python"})
    assert response.status_code == 503
    assert response.json() == {"detail": "Model unavailable"}


def test_model_loader_uses_configured_artifact(tmp_path, monkeypatch):
    path = Path(tmp_path / "model.joblib")
    classifier = DummyClassifier(strategy="constant", constant="Backend")
    classifier.fit([["Python"]], ["Backend"])
    joblib.dump(classifier, path)
    monkeypatch.setattr(model, "MODEL_PATH", path)
    response = client.post("/predict", json={"skills": "Python"})
    assert response.status_code == 200
    assert response.json() == {"domain": "Backend"}


def test_model_loader_rejects_sha256_mismatch(tmp_path, monkeypatch):
    path = Path(tmp_path / "model.joblib")
    classifier = DummyClassifier(strategy="constant", constant="Backend")
    classifier.fit([["Python"]], ["Backend"])
    joblib.dump(classifier, path)
    monkeypatch.setattr(model, "MODEL_PATH", path)
    monkeypatch.setenv("MINI_CRM_MODEL_SHA256", "0" * 64)

    response = client.get("/ready")

    assert response.status_code == 503
    assert response.json() == {"detail": "Model unavailable"}


def test_model_info_exposes_verified_provenance(tmp_path, monkeypatch):
    path = Path(tmp_path / "model.joblib")
    classifier = DummyClassifier(strategy="constant", constant="Backend")
    classifier.fit([["Python"]], ["Backend"])
    joblib.dump(classifier, path)
    monkeypatch.setattr(model, "MODEL_PATH", path)
    monkeypatch.setenv("MINI_CRM_MODEL_SOURCE", "s3://mini-crm-models/models/model.joblib")
    monkeypatch.setenv("MINI_CRM_MODEL_VERSION", "test-version")

    response = client.get("/model-info")

    assert response.status_code == 200
    assert response.json() == {
        "source": "s3://mini-crm-models/models/model.joblib",
        "version_id": "test-version",
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }
