
# 1. Image de base
FROM python:3.12-slim

# 2. Configuration Python
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# 3. Dossier de travail
WORKDIR /app

# Apply security updates to the Debian runtime packages in the slim base image.
# In particular, this refreshes zlib1g when the base image lags behind Debian
# security repositories (Trivy otherwise reports fixed HIGH CVEs).
# The package is intentionally upgraded to the repository's current security
# version rather than pinned to a stale Debian revision.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends --only-upgrade zlib1g \
    && rm -rf /var/lib/apt/lists/*

# 4. Installer les dependances
COPY requirements-api.txt .
RUN pip install --no-cache-dir --default-timeout=300 --retries 10 -r requirements-api.txt

# 5. Copier l'application
COPY app/ ./app/

# 6. Copier le modele entraine
COPY models/model.joblib ./models/model.joblib

# 7. Port utilise par FastAPI
EXPOSE 8000
# Creer un utilisateur non-root
RUN groupadd --gid 1000 appgroup \
    && useradd --uid 1000 --gid appgroup --create-home appuser

# Executer FastAPI sans privileges root
USER 1000:1000
# 8. Demarrer l'API
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

