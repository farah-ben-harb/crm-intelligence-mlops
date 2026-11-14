"""Model manifest and provenance helpers."""

from __future__ import annotations

import hashlib
import os
import platform
import subprocess
from pathlib import Path
from typing import Any


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_sha(base_dir: Path) -> str:
    configured = os.environ.get("GIT_SHA")
    if configured:
        return configured
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=base_dir,
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return "unknown"
    return result.stdout.strip()


def build_manifest(
    *,
    base_dir: Path,
    dataset_path: Path,
    model_path: Path,
    metrics: dict[str, Any],
    quality_gate: dict[str, Any],
) -> dict[str, Any]:
    """Build a JSON-safe manifest for an immutable model artifact."""
    return {
        "schema_version": 1,
        "git_sha": git_sha(base_dir),
        "model_version": os.environ.get("MODEL_VERSION", git_sha(base_dir)),
        "dataset": {
            "path": str(dataset_path.relative_to(base_dir)),
            "sha256": sha256_file(dataset_path),
            "rows": metrics["rows"],
        },
        "model": {
            "path": str(model_path.relative_to(base_dir)),
            "sha256": sha256_file(model_path),
        },
        "metrics": metrics,
        "quality_gate": quality_gate,
        "runtime": {"python": platform.python_version()},
    }
