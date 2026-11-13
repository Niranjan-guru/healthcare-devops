# Architecture

## 1. Overview

```mermaid
flowchart LR
    dev[Developer<br/>Windows laptop] -->|git push main| gh[(GitHub<br/>Niranjan-guru/healthcare-devops)]
    subgraph laptop[Windows laptop]
        jenkins[Jenkins 2.580.2<br/>service: LocalSystem]
        docker[Docker Desktop 29.5]
        jenkins --> docker
    end
    gh -->|Pipeline script from SCM| jenkins
    docker -->|push immutable tags| hub[(Docker Hub<br/>niranjanbalaguru/healthcare-app)]
    jenkins -->|SSH 22 only, pinned host key<br/>sudo kubectl on the node| ec2
    subgraph aws[AWS us-east-1]
        subgraph ec2[EC2 i-00f631df0f5cf81d8 t3.small - K3s v1.36.5]
            subgraph ns[namespace healthcare]
                rolling[Deployment healthcare-deployment<br/>environment=rolling - Activity 7]
                blue[Deployment healthcare-blue<br/>environment=blue - Activity 8]
                green[Deployment healthcare-green<br/>environment=green - Activity 8]
                prod{{Service healthcare-service<br/>NodePort 30060 - production}}
                preview{{Service healthcare-preview-service<br/>ClusterIP - candidate}}
                rsvc{{Service healthcare-rolling-service<br/>NodePort 30061}}
            end
        end
    end
    hub -->|image pull| ec2
    prod -. selector environment=active .-> blue
    prod -.-> green
    preview -. candidate .-> green
    rsvc --> rolling
```

* The K3s API (6443) is **not** exposed; all `kubectl` commands run on the
  node through SSH. The security group allows SSH (22) from one /32 only and
  does not expose the NodePorts; all HTTP tests run on the node itself.
* No kubeconfig is ever copied to Windows.

## 2. Components

| Component | Purpose |
|---|---|
| `app/app.py` | Flask API: `/`, `/health`, `/version`, `/api/doctors`, `/api/appointments` (synthetic, in-memory data), security headers, JSON error handlers |
| `Dockerfile` | Multi-stage: `base` (python:3.12-slim + security updates + deps), `test` (pytest, non-root), `runtime` (Gunicorn, UID 10001, HEALTHCHECK, `APP_VERSION` baked in) |
| `k8s/` | Activity 7 rolling Deployment + Service; `k8s/blue-green/` Activity 8 Deployments + production/preview Services |
| `Jenkinsfile` | Activity 7 job `Healthcare-CI-CD` |
| `pipelines/blue-green.Jenkinsfile` | Activity 8 job `Healthcare-Blue-Green` |
| `pipelines/devsecops.Jenkinsfile` | Activity 9 job `Healthcare-DevSecOps` |
| `ci/lib.ps1` | Native-command handling, Windows ACL hardening, pinned SSH, detached remote execution, bundle rendering, Docker Hub registry API |
| `ci/stages.ps1` | Stage implementations shared by all three jobs |
| `ci/security.ps1` | Activity 9 scanner stages |
| `ci/remote/*.sh` | EC2-side scripts: host verification, rolling deploy, blue-green operations, namespace lock, smoke tests, detached job runner, shared Kubernetes checks |
| `ci/security/` | Security policy, gate evaluator, pinned tools image, OpenAPI description for DAST |

## 3. Kubernetes objects in namespace `healthcare`

| Object | Owner | Selector / labels | Exposure |
|---|---|---|---|
| `healthcare-deployment` | Activity 7 | `app=healthcare, environment=rolling` | via `healthcare-rolling-service` |
| `healthcare-rolling-service` | Activity 7 | `environment=rolling` | NodePort 30061 (node-local tests) |
| `healthcare-blue` / `healthcare-green` | Activity 8 | `environment=blue` / `green` | via the Services below |
| `healthcare-service` | Activity 8 | `app=healthcare, environment=<active>` | **Production**, NodePort 30060 |
| `healthcare-preview-service` | Activity 8 | `environment=<candidate>` | ClusterIP only |
| `healthcare-deploy-lock` (ConfigMap, transient) | Activities 7 and 8 | – | Serialises deployments |

All three Deployments share an identical pod specification (verified by
tests): 2 replicas, RollingUpdate (maxSurge 1, maxUnavailable 0), readiness
and liveness probes on `/health`, requests 50m CPU / 64Mi, limits 300m /
256Mi, pod and container `securityContext` (UID/GID 10001, non-root,
`allowPrivilegeEscalation: false`, all capabilities dropped,
`readOnlyRootFilesystem: true`, seccomp `RuntimeDefault`), memory-backed
`/tmp`, and `automountServiceAccountToken: false`.

## 4. How the three pipelines relate

```mermaid
flowchart TB
    commit[Commit on main] --> a7 & a8 & a9
    a7[Healthcare-CI-CD<br/>Activity 7] -->|tag build-sha<br/>+ latest| hub[(Docker Hub)]
    a8[Healthcare-Blue-Green<br/>Activity 8] -->|tag bg-build-sha| hub
    a9[Healthcare-DevSecOps<br/>Activity 9] -->|tag sec-build-sha<br/>only if gate passes| hub
    a7 -->|rolling update| rolling[environment=rolling]
    a8 -->|inactive env, validate, switch| bg[blue / green + production Service]
    a9 -->|reports, SBOM| artifacts[(Jenkins artifacts)]
    lock{{namespace deploy lock}} --- a7 & a8
```

* The jobs are independent and have no triggers between them, so there are
  no circular or recursive builds. Each has `disableConcurrentBuilds()`.
* Activities 7 and 8 both deploy into `healthcare`, so they share a
  ConfigMap-based lock (Jenkins has no Lockable Resources plugin): creation is
  atomic, the holder is recorded, stale locks expire after 45 min and waiting
  is bounded to 5 min.
* Image tags carry a pipeline prefix because each job has its own build
  counter; without it, two jobs could produce the same tag for different
  images.

## 5. Traceability

| From | To | How |
|---|---|---|
| Git commit | Jenkins build | Checkout verifies the commit equals `origin/main`; build display name contains the short SHA |
| Jenkins build | Docker image | Tag `<prefix><build>-<sha7>`; OCI labels `revision`, `version`, `source` |
| Docker image | Docker Hub | Pushed digest compared with the registry-reported digest |
| Docker image | Application | `APP_VERSION` = image tag, reported by `/version` and verified per pod |
| Image | Kubernetes | Deployment image verified equal to the build image; `kubernetes.io/change-cause` annotation |
| Production state | Service annotations | `healthcare.pbl/active-*`, `previous-*`, `last-operation`, `last-build`, `last-commit`, `rollback-reason` |
| Image | SBOM and scan reports | `sbom-<tag>.cdx.json` and `sbom-metadata.json` (commit, build, image ID) archived with the build |
