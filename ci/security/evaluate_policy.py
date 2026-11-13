"""Security gate for the Activity 9 DevSecOps pipeline.

Reads the raw scanner reports produced by the pipeline, applies the release
policy in security-policy.yaml (including explicitly approved, unexpired,
finding-specific exceptions) and writes:

  security-summary.json  machine-readable gate result
  security-report.md     human-readable report for evaluators

Exit code 0 = release allowed, 1 = policy violated, 2 = tool/report error.
A scanner that crashed, or a report that is missing or unparsable, is a
TOOL-ERROR and always fails the gate: it is never treated as "no findings".
"""
from __future__ import annotations

import datetime as dt
import json
import sys
from collections import Counter
from pathlib import Path

import yaml

REQUIRED_EXCEPTION_FIELDS = (
    "id", "control", "severity", "reason", "mitigation", "owner", "approved_by", "approved_on", "expires",
)

# Exit codes each tool uses for "ran successfully" (findings or not).
TOOL_OK_EXIT_CODES = {
    "gitleaks": {0, 3},          # 3 = leaks found (configured --exit-code 3)
    "semgrep": {0, 1},           # 1 = findings with --error; >=2 = tool error
    "pip-audit": {0, 1},         # 1 = vulnerabilities found
    "trivy-image": {0},
    "trivy-dockerfile": {0},
    "trivy-k8s": {0},
    "zap-baseline": {0, 1, 2},   # 3 = ZAP failure
    "zap-api": {0, 1, 2},
    "sbom": {0},
}


class ToolError(Exception):
    pass


def load_json(path: Path):
    if not path.is_file():
        raise ToolError(f"report {path.name} is missing")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ToolError(f"report {path.name} is not valid JSON: {exc}") from exc


def tool_exit_code(reports: Path, tool: str) -> int:
    path = reports / f"{tool}.exitcode"
    if not path.is_file():
        raise ToolError(f"{tool} did not record an exit code (did it run?)")
    code = int(path.read_text(encoding="utf-8").strip())
    if code not in TOOL_OK_EXIT_CODES[tool]:
        raise ToolError(f"{tool} exited with {code}, which indicates a tool failure")
    return code


# ---- Finding extraction -------------------------------------------------------
# Each extractor returns a list of dicts: {id, severity, title, location, fix}

def secrets_findings(reports: Path):
    tool_exit_code(reports, "gitleaks")
    data = load_json(reports / "gitleaks.json")
    return [{"id": f["RuleID"], "severity": "CRITICAL", "title": f.get("Description", "secret"),
             "location": f"{f['File']}:{f.get('StartLine')} (commit {f.get('Commit', '')[:7]})",
             "fix": "Remove and rotate the secret"} for f in data]


def sast_findings(reports: Path):
    tool_exit_code(reports, "semgrep")
    data = load_json(reports / "semgrep.json")
    if data.get("errors"):
        raise ToolError(f"semgrep reported {len(data['errors'])} scan error(s)")
    scanned = [p.replace("/src/", "") for p in data.get("paths", {}).get("scanned", [])]
    if "app/app.py" not in scanned or "Dockerfile" not in scanned:
        raise ToolError(f"semgrep did not scan the application sources ({len(scanned)} files scanned); an empty scan is not a pass")
    return [{"id": r["check_id"].split(".")[-1], "severity": r["extra"]["severity"],
             "title": r["extra"]["message"].strip().splitlines()[0][:160],
             "location": f"{r['path'].replace('/src/', '')}:{r['start']['line']}", "fix": r["extra"].get("fix", "")}
            for r in data["results"]]


def dependency_findings(reports: Path):
    tool_exit_code(reports, "pip-audit")
    data = load_json(reports / "pip-audit.json")
    seen, out = set(), []
    for dep in data["dependencies"]:
        for vuln in dep.get("vulns", []):
            key = (dep["name"], vuln["id"])
            if key in seen:
                continue
            seen.add(key)
            out.append({"id": vuln["id"], "severity": "HIGH", "title": f"{dep['name']} {dep['version']} ({', '.join(vuln.get('aliases', []))})",
                        "location": dep["name"], "package": dep["name"], "fix": ", ".join(vuln.get("fix_versions", [])) or "no fix"})
    return out


def trivy_vuln_findings(reports: Path):
    tool_exit_code(reports, "trivy-image")
    data = load_json(reports / "trivy-image.json")
    seen, out = set(), []
    for result in data.get("Results", []):
        for v in result.get("Vulnerabilities") or []:
            key = (v["VulnerabilityID"], v["PkgName"])
            if key in seen:
                continue
            seen.add(key)
            out.append({"id": v["VulnerabilityID"], "severity": v["Severity"], "package": v["PkgName"],
                        "title": f"{v['PkgName']} {v['InstalledVersion']}: {(v.get('Title') or '').strip()[:100]}",
                        "location": result["Class"], "fix": v.get("FixedVersion") or "no fix available"})
        for s in result.get("Secrets") or []:
            out.append({"id": s["RuleID"], "severity": "CRITICAL", "title": "secret in image", "location": result["Target"], "fix": "remove"})
    return out


