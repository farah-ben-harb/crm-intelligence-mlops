"""Load only a trusted, locally packaged classifier artifact."""

import hashlib
import hmac
import logging
import os
from functools import lru_cache
from pathlib import Path
from typing import Any

import joblib

logger = logging.getLogger("uvicorn.error")

MODEL_PATH = Path(
    os.environ.get(
        "MINI_CRM_MODEL_PATH",
        str(Path(__file__).resolve().parent.parent / "models" / "model.joblib"),
    )
)


class ModelUnavailable(RuntimeError):
    """The configured classifier cannot serve requests."""


@lru_cache(maxsize=1)
def get_model() -> Any:
    """Load once on first use so an absent artifact does not kill the API."""
    try:
        expected_sha = os.environ.get("MINI_CRM_MODEL_SHA256")
        if expected_sha:
            actual_sha = hashlib.sha256(MODEL_PATH.read_bytes()).hexdigest()
            if not hmac.compare_digest(actual_sha, expected_sha.lower()):
                raise ValueError("Model SHA-256 mismatch")

        model = joblib.load(MODEL_PATH)
        if not callable(getattr(model, "predict", None)):
            raise TypeError("Artifact does not implement predict")
    except Exception as exc:
        logger.error("Model load failed at %s: %s", MODEL_PATH, type(exc).__name__)
        raise ModelUnavailable("Classifier artifact could not be loaded") from exc
    logger.info("Model loaded from %s", MODEL_PATH)
    return model
