"""HTTP interface for the synthetic profile classifier."""

import hashlib
import logging
import os
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, field_validator

from app import model
from app.model import ModelUnavailable, get_model

logger = logging.getLogger("uvicorn.error")
STATIC_DIR = Path(__file__).parent / "static"

app = FastAPI(
    title="Mini CRM Intelligence",
    description="Synthetic profile classification demo",
    version="1.1.0",
)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


class Profile(BaseModel):
    id: int
    name: str
    skills: list[str]


class PredictionRequest(BaseModel):
    skills: str = Field(min_length=1, max_length=1000)

    @field_validator("skills")
    @classmethod
    def strip_and_validate_skills(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("skills must contain non-whitespace text")
        return value


class PredictionResponse(BaseModel):
    domain: str


PROFILES = [
    Profile(id=1, name="Alex Martin", skills=["Python", "Docker", "Linux"]),
    Profile(id=2, name="Samira Dupont", skills=["Terraform", "Ansible", "AWS"]),
    Profile(
        id=3,
        name="Thomas Bernard",
        skills=["Python", "MLflow", "Machine Learning"],
    ),
    Profile(id=4, name="Maya Laurent", skills=["Java", "Spring Boot", "PostgreSQL"]),
    Profile(id=5, name="Noah Petit", skills=["Kubernetes", "Helm", "Prometheus"]),
    Profile(id=6, name="Lina Moreau", skills=["Python", "FastAPI", "PostgreSQL"]),
    Profile(id=7, name="Adam Girard", skills=["AWS", "Terraform", "Docker"]),
    Profile(id=8, name="Ines Roux", skills=["scikit-learn", "MLflow", "Python"]),
    Profile(id=9, name="Hugo Fontaine", skills=["C#", ".NET", "SQL Server"]),
    Profile(id=10, name="Sara Chevalier", skills=["GitHub Actions", "Docker", "Linux"]),
    Profile(id=11, name="Leo Francois", skills=["JavaScript", "React", "Node.js"]),
    Profile(id=12, name="Nora Legrand", skills=["PyTorch", "Python", "Model serving"]),
    Profile(id=13, name="Ethan Garnier", skills=["Azure", "Terraform", "PowerShell"]),
    Profile(id=14, name="Jade Faure", skills=["Go", "REST APIs", "PostgreSQL"]),
    Profile(id=15, name="Louis Andre", skills=["Jenkins", "Ansible", "Kubernetes"]),
    Profile(id=16, name="Mila Mercier", skills=["Pandas", "SQL", "Data analysis"]),
    Profile(id=17, name="Yanis Blanc", skills=["AWS", "ECR", "EC2"]),
    Profile(id=18, name="Emma Guerin", skills=["Python", "Airflow", "MLflow"]),
    Profile(id=19, name="Rayan Muller", skills=["Linux", "Bash", "Nginx"]),
    Profile(id=20, name="Chloe Henry", skills=["TypeScript", "React", "AWS"]),
]


@app.get("/", include_in_schema=False)
def dashboard() -> FileResponse:
    """Serve the browser dashboard without changing the API contract."""
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/health")
def health_check() -> dict[str, str]:
    """Liveness does not depend on a model file."""
    return {"status": "healthy", "service": "mini-crm"}


@app.get("/ready")
def readiness_check() -> dict[str, str]:
    """Readiness verifies that the classifier can be loaded."""
    try:
        get_model()
    except ModelUnavailable as exc:
        raise HTTPException(status_code=503, detail="Model unavailable") from exc
    return {"status": "ready", "model": "loaded"}


@app.get("/model-info")
def model_info() -> dict[str, str]:
    """Expose the loaded model's deployment metadata."""
    try:
        get_model()
        digest = hashlib.sha256(model.MODEL_PATH.read_bytes()).hexdigest()
    except (ModelUnavailable, OSError) as exc:
        raise HTTPException(
            status_code=503,
            detail="Model unavailable",
        ) from exc

    return {
        "source": os.environ.get("MINI_CRM_MODEL_SOURCE", "bundled"),
        "version_id": os.environ.get("MINI_CRM_MODEL_VERSION", "not_set"),
        "sha256": digest,
    }


@app.get("/profiles", response_model=list[Profile])
def get_profiles() -> list[Profile]:
    return PROFILES


@app.post("/predict", response_model=PredictionResponse)
def predict_domain(request: PredictionRequest) -> PredictionResponse:
    try:
        prediction = get_model().predict([request.skills])[0]
    except ModelUnavailable as exc:
        raise HTTPException(status_code=503, detail="Model unavailable") from exc
    except Exception as exc:
        logger.exception("Model inference failed")
        raise HTTPException(status_code=500, detail="Prediction failed") from exc
    return PredictionResponse(domain=str(prediction))
