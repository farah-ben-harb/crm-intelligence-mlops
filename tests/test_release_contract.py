from pathlib import Path

ROOT = Path(__file__).parents[1]


def read_script(name: str) -> str:
    return (ROOT / "scripts" / "aws" / name).read_text(encoding="utf-8")


def test_release_requires_explicit_production_approval() -> None:
    script = read_script("release.ps1")
    assert "ApproveProduction" in script
    assert "La promotion production exige" in script
    assert "$Promote" in script


def test_release_requires_immutable_artifacts_and_manifest() -> None:
    script = read_script("release.ps1")
    assert "ValidatePattern('@sha256:[0-9a-f]{64}$')" in script
    assert "candidates/[0-9a-f]{40}/model\\.joblib" in script
    assert "ManifestPath" in script
    assert "quality_gate.passed" in script
    assert "head.Metadata.sha256" in script
    assert 'if ($WhatIf)' in script
    assert 'production_unchanged = $true' in script


def test_release_preserves_production_until_promotion() -> None:
    script = read_script("release.ps1")
    assert 'production_promotion = "not-executed"' in script
    assert 'production_unchanged = $true' in script
    assert 'production_unchanged = $false' in script


def test_production_deployment_has_lock_and_reversible_backup() -> None:
    script = read_script("deploy-production.ps1")
    assert ".production-release.lock" in script
    assert "backup_container=mini-crm-api-rollback" in script
    assert "production.inspect.sanitized.json" in script
    assert "MODEL_SOURCE" in script
    assert "ROLLBACK_SUCCESS" in script
    assert "ROLLBACK_FAILED" in script


def test_canary_deployment_returns_command_id_and_has_lock() -> None:
    script = read_script("deploy-canary.ps1")
    assert ".canary-release.lock" in script
    assert 'Write-Output "COMMAND_ID=$commandId"' in script


def test_kfp_candidate_publication_is_immutable_and_traceable() -> None:
    script = read_script("publish-kfp-candidate.ps1")
    assert "candidate-published" in script
    assert "candidates/$($evidence.git_sha)/model.joblib" in script
    assert "S3_CANDIDATE_PUBLISHED" in script
    assert "aucun écrasement autorisé" in script
    assert "downloadSha" in script
    assert "production_changed = $false" in script