def trivy_misconfig_findings(reports: Path, tool: str):
    tool_exit_code(reports, tool)
    data = load_json(reports / f"{tool}.json")
    out = []
    for result in data.get("Results", []):
        for m in result.get("Misconfigurations") or []:
            if m.get("Status", "FAIL") != "FAIL":
                continue
            out.append({"id": m["ID"], "severity": m["Severity"], "title": m["Title"],
                        "location": result["Target"], "fix": (m.get("Resolution") or "").strip()})
    return out


ZAP_RISK = {"3": "High", "2": "Medium", "1": "Low", "0": "Informational"}


def dast_findings(reports: Path):
    out = []
    for tool in ("zap-baseline", "zap-api"):
        tool_exit_code(reports, tool)
        data = load_json(reports / f"{tool}.json")
        for site in data.get("site", []):
            for alert in site.get("alerts", []):
                out.append({"id": f"ZAP-{alert['pluginid']}", "severity": ZAP_RISK[alert["riskcode"]],
                            "title": f"{alert['alert']} ({tool}, {alert['count']} instance(s))",
                            "location": site.get("@name", ""), "fix": " ".join(alert.get("solution", "").split())[:200]})
    return out


def sbom_check(reports: Path):
    tool_exit_code(reports, "sbom")
    sboms = sorted(reports.glob("sbom-*.cdx.json"))
    if not sboms:
        raise ToolError("no CycloneDX SBOM was produced")
    data = load_json(sboms[0])
    if data.get("bomFormat") != "CycloneDX" or not data.get("components"):
        raise ToolError(f"{sboms[0].name} is not a populated CycloneDX SBOM")
    return [], {"file": sboms[0].name, "components": len(data["components"]), "spec": data.get("specVersion")}


# ---- Policy ---------------------------------------------------------------------

def valid_exceptions(policy, today):
    valid, problems = [], []
    for exc in policy.get("exceptions") or []:
        missing = [f for f in REQUIRED_EXCEPTION_FIELDS if not str(exc.get(f, "")).strip()]
        if missing:
            problems.append(f"exception {exc.get('id', '?')} ignored: missing {', '.join(missing)}")
            continue
        if str(exc["id"]).strip() in ("*", "ALL"):
            problems.append("blanket exception ignored: exceptions must name one finding")
            continue
        expires = exc["expires"] if isinstance(exc["expires"], dt.date) else dt.date.fromisoformat(str(exc["expires"]))
        if expires < today:
            problems.append(f"exception {exc['id']} ignored: expired on {expires}")
            continue
        valid.append(exc)
    return valid, problems


def matches(exc, control, finding):
    # Exact match on control + finding id + severity; when the exception lists
    # packages, the finding's package must be one of them.
    packages = exc.get("packages") or ([exc["package"]] if exc.get("package") else [])
    return (exc["control"] == control and exc["id"] == finding["id"]
            and str(exc["severity"]).upper() == str(finding["severity"]).upper()
            and (not packages or finding.get("package") in packages))


CONTROLS = [
    ("secrets", "Secret detection", "Gitleaks", secrets_findings),
    ("sast", "Static application security testing", "Semgrep", sast_findings),
    ("dependencies", "Python dependency scanning", "pip-audit", dependency_findings),
    ("container", "Container image scanning", "Trivy (image)", trivy_vuln_findings),
    ("dockerfile", "Dockerfile scanning", "Trivy (config)", lambda r: trivy_misconfig_findings(r, "trivy-dockerfile")),
    ("kubernetes", "Kubernetes manifest scanning", "Trivy (config)", lambda r: trivy_misconfig_findings(r, "trivy-k8s")),
    ("dast", "Dynamic application security testing", "OWASP ZAP", dast_findings),
]


