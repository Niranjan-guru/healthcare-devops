# Release Security Policy (Activity 9)

> Academic demonstration. The Healthcare Appointment Management application
> uses **synthetic data only**. It is not production healthcare software and
> no regulatory compliance (HIPAA or otherwise) is claimed.

The policy is enforced automatically by the `Security Policy Evaluation`
stage of the **Healthcare-DevSecOps** Jenkins job. The machine-readable
version is [`ci/security/security-policy.yaml`](../ci/security/security-policy.yaml);
the evaluator is [`ci/security/evaluate_policy.py`](../ci/security/evaluate_policy.py).

## 1. Release gates

| Control | Tool (pinned version) | What blocks a release | What is reported only |
|---|---|---|---|
| Secret detection | Gitleaks v8.30.1 | **Any** detected secret (full Git history) | – |
| SAST | Semgrep 1.182.1 | Severity `ERROR` | `WARNING`, `INFO` |
| Dependencies | pip-audit 2.10.1 | **Any** known vulnerability in a pinned Python dependency | – |
| Container image | Trivy 0.76.1 (image) | `CRITICAL`, `HIGH` | `MEDIUM`, `LOW`, `UNKNOWN` |
| Dockerfile | Trivy 0.76.1 (config) | `CRITICAL`, `HIGH` | `MEDIUM`, `LOW` |
| Kubernetes manifests | Trivy 0.76.1 (config) | `CRITICAL`, `HIGH` | `MEDIUM`, `LOW` |
| DAST | OWASP ZAP 2.16.1 | Risk `High` | `Medium`, `Low`, `Informational` |
| SBOM | Trivy 0.76.1 (CycloneDX) | SBOM missing or empty | – |

## 2. Result categories

Each control receives exactly one result:

| Result | Meaning | Effect |
|---|---|---|
| `PASS` | Scanner ran correctly; no findings | Release allowed |
| `WARN` | Only non-blocking findings | Release allowed; findings listed for tracking |
| `PASS-WITH-EXCEPTIONS` | Blocking-severity findings exist, but **every one** matches an approved exception | Release allowed; each excepted finding is listed |
| `FAIL` | At least one blocking finding without a valid exception | **Build fails** |
| `TOOL-ERROR` | Scanner crashed, returned an error exit code, produced no or invalid report, or scanned nothing | **Build fails**; a crash is never a pass |

Tool-error detection is explicit: each scanner's exit code is recorded and
compared with the codes that tool uses for "ran successfully" (for example,
Gitleaks `0`/`3`, pip-audit `0`/`1`, ZAP `0`/`1`/`2`). Semgrep must report that
it scanned `app/app.py` and `Dockerfile`; an empty scan is a `TOOL-ERROR`.

## 3. Exceptions

An exception is accepted only if **all** of these hold:

* It names a single finding identifier (no `*`/`ALL` – blanket suppressions are rejected).
* It names the control and severity, and optionally the exact affected packages.
* It has `reason`, `mitigation`, `owner`, `approved_by`, `approved_on` and `expires`.
* `expires` is in the future.

Expired or incomplete exceptions are ignored (the finding blocks again) and
reported in the "Exception register problems" section of the security report.
Exceptions that no longer match any finding are reported for removal.

### 3.1 Current exceptions (approved 2026-11-14, expire 2026-12-31)

The required base image `python:3.12-slim` (Debian 13.7) contains 11 HIGH
CVEs (47 package findings) for which **Debian has not published any fix**.
`apt-get upgrade` in the Dockerfile already removed every fixable HIGH
finding. The project owner approved time-limited exceptions after reviewing
this exploitability analysis:

