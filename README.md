# Healthcare Appointment Management – DevOps PBL-III

An academic DevOps project: a small Flask API for **synthetic** healthcare
appointments, delivered by three Jenkins pipelines to a K3s Kubernetes
cluster on AWS EC2.

> **Disclaimer.** This is a demonstration system that uses synthetic data only.
> It is not production healthcare software and makes no claim of HIPAA or any
> other regulatory compliance.

| Activity | Jenkins job | Jenkinsfile | Purpose |
|---|---|---|---|
| 7 | `Healthcare-CI-CD` | [`Jenkinsfile`](Jenkinsfile) | CI/CD with a rolling update |
| 8 | `Healthcare-Blue-Green` | [`pipelines/blue-green.Jenkinsfile`](pipelines/blue-green.Jenkinsfile) | Blue-green release, switch and rollback |
| 9 | `Healthcare-DevSecOps` | [`pipelines/devsecops.Jenkinsfile`](pipelines/devsecops.Jenkinsfile) | Security-integrated pipeline with a policy gate |

## Application

| Endpoint | Description |
|---|---|
| `GET /` | Browser: the **hospital web frontend** (doctors, booking, appointments, live deployment banner). API clients: JSON metadata |
| `GET /api/deployment` | Environment (blue / green / rolling), version and pod that served the request |
| `GET /health` | Health check (used by Docker and Kubernetes probes) |
| `GET /version` | Deployed version (= image tag) |
| `GET /api/doctors` | Synthetic doctors |
| `GET/POST /api/appointments` | List / create synthetic appointments (validated input) |

Python 3.12-slim, Flask 3.1.3, Gunicorn 23.0.0. The image runs as non-root
UID 10001, exposes port 5000, has a HEALTHCHECK, and bakes `APP_VERSION` in
at build time. Appointments are stored **in memory only**.

## Repository layout

```
app/                     Flask application and runtime requirements
tests/                   71 pytest tests (app, manifests, security gate)
Dockerfile               base / test / runtime stages
k8s/                     Activity 7 rolling Deployment + Service, namespace
k8s/blue-green/          Activity 8 blue/green Deployments, production + preview Services
Jenkinsfile              Activity 7 pipeline
pipelines/               Activity 8 and 9 pipelines
ci/lib.ps1, stages.ps1   Shared Windows-side pipeline logic
ci/security.ps1          Activity 9 scanner stages
ci/security/             Security policy, gate evaluator, tools image, OpenAPI spec for DAST
ci/remote/               Scripts executed on the EC2 node (deploy, blue-green, lock, smoke tests, job runner)
docs/                    Documentation (below)
```

## Documentation

* [Architecture](docs/architecture.md)
* [Activity 7 – CI/CD](docs/activity-7-cicd.md)
* [Activity 8 – Blue-Green deployment](docs/activity-8-blue-green.md)
* [Activity 9 – DevSecOps](docs/activity-9-devsecops.md)
* [Security policy and exceptions](docs/security-policy.md)
* [Testing and validation](docs/testing-and-validation.md)
* [Deployment runbook](docs/deployment-runbook.md)

## Frontends

* **Hospital frontend** – served by the application itself at `/` (see `app/templates`,
  `app/static`). The coloured banner shows which environment, version and pod served
  the page and refreshes every 3 s, so blue/green switches are visible live.
* **Blue-Green control panel** – a local-only tool in
  [`tools/bluegreen-control-panel`](tools/bluegreen-control-panel/README.md) with
  *Turn ON Blue / Turn ON Green* buttons that run the Blue-Green pipeline
  (`ACTION=activate`, optional `STOP_PREVIOUS`).

## Run the tests locally

```bash
docker build --target test -t healthcare-app-test .
docker run --rm --network none healthcare-app-test
```

## Security notes

* Never commit credentials. `.gitignore` excludes `*.pem`, `*.key`, `.env`,
  kubeconfig files and pipeline report output.
* Jenkins credentials (`dockerhub-creds`, `aws-ec2-ssh`) are bound only to
  the stages that need them; temporary key and Docker config files are
  ACL-restricted to `NT AUTHORITY\SYSTEM` and removed after use.
* The Kubernetes API is not exposed; deployments run `sudo kubectl` on the
  node over SSH with a pinned host key and a verified instance identity.
