"""Tests for the Activity 9 security gate (ci/security/evaluate_policy.py).

They prove that scanner failures can never be mistaken for a passing scan
and that exceptions cannot be used as blanket suppressions.
"""
import datetime as dt
import json

import pytest
import yaml

import evaluate_policy as gate

TOOLS_OK = {
    "gitleaks": 0, "semgrep": 0, "pip-audit": 0, "trivy-image": 0,
    "trivy-dockerfile": 0, "trivy-k8s": 0, "zap-baseline": 0, "zap-api": 0, "sbom": 0,
}
HIGH_VULN = {"VulnerabilityID": "CVE-2099-0001", "PkgName": "libdemo", "InstalledVersion": "1.0",
             "Severity": "HIGH", "Title": "synthetic test vulnerability"}


def write(path, data):
    path.write_text(json.dumps(data), encoding="utf-8")


@pytest.fixture()
def reports(tmp_path):
    """A complete, clean set of scanner reports."""
    for tool, code in TOOLS_OK.items():
        (tmp_path / f"{tool}.exitcode").write_text(f"{code}\n", encoding="utf-8")
    write(tmp_path / "gitleaks.json", [])
    write(tmp_path / "semgrep.json", {"results": [], "errors": [],
                                      "paths": {"scanned": ["/src/app/app.py", "/src/Dockerfile"]}})
    write(tmp_path / "pip-audit.json", {"dependencies": [{"name": "flask", "version": "3.1.3", "vulns": []}]})
    write(tmp_path / "trivy-image.json", {"Results": [{"Class": "os-pkgs", "Target": "img", "Vulnerabilities": []}]})
    write(tmp_path / "trivy-dockerfile.json", {"Results": []})
    write(tmp_path / "trivy-k8s.json", {"Results": []})
    for zap in ("zap-baseline", "zap-api"):
        write(tmp_path / f"{zap}.json", {"site": [{"@name": "http://target", "alerts": []}]})
    write(tmp_path / "sbom-test.cdx.json", {"bomFormat": "CycloneDX", "specVersion": "1.6",
                                             "components": [{"name": "flask"}]})
    return tmp_path


def policy(tmp_path, exceptions=()):
    data = {"version": 1, "gates": {
        "secrets": {"block_any": True}, "sast": {"block": ["ERROR"]},
        "dependencies": {"block_any": True}, "container": {"block": ["CRITICAL", "HIGH"]},
        "dockerfile": {"block": ["CRITICAL", "HIGH"]}, "kubernetes": {"block": ["CRITICAL", "HIGH"]},
        "dast": {"block": ["High"]}}, "exceptions": list(exceptions)}
    path = tmp_path / "policy.yaml"
    path.write_text(yaml.safe_dump(data), encoding="utf-8")
    return path


def exception(**overrides):
    base = {"id": "CVE-2099-0001", "control": "container", "severity": "HIGH", "packages": ["libdemo"],
            "reason": "test", "mitigation": "test", "owner": "tester", "approved_by": "tester",
            "approved_on": "2026-01-01", "expires": str(dt.date.today() + dt.timedelta(days=30))}
    base.update(overrides)
    return base


def status(result, control):
    return next(c for c in result["controls"] if c["control"] == control)["status"]


def add_high_vuln(reports):
    write(reports / "trivy-image.json", {"Results": [{"Class": "os-pkgs", "Target": "img", "Vulnerabilities": [HIGH_VULN]}]})


def test_clean_reports_pass(reports, tmp_path):
    result = gate.evaluate(reports, policy(tmp_path))
    assert result["overall"] == "PASS"
    assert all(c["status"] == "PASS" for c in result["controls"])


def test_missing_exit_code_is_tool_error(reports, tmp_path):
    (reports / "semgrep.exitcode").unlink()
    result = gate.evaluate(reports, policy(tmp_path))
    assert status(result, "sast") == "TOOL-ERROR"
    assert result["overall"] == "FAIL"


