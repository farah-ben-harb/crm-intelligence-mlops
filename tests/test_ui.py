from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_dashboard_is_served_at_root() -> None:
    response = client.get("/")

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/html")
    assert "Mini CRM Intelligence" in response.text
    assert "/static/styles.css" in response.text
    assert "/static/app.js" in response.text


def test_static_assets_are_served() -> None:
    stylesheet = client.get("/static/styles.css")
    script = client.get("/static/app.js")

    assert stylesheet.status_code == 200
    assert stylesheet.headers["content-type"].startswith("text/css")
    assert script.status_code == 200
    assert script.headers["content-type"].split(";", maxsplit=1)[0] in {
        "application/javascript",
        "text/javascript",
    }
    assert 'fetchJson("/profiles")' in script.text
    assert 'fetchJson("/predict"' in script.text


def test_swagger_contract_is_preserved() -> None:
    response = client.get("/docs")

    assert response.status_code == 200
    assert "swagger-ui" in response.text


def test_dashboard_does_not_expose_infrastructure_identifiers() -> None:
    response = client.get("/")

    assert "251538491265" not in response.text
    assert "i-049bfd217926eb2b2" not in response.text


def test_dashboard_copy_does_not_expose_api_routes() -> None:
    response = client.get("/")

    for route in ("/health", "/ready", "/profiles", "/predict", "/docs"):
        assert route not in response.text
