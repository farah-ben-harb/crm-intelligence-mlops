from pipelines.kubeflow_pipeline import pipeline_steps


def test_kubeflow_pipeline_contract_is_ordered():
    assert pipeline_steps() == (
        "prepare_data",
        "train",
        "evaluate",
        "validate",
        "register",
    )
