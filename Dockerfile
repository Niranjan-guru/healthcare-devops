# ---------------------------------------------------------------------------
# base: runtime dependencies shared by the test and runtime stages
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS base

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Apply available Debian security updates to the base image packages
# (Activity 9: Trivy reported fixable HIGH findings, e.g. apt and zlib1g).
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY app/requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

# ---------------------------------------------------------------------------
# test: application + manifest tests (built with --target test, run by CI)
# ---------------------------------------------------------------------------
FROM base AS test

COPY requirements-dev.txt /tmp/requirements-dev.txt
RUN pip install --no-cache-dir -r /tmp/requirements-dev.txt

WORKDIR /src
COPY pytest.ini .
COPY app/ app/
COPY tests/ tests/
COPY k8s/ k8s/

# Tests do not need root either (Semgrep dockerfile.security.missing-user).
RUN useradd --create-home --uid 10001 tester
USER 10001

CMD ["python", "-m", "pytest", "-v", "-p", "no:cacheprovider"]

# ---------------------------------------------------------------------------
# runtime: the deployable image (default target)
# ---------------------------------------------------------------------------
FROM base AS runtime

ARG APP_VERSION=1.0.0
ENV APP_VERSION=${APP_VERSION}

COPY app/ .

# Create a non-root application user
RUN useradd --create-home --uid 10001 appuser

USER 10001

EXPOSE 5000

# Container health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --start-interval=2s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=4)"

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--threads", "2", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
