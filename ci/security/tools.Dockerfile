# Pinned Python-based security tooling for the Activity 9 DevSecOps pipeline.
# Built from the same python:3.12-slim base as the application, so it needs
# no additional base image from Docker Hub.
FROM python:3.12-slim
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONDONTWRITEBYTECODE=1 SEMGREP_SEND_METRICS=off
RUN pip install --no-cache-dir semgrep==1.182.1 pip-audit==2.10.1 PyYAML==6.0.2 \
 && useradd --create-home --uid 10002 scanner
USER 10002
WORKDIR /src