def evaluate(reports: Path, policy_path: Path):
    policy = yaml.safe_load(policy_path.read_text(encoding="utf-8"))
    today = dt.date.today()
    exceptions, exception_problems = valid_exceptions(policy, today)
    used_exceptions = set()
    controls, overall = [], "PASS"

    for key, name, tool, extractor in CONTROLS:
        gate = policy["gates"][key]
        block = {s.upper() for s in gate.get("block", [])}
        entry = {"control": key, "name": name, "tool": tool}
        try:
            findings = extractor(reports)
        except ToolError as exc:
            entry.update(status="TOOL-ERROR", error=str(exc), counts={}, blocking=[], excepted=[], warnings=[])
            controls.append(entry)
            overall = "FAIL"
            continue
        counts = Counter(str(f["severity"]).upper() for f in findings)
        blocking, excepted, warnings = [], [], []
        for f in findings:
            if str(f["severity"]).upper() in block or gate.get("block_any"):
                exc = next((e for e in exceptions if matches(e, key, f)), None)
                if exc:
                    excepted.append({**f, "exception_owner": exc["owner"], "exception_expires": str(exc["expires"])})
                    used_exceptions.add((key, exc["id"]))
                else:
                    blocking.append(f)
            else:
                warnings.append(f)
        status = "FAIL" if blocking else ("PASS-WITH-EXCEPTIONS" if excepted else ("WARN" if warnings else "PASS"))
        if blocking:
            overall = "FAIL"
        entry.update(status=status, counts=dict(sorted(counts.items())), blocking=blocking, excepted=excepted, warnings=warnings)
        controls.append(entry)

    try:
        _, sbom = sbom_check(reports)
        controls.append({"control": "sbom", "name": "Software Bill of Materials", "tool": "Trivy (CycloneDX)",
                         "status": "PASS", "counts": {}, "sbom": sbom, "blocking": [], "excepted": [], "warnings": []})
    except ToolError as exc:
        controls.append({"control": "sbom", "name": "Software Bill of Materials", "tool": "Trivy (CycloneDX)",
                         "status": "TOOL-ERROR", "error": str(exc), "counts": {}, "blocking": [], "excepted": [], "warnings": []})
        overall = "FAIL"

    unused = [e["id"] for e in exceptions if (e["control"], e["id"]) not in used_exceptions]
    return {"overall": overall, "evaluated_on": str(today), "controls": controls,
            "exception_problems": exception_problems, "unused_exceptions": unused}


def write_markdown(result, meta, path: Path):
    lines = [
        "# Security Gate Report - Healthcare-DevSecOps",
        "",
        f"* Image: `{meta.get('image', '')}`",
        f"* Git commit: `{meta.get('commit', '')}`  Jenkins build: `{meta.get('build', '')}`",
        f"* Evaluated: {result['evaluated_on']}",
        f"* **Overall gate result: {result['overall']}**",
        "",
        "| Security control | Tool | Result | Findings by severity | Blocking | Excepted |",
        "|---|---|---|---|---|---|",
    ]
    for c in result["controls"]:
        counts = ", ".join(f"{k}: {v}" for k, v in c["counts"].items()) or ("error: " + c["error"] if "error" in c else "none")
        if c["control"] == "sbom" and "sbom" in c:
            counts = f"{c['sbom']['components']} components ({c['sbom']['file']})"
        lines.append(f"| {c['name']} | {c['tool']} | **{c['status']}** | {counts} | {len(c['blocking'])} | {len(c['excepted'])} |")
    for title, field in (("Blocking findings", "blocking"), ("Findings accepted under approved exceptions", "excepted")):
        rows = [(c["name"], f) for c in result["controls"] for f in c[field]]
        lines += ["", f"## {title} ({len(rows)})", ""]
        if rows:
            lines += ["| Control | ID | Severity | Location | Detail | Fix |", "|---|---|---|---|---|---|"]
            lines += [f"| {n} | {f['id']} | {f['severity']} | {f['location']} | {f['title'].replace('|', '/')} | {str(f.get('fix', '')).replace('|', '/')[:120]} |" for n, f in rows]
        else:
            lines.append("None.")
    warn_rows = [(c["name"], f) for c in result["controls"] for f in c["warnings"]]
    lines += ["", f"## Non-blocking findings reported for tracking ({len(warn_rows)})", ""]
    by_control = Counter((n, str(f["severity"]).upper()) for n, f in warn_rows)
    lines += [f"* {n}: {sev} x {count}" for (n, sev), count in sorted(by_control.items())] or ["None."]
    if result["exception_problems"] or result["unused_exceptions"]:
        lines += ["", "## Exception register problems", ""]
        lines += [f"* {p}" for p in result["exception_problems"]]
        lines += [f"* exception {u} did not match any current finding (review/remove)" for u in result["unused_exceptions"]]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main(argv):
    if len(argv) != 5:
        print("usage: evaluate_policy.py <reports-dir> <policy.yaml> <metadata.json> <output-dir>", file=sys.stderr)
        return 2
    reports, policy_path, meta_path, out = Path(argv[1]), Path(argv[2]), Path(argv[3]), Path(argv[4])
    out.mkdir(parents=True, exist_ok=True)
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    result = evaluate(reports, policy_path)
    result["metadata"] = meta
    (out / "security-summary.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    write_markdown(result, meta, out / "security-report.md")
    print((out / "security-report.md").read_text(encoding="utf-8"))
    if any(c["status"] == "TOOL-ERROR" for c in result["controls"]):
        return 2
    return 0 if result["overall"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