def test_crash_exit_code_is_tool_error_even_with_empty_report(reports, tmp_path):
    # Gitleaks exit code 1 = crash (findings use the configured code 3).
    (reports / "gitleaks.exitcode").write_text("1\n", encoding="utf-8")
    result = gate.evaluate(reports, policy(tmp_path))
    assert status(result, "secrets") == "TOOL-ERROR"
    assert result["overall"] == "FAIL"


def test_missing_report_is_tool_error(reports, tmp_path):
    (reports / "trivy-image.json").unlink()
    assert status(gate.evaluate(reports, policy(tmp_path)), "container") == "TOOL-ERROR"


def test_malformed_report_is_tool_error(reports, tmp_path):
    (reports / "pip-audit.json").write_text("{not json", encoding="utf-8")
    assert status(gate.evaluate(reports, policy(tmp_path)), "dependencies") == "TOOL-ERROR"


def test_empty_semgrep_scan_is_tool_error(reports, tmp_path):
    write(reports / "semgrep.json", {"results": [], "errors": [], "paths": {"scanned": []}})
    result = gate.evaluate(reports, policy(tmp_path))
    assert status(result, "sast") == "TOOL-ERROR"
    assert result["overall"] == "FAIL"


def test_missing_sbom_is_tool_error(reports, tmp_path):
    (reports / "sbom-test.cdx.json").unlink()
    assert status(gate.evaluate(reports, policy(tmp_path)), "sbom") == "TOOL-ERROR"


def test_detected_secret_blocks(reports, tmp_path):
    (reports / "gitleaks.exitcode").write_text("3\n", encoding="utf-8")
    write(reports / "gitleaks.json", [{"RuleID": "aws-access-token", "File": "x.py", "StartLine": 1,
                                       "Commit": "abcdef0", "Secret": "REDACTED"}])
    result = gate.evaluate(reports, policy(tmp_path))
    assert status(result, "secrets") == "FAIL"
    assert result["overall"] == "FAIL"


def test_high_vulnerability_blocks_without_exception(reports, tmp_path):
    add_high_vuln(reports)
    result = gate.evaluate(reports, policy(tmp_path))
    assert status(result, "container") == "FAIL"
    assert result["overall"] == "FAIL"


def test_valid_exception_allows_release(reports, tmp_path):
    add_high_vuln(reports)
    result = gate.evaluate(reports, policy(tmp_path, [exception()]))
    assert status(result, "container") == "PASS-WITH-EXCEPTIONS"
    assert result["overall"] == "PASS"


def test_expired_exception_is_ignored(reports, tmp_path):
    add_high_vuln(reports)
    result = gate.evaluate(reports, policy(tmp_path, [exception(expires="2020-01-01")]))
    assert status(result, "container") == "FAIL"
    assert any("expired" in p for p in result["exception_problems"])


def test_incomplete_exception_is_ignored(reports, tmp_path):
    add_high_vuln(reports)
    result = gate.evaluate(reports, policy(tmp_path, [exception(approved_by="")]))
    assert status(result, "container") == "FAIL"
    assert any("approved_by" in p for p in result["exception_problems"])


def test_blanket_exception_is_rejected(reports, tmp_path):
    add_high_vuln(reports)
    result = gate.evaluate(reports, policy(tmp_path, [exception(id="*", packages=[])]))
    assert status(result, "container") == "FAIL"
    assert any("blanket" in p for p in result["exception_problems"])


def test_exception_is_scoped_to_listed_packages(reports, tmp_path):
    add_high_vuln(reports)
    result = gate.evaluate(reports, policy(tmp_path, [exception(packages=["some-other-package"])]))
    assert status(result, "container") == "FAIL"


def test_medium_findings_warn_but_do_not_block(reports, tmp_path):
    write(reports / "trivy-k8s.json", {"Results": [{"Target": "k8s/deployment.yaml", "Misconfigurations": [
        {"ID": "KSV-0125", "Severity": "MEDIUM", "Title": "registry", "Status": "FAIL"}]}]})
    result = gate.evaluate(reports, policy(tmp_path))
    assert status(result, "kubernetes") == "WARN"
    assert result["overall"] == "PASS"
