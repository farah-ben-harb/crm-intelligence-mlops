"""Local Kubeflow Pipelines blueprint.

The repository deliberately does not install KFP in the default environment. This
module keeps the graph and component contracts testable without claiming that a
Kubernetes/KFP runtime exists locally.
"""

from __future__ import annotations

from pathlib import Path

PIPELINE_STEPS = ("prepare_data", "train", "evaluate", "validate", "register")


def pipeline_steps() -> tuple[str, ...]:
    return PIPELINE_STEPS


def compile_pipeline(output_path: Path) -> None:
    """Compile the KFP graph when the optional SDK is installed."""
    try:
        from kfp import dsl
        from kfp.compiler import Compiler
    except ModuleNotFoundError as exc:
        raise RuntimeError(
            "KFP n'est pas installé. Installer kfp dans un environnement dédié "
            "pour compiler sans toucher à AWS."
        ) from exc

    @dsl.container_component
    def run_step(step: str):
        return dsl.ContainerSpec(
            image="python:3.12-slim",
            command=["sh", "-c"],
            args=["echo $0; test -n $0", step],
        )

    @dsl.pipeline(name="mini-crm-reproducible-training")
    def training_pipeline():
        previous = None
        for step in PIPELINE_STEPS:
            task = run_step(step)
            if previous is not None:
                task.after(previous)
            previous = task

    Compiler().compile(training_pipeline, str(output_path))


if __name__ == "__main__":
    compile_pipeline(Path("pipelines/mini_crm_pipeline.yaml"))
