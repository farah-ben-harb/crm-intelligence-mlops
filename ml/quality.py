"""Quality gates shared by local training and CI."""

from __future__ import annotations

from typing import Any

DEFAULT_MIN_F1_MACRO = 0.60


def evaluate_quality(
    metrics: dict[str, Any], min_f1_macro: float = DEFAULT_MIN_F1_MACRO
) -> dict[str, Any]:
    """Return explicit, serializable promotion checks for a candidate model."""
    f1_macro = float(metrics["f1_macro"])
    baseline = float(metrics["baseline_accuracy"])
    accuracy = float(metrics["accuracy"])
    checks = {
        "f1_macro_threshold": f1_macro >= min_f1_macro,
        "beats_baseline": accuracy >= baseline,
    }
    return {
        "passed": all(checks.values()),
        "min_f1_macro": min_f1_macro,
        "checks": checks,
    }


def assert_quality(metrics: dict[str, Any], min_f1_macro: float) -> None:
    """Fail training before promotion when a candidate does not meet policy."""
    result = evaluate_quality(metrics, min_f1_macro)
    if not result["passed"]:
        raise ValueError(f"Model quality gate failed: {result}")
