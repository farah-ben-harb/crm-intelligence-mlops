# Mini CRM Intelligence Dashboard

The FastAPI application now serves a responsive English dashboard at `/`. It
is designed for product demonstrations while keeping the API contract
unchanged.

## Launch locally

```bash
python -m pip install -r requirements-api.txt -r requirements-dev.txt
uvicorn app.main:app --reload
```

Open <http://127.0.0.1:8000/> for the dashboard and
<http://127.0.0.1:8000/docs> for the interactive API documentation.

## Demonstration flow

1. Open **Profiles** to review the three synthetic, in-memory profiles returned
   by `GET /profiles`.
2. Enter a real skill set in **AI Prediction** and select **Predict domain**.
   The result is returned by `POST /predict`; the browser does not fabricate a
   confidence score or business metric.
3. Review **System Health**. Liveness and model readiness come directly from
   `GET /health` and `GET /ready`.
4. Review **Model Details** for the source, version and SHA-256 returned by
   `GET /model-info`. The SHA can be copied for an audit note.

The UI uses same-origin requests only. If the API or model is unavailable, the
dashboard displays an explicit unavailable state instead of placeholder data.
Profiles are intentionally not persistent CRM records; this remains a
demonstration classifier rather than a CRUD application.

## Screenshot

For a local capture, run the API first and use a browser screenshot tool against
`http://127.0.0.1:8000/`. A reference capture can be stored under
`docs/assets/` for presentation material; it is not used by the application.

## Validation

```bash
python -m pytest -q
python -m ruff check .
```

The dashboard is included in the existing API container because `app/static/`
is copied with the FastAPI application. No AWS resource or production release
is triggered by this feature.
