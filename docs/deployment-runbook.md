# Deployment Runbook

All commands assume the operator's own SSH access to the EC2 node
(`ssh -i <your-key>.pem ec2-user@184.73.3.54`). Never copy the key into the
repository. Jenkins uses its own credential `aws-ec2-ssh`.

## 1. Prerequisites (one-time, already in place)

| Item | Value |
|---|---|
| Jenkins | `http://localhost:8080`, Windows service running as `LocalSystem` |
| Jenkins credentials | `dockerhub-creds` (username + Docker Hub Read/Write PAT), `aws-ec2-ssh` (SSH username + private key) |
| Jenkins jobs | `Healthcare-CI-CD` (`Jenkinsfile`), `Healthcare-Blue-Green` (`pipelines/blue-green.Jenkinsfile`), `Healthcare-DevSecOps` (`pipelines/devsecops.Jenkinsfile`) – all "Pipeline script from SCM", branch `*/main`, no triggers, concurrent builds disabled |
| EC2 | `i-00f631df0f5cf81d8`, public IP `184.73.3.54`, private IP `172.31.25.50`, K3s, `ec2-user` with passwordless `sudo kubectl` |
| Security group | SSH 22 from the operator's /32 only; 6443 and NodePorts closed to the internet |
| Scanner images (pulled automatically) | `ghcr.io/aquasecurity/trivy:0.76.1`, `ghcr.io/gitleaks/gitleaks:v8.30.1`, `ghcr.io/zaproxy/zaproxy:2.16.1`; Semgrep/pip-audit built from `ci/security/tools.Dockerfile` |

If the EC2 public IP or host key ever changes, update `EC2_HOST` /
`EC2_HOSTKEY_FP` in the Jenkinsfiles **after verifying the new instance** –
the pipelines refuse to connect otherwise.

## 2. Activity 7 – rolling CI/CD release

Jenkins → `Healthcare-CI-CD` → **Build Now**. Result: image
`niranjanbalaguru/healthcare-app:<build>-<sha>` (+ `latest`) rolled out to
`healthcare-deployment` and smoke-tested through `healthcare-rolling-service`.

## 3. Activity 8 – blue-green release

Jenkins → `Healthcare-Blue-Green` → **Build with Parameters**:

| Parameter | Normal release | Notes |
|---|---|---|
| `ACTION` | `deploy` | `rollback` = switch production back to the previous environment |
| `REPLICAS` | `2` | 1–4; node capacity is checked first |
| `MONITOR_SECONDS` | `60` | Post-switch monitoring window |
| `ROLLBACK_REASON` | – | Used with `ACTION=rollback` |
| `SIMULATE_FAILED_VALIDATION` | `false` | Negative test: breaks the candidate's readiness probe |
| `SIMULATE_POST_SWITCH_FAILURE` | `false` | Negative test: forces post-switch monitoring to fail → automatic rollback |

### Inspect the current state

```bash
sudo kubectl -n healthcare get deployments,pods,services,endpointslices -o wide
sudo kubectl -n healthcare get service healthcare-service -o jsonpath='{.spec.selector}{"\n"}'
sudo kubectl -n healthcare get service healthcare-service -o json | python3 -c \
  'import json,sys; a=json.load(sys.stdin)["metadata"]["annotations"]; [print(k,"=",v) for k,v in sorted(a.items()) if k.startswith("healthcare.pbl")]'
curl -s http://127.0.0.1:30060/version     # production
curl -s http://127.0.0.1:30061/version     # Activity 7 rolling environment
```

### Manual rollback

Preferred: run the job with `ACTION=rollback`. It refuses unless the
previous environment still runs the **recorded, previously verified** image
and all its pods are Ready, and it verifies production afterwards.

Emergency manual equivalent (only if Jenkins is unavailable):

```bash
sudo kubectl -n healthcare patch service healthcare-service --type merge \
  -p '{"spec":{"selector":{"app":"healthcare","environment":"blue"}}}'   # or green
curl -s http://127.0.0.1:30060/version
```

Record the reason and update the `healthcare.pbl/*` annotations afterwards
(the next pipeline run reads them).

### Stuck deploy lock

The lock expires automatically after 45 minutes. To inspect it:

```bash
sudo kubectl -n healthcare get configmap healthcare-deploy-lock -o jsonpath='{.data}{"\n"}'
```

Delete it only after confirming that no `Healthcare-CI-CD` or
`Healthcare-Blue-Green` build is running.

## 4. Activity 9 – security pipeline

Jenkins → `Healthcare-DevSecOps` → **Build with Parameters**
(`PUBLISH_VERIFIED_IMAGE=true` pushes `sec-<build>-<sha>` only if the gate
passes). Evidence: build **Artifacts** → `reports/` (security-report.md,
security-summary.json, raw scanner JSON/HTML, SBOM, JUnit).

### Managing exceptions

Edit `ci/security/security-policy.yaml` through a reviewed commit. Each entry
needs `id`, `control`, `severity`, `packages` (where applicable), `reason`,
`mitigation`, `owner`, `approved_by`, `approved_on`, `expires`. Expired or
incomplete entries are ignored by the gate.

## 5. Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| `UNPROTECTED PRIVATE KEY FILE` | Key ACL not restricted | Handled by `Protect-PrivatePath`; check the `icacls` output in the log |
| `HOST KEY MISMATCH` | IP now belongs to another host, or the instance was replaced | Stop; verify the instance in the AWS console before updating the pin |
| `poll failed with exit 255; retry n/6` | Transient network drop | The remote job keeps running detached; polling resumes automatically (bounded) |
| `deploy lock held by ...` | Another deployment is running | Wait; the stage waits for at most 5 minutes |
| `SECURITY GATE: TOOL-ERROR` | A scanner crashed or produced no report | Inspect that stage's log; never treat as a pass |
| Docker Hub pulls fail with `incorrect username or password` | Docker Desktop's signed-in session on the laptop is stale | Sign in to Docker Desktop again (pipelines pull scanners from GHCR) |
