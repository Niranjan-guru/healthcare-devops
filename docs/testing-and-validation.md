# Testing and Validation

Only results that were actually executed are listed. "Local" means run by
the engineer on the Windows workstation before spending a Jenkins build.

## 1. Automated test suite (71 tests, `pytest` in the `test` Docker stage)

| File | Tests | Covers |
|---|---|---|
| `tests/test_app.py` | 32 | Endpoints, version from environment, synthetic doctors, appointment creation and validation (types, ISO dates, length, non-JSON, arrays, unknown doctor), security headers, JSON 404/405, no leakage of exception details |
| `tests/test_manifests.py` | 24 | Namespace; rolling Deployment/Service; blue/green labels and selectors; identical pod specs; disjoint selectors; production/preview Services; probes; resources; container and pod security (read-only root FS, seccomp, UID/GID, no host access, no SA token) |
| `tests/test_security_policy.py` | 15 | Security gate: tool errors (missing/crashed scanner, malformed/missing report, empty scan, missing SBOM), blocking findings, exception validity/expiry/scope, blanket-exception rejection, WARN behaviour |

Mutation checks performed locally: making `/health` report `DOWN` and
removing the `doctor_id` type validation made 4 tests fail, confirming the
tests detect regressions.

## 2. Static validation

| Check | Method | Result |
|---|---|---|
| Jenkinsfiles | Jenkins Declarative linter (`/pipeline-model-converter/validate`) | All three: "successfully validated" |
| PowerShell | `Parser::ParseFile` on `ci/*.ps1` | 0 parse errors |
| Bash | `bash -n` on `ci/remote/*.sh` | OK |
| Kubernetes YAML | `kubectl apply --dry-run=server` against K3s (read-only) | All manifests accepted; the immutable-selector rejection of the old rolling Deployment confirmed the need for the migration |
| Secrets | Staged-diff scan before every commit; Gitleaks over full history | 0 findings |

## 3. Local pre-validation (before Jenkins builds)

| Item | Outcome |
|---|---|
| Windows private-key ACL fix | Reproduced `UNPROTECTED PRIVATE KEY FILE` with `BUILTIN\Users:(RX)`, then fixed – SSH exit 0 |
| Host-key pin / identity | Wrong fingerprint refused; wrong instance ID refused |
| Remote kubectl queries | Run read-only against `kube-system/coredns`; found the `read` + `set -e` bug before it reached Jenkins |
| Detached remote execution | Streaming, stderr, partial last line, exit-code propagation, timeout kill, idempotent start – all verified on the EC2 host; found and fixed a marker bug |
| Security pipeline end-to-end | All controls run locally; found 4 integration problems (GNU tar on PATH, Semgrep empty-scan blind spot, PowerShell `@($null)` count, ZAP requiring a mounted `/zap/wrk`) and fixed them |
| DAST target | App ran under `--read-only --tmpfs /tmp`, which validated the read-only root filesystem change |

## 4. Jenkins executions

### Healthcare-CI-CD (Activity 7)

| Build | Commit | Result | Notes |
|---|---|---|---|
| #6 | `eeed966` | SUCCESS | Activity 7 baseline (32 tests) |
| #7 | `5d27aeb` | SUCCESS | Migration to `environment=rolling`; deploy lock; 42 tests |
| #8 | `c02986f` | SUCCESS | Hardened pods; 56 tests |
| #9 | `0d720d8` | SUCCESS | 71 tests; 2/2 Ready; 9/9 smoke tests |

### Healthcare-Blue-Green (Activity 8)

See [activity-8-blue-green.md §5](activity-8-blue-green.md): 8 builds,
including the promotion (#2), the manual rollback (#4), the failed-validation
block (#5), the automatic rollback (#7) and the final release (#8).

### Healthcare-DevSecOps (Activity 9)

| Build | Commit | Result | Gate |
|---|---|---|---|
| #1 | `c02986f` | SUCCESS | PASS (container PASS-WITH-EXCEPTIONS, K8s and DAST WARN) |
| #2 | `0d720d8` | SUCCESS | PASS; 71 tests; `sec-2-0d720d8` published |

## 5. Smoke tests (every deployment)

`/health` 200 HEALTHY with the expected version · `/` 200 · `/version`
×10 (all replicas) · `/api/doctors` 200 with 3 synthetic doctors · POST `{}`
→ 400 · invalid date → 400 · string `doctor_id` → 400 · unknown doctor →
404 · valid synthetic appointment → 201. Always run from the EC2 node
against a Kubernetes Service; no inbound port was opened for testing.

## 6. Final independent verification (engineer's own SSH session)

* Production selector `environment=green`; endpoints = the 2 green pod IPs; `bg-8-ae90509`.
* Blue `bg-1-5d27aeb` 2/2 (rollback target); rolling `9-0d720d8` 2/2.
* In-pod: `uid=10001`, root filesystem read-only, `/tmp` writable; seccomp
  RuntimeDefault; no SA token.
* HTTP: `/health` 200 with `nosniff` and CSP headers; `/api/doctors` 200;
  invalid POST 400; valid synthetic POST 201.
* No deploy lock left; no remote temp directories; `default` and
  `kube-system` workloads unchanged.