| CVE | Packages | Why it is not reachable | Mitigations in place |
|---|---|---|---|
| CVE-2026-76642, CVE-2026-78408, CVE-2026-78409, CVE-2026-78410 | util-linux family (`bsdutils`, `libblkid1`, `liblastlog2-2`, `libmount1`, `libsmartcols1`, `libuuid1`, `login`, `mount`, `util-linux`) | The application never executes `mount`, `nsenter` or other util-linux tools | UID 10001, all capabilities dropped, `allowPrivilegeEscalation: false` (no setuid gain), read-only root filesystem, seccomp `RuntimeDefault` |
| CVE-2026-54369 | `libacl1` | No privileged process uses libacl on attacker-controlled paths | Non-root, no file/path input in the API |
| CVE-2025-69720 | `libncursesw6`, `libtinfo6`, `ncurses-base`, `ncurses-bin` | No terminal UI; curses never loaded | No TTY in pods |
| CVE-2026-119373, CVE-2026-119374, CVE-2026-119379 | `libsqlite3-0` | Data is held in memory; SQLite is never opened | No database input reachable |
| CVE-2026-16742 | `libsystemd0`, `libudev1` | No systemd / homed daemon in the container | No init system; non-root |
| CVE-2026-9538 | `perl-base` | Perl and Archive::Tar are never used | Non-root, read-only root filesystem |

These CVEs remain **unresolved vulnerabilities**: the image is *not*
vulnerability-free. Any **new** HIGH or CRITICAL finding, or one of these CVEs
appearing in a different package, still fails the build. The exceptions must
be reviewed before 2026-12-31 and removed as soon as a fixed base image exists.

## 4. Remediated findings (true positives fixed)

| Source | Finding | Severity | Location | Fix |
|---|---|---|---|---|
| pip-audit | CVE-2026-27205 (PYSEC-2026-2151) in Flask 3.1.2 – direct runtime dependency | blocking | `app/requirements.txt` | Upgraded to Flask 3.1.3 |
| pip-audit | CVE-2025-71176 (PYSEC-2026-1845) in pytest 8.3.5 – dev/test only | blocking | `requirements-dev.txt` | Upgraded to pytest 9.0.3 |
| Semgrep | `avoid_app_run_with_bad_host` | WARNING | `app/app.py` (dev server) | Binds to `127.0.0.1` by default |
| Semgrep | `dockerfile.security.missing-user` | ERROR | `Dockerfile` test stage | Test stage runs as UID 10001 |
| Trivy image | Fixable HIGHs in `apt`, `zlib1g` | HIGH | base image | `apt-get upgrade` in base stage |
| Trivy config | KSV-0014 writable root filesystem | HIGH | all Deployments | `readOnlyRootFilesystem: true` + memory `emptyDir` for `/tmp` |
| Trivy config | KSV-0118 no pod security context | HIGH | all Deployments | Pod `securityContext` |
| Trivy config | KSV-0021 GID ≤ 10000 | LOW | all Deployments | `runAsGroup: 10001` |
| Trivy config | KSV-0030 / KSV-0104 seccomp | LOW / MEDIUM | all Deployments | `seccompProfile: RuntimeDefault` |
| (hardening) | Service-account token mounted unnecessarily | – | all Deployments | `automountServiceAccountToken: false` |
| OWASP ZAP | 10021 X-Content-Type-Options missing | Low | all responses | `nosniff` header |
| OWASP ZAP | 10038 CSP header not set | Medium | all responses | `default-src 'none'; frame-ancestors 'none'` |
| OWASP ZAP | 100001 unexpected content type (HTML error pages) | Low | 404/405 responses | JSON-only error handlers |

## 5. Accepted non-blocking findings

| Finding | Severity | Decision |
|---|---|---|
| KSV-0125 "Restrict container images to trusted registries" | MEDIUM | Report and track. Images come from the project's own Docker Hub repository with immutable tags; registry allow-listing needs an admission controller, which is out of scope for this single-node academic cluster. |
| ZAP 100000 "A client error response code was returned" | Informational | Expected: the API scan sends invalid input and the API correctly answers 4xx. |
| MEDIUM / LOW / UNKNOWN OS-package CVEs | MEDIUM / LOW | Report and track. |

## 6. Secret handling rules

* Credentials live only in Jenkins (`dockerhub-creds`, `aws-ec2-ssh`) and are bound per stage.
* Docker Hub login uses an isolated, ACL-restricted temporary `DOCKER_CONFIG`, deleted afterwards.
* The SSH private key file is restricted to `NT AUTHORITY\SYSTEM` before use.
* Gitleaks reports are generated with `--redact`; every report is scanned for
  key/token patterns before it is archived, and archiving is refused on a match.
* `.gitignore` excludes `*.pem`, `*.key`, `*.ppk`, `id_rsa*`, `id_ed25519*`, `.env`,
  kubeconfig files, `known_hosts` and `reports/`.
