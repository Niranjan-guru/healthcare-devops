"""Blue-Green control panel (local showcase tool for Activity 8).

Runs on the operator's laptop only (bound to 127.0.0.1). It never changes the
cluster directly: the "Turn ON" buttons trigger the Healthcare-Blue-Green
Jenkins job (ACTION=activate), which validates the environment, switches the
production Service and (optionally) turns the previous environment OFF.

Read-only status comes from the K3s node over SSH (pinned host key) and the
live production view through a localhost-only SSH tunnel.

Usage:
    python server.py --key C:\\path\\to\\devops-lab-key.pem
Then open http://127.0.0.1:8090/

Secrets: the Jenkins API token is read from ~/.jenkins-api-token
("username:token") inside this process and is never sent to the browser.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import pathlib
import re
import secrets
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = pathlib.Path(__file__).resolve().parent
STATIC = HERE / "static"
JOB = "Healthcare-Blue-Green"
EC2_HOST = "184.73.3.54"
EC2_USER = "ec2-user"
HOSTKEY_FP = "SHA256:B4W0XuwdBWHb4H78QudSeZPiNrVAm79DNNkZPggq0RU"   # same pin as the pipelines
PROD_NODEPORT = 30060
TUNNEL_PORT = 18060

# Read-only cluster query executed on the node (python3 is available there).
STATE_SCRIPT = r'''
import json, subprocess
def kc(*a):
    return json.loads(subprocess.check_output(["sudo", "-n", "kubectl", "-n", "healthcare", *a, "-o", "json"]))
out = {"environments": {}}
svc = kc("get", "service", "healthcare-service")
ann = svc["metadata"].get("annotations", {})
out["production"] = {"selector": svc["spec"]["selector"],
                     "annotations": {k.split("/", 1)[1]: v for k, v in ann.items() if k.startswith("healthcare.pbl/")}}
for env in ("blue", "green"):
    try:
        d = kc("get", "deployment", "healthcare-" + env)
    except subprocess.CalledProcessError:
        out["environments"][env] = None
        continue
    a = d["metadata"].get("annotations", {})
    out["environments"][env] = {
        "desired": d["spec"].get("replicas", 0), "ready": d.get("status", {}).get("readyReplicas", 0),
        "image": d["spec"]["template"]["spec"]["containers"][0]["image"],
        "verified_image": a.get("healthcare.pbl/verified-image", ""),
        "verified_version": a.get("healthcare.pbl/verified-version", ""),
        "stopped": a.get("healthcare.pbl/stopped", "") == "true"}
lock = subprocess.run(["sudo", "-n", "kubectl", "-n", "healthcare", "get", "configmap", "healthcare-deploy-lock",
                       "-o", "jsonpath={.data.holder}"], capture_output=True, text=True)
out["lock"] = lock.stdout.strip() if lock.returncode == 0 else ""
print(json.dumps(out))
'''


class Panel:
    def __init__(self, key: pathlib.Path, jenkins: str, token_file: pathlib.Path):
        self.key = key
        # Only plain http(s) to a host is accepted, so urllib can never be
        # pointed at file:// or other schemes (Semgrep dynamic-urllib-use).
        parsed = urllib.parse.urlparse(jenkins)
        if parsed.scheme not in ("http", "https") or not parsed.hostname:
            raise SystemExit(f"--jenkins must be an http(s) URL, got {jenkins!r}")
        self.jenkins = jenkins.rstrip("/")
        raw = token_file.read_text(encoding="utf-8").strip()
        if not re.fullmatch(r"[^:\s]+:\S+", raw):
            raise SystemExit(f"{token_file} must contain one line 'username:token'")
        self._auth = "Basic " + base64.b64encode(raw.encode()).decode()
        self.csrf = secrets.token_urlsafe(24)
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="bg-panel-"))
        self.known_hosts = self.tmp / "known_hosts"
        self._pin_host_key()
        self._tunnel = None
        self._tunnel_lock = threading.Lock()
        self._state_cache = (0.0, None)

    # ---- SSH --------------------------------------------------------------------
    def _pin_host_key(self):
        scan = subprocess.run(["ssh-keyscan", "-T", "10", "-t", "ed25519", EC2_HOST], capture_output=True, text=True, timeout=30)
        line = next((l for l in scan.stdout.splitlines() if re.match(r"^\S+\s+ssh-ed25519\s+\S+$", l.strip())), None)
        if not line:
            raise SystemExit(f"Could not read the SSH host key of {EC2_HOST}")
        self.known_hosts.write_text(line.strip() + "\n", encoding="ascii")
        fp = subprocess.run(["ssh-keygen", "-l", "-E", "sha256", "-f", str(self.known_hosts)], capture_output=True, text=True).stdout
        if HOSTKEY_FP not in fp:
            raise SystemExit(f"HOST KEY MISMATCH for {EC2_HOST}: refusing to connect")

    def _ssh_base(self):
        return ["ssh", "-i", str(self.key), "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={self.known_hosts.as_posix()}",
                "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "LogLevel=ERROR"]

    def cluster_state(self):
        now = time.time()
        if self._state_cache[1] is not None and now - self._state_cache[0] < 4:
            return self._state_cache[1]
        try:
            r = subprocess.run(self._ssh_base() + [f"{EC2_USER}@{EC2_HOST}", "python3", "-"], input=STATE_SCRIPT,
                               capture_output=True, text=True, timeout=30)
            state = json.loads(r.stdout) if r.returncode == 0 else {"error": "cluster query failed (ssh exit %d)" % r.returncode}
        except (subprocess.TimeoutExpired, ValueError) as exc:
            state = {"error": f"cluster query failed: {type(exc).__name__}"}
        self._state_cache = (now, state)
        return state

    def ensure_tunnel(self):
        with self._tunnel_lock:
            if self._tunnel and self._tunnel.poll() is None:
                return
            self._tunnel = subprocess.Popen(
                self._ssh_base() + ["-N", "-o", "ExitOnForwardFailure=yes",
                                    "-L", f"127.0.0.1:{TUNNEL_PORT}:127.0.0.1:{PROD_NODEPORT}", f"{EC2_USER}@{EC2_HOST}"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(2)

    def live(self):
        self.ensure_tunnel()
        base = f"http://127.0.0.1:{TUNNEL_PORT}"
        try:
            with urllib.request.urlopen(f"{base}/api/deployment", timeout=4) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                return {"error": f"production returned HTTP {exc.code}"}
            # Releases built before the frontend have no /api/deployment:
            # use /version and the live Service selector instead.
            try:
                with urllib.request.urlopen(f"{base}/version", timeout=4) as resp:
                    version = json.loads(resp.read())["version"]
            except Exception as inner:
                return {"error": f"production unreachable ({type(inner).__name__})"}
            selector = (self.cluster_state().get("production") or {}).get("selector", {})
            return {"version": version, "environment": selector.get("environment", "unknown"),
                    "pod": "(release predates the frontend)"}
        except Exception as exc:  # reported to the UI as "unreachable"
            return {"error": f"production unreachable ({type(exc).__name__})"}

    # ---- Jenkins ------------------------------------------------------------------
    def _jenkins(self, path, method="GET", data=None):
        req = urllib.request.Request(self.jenkins + path, method=method, data=data, headers={"Authorization": self._auth})
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read()
            return resp.status, (json.loads(body) if body and resp.headers.get_content_type() == "application/json" else None)

    def jenkins_state(self):
        try:
            _, job = self._jenkins(f"/job/{JOB}/api/json?tree=inQueue,lastBuild[number,building,result,displayName,description,url,duration]")
            return {"in_queue": job.get("inQueue", False), "last_build": job.get("lastBuild")}
        except (urllib.error.URLError, OSError) as exc:
            return {"error": f"Jenkins unreachable ({type(exc).__name__})"}

    def trigger(self, params: dict):
        state = self.jenkins_state()
        if "error" in state:
            return 502, {"error": state["error"]}
        last = state.get("last_build") or {}
        if state["in_queue"] or last.get("building"):
            return 409, {"error": "A Healthcare-Blue-Green build is already queued or running. Wait for it to finish."}
        query = urllib.parse.urlencode(params)
        status, _ = self._jenkins(f"/job/{JOB}/buildWithParameters?{query}", method="POST", data=b"")
        return (202, {"message": f"Jenkins build queued: {query}"}) if status in (200, 201) else (502, {"error": f"Jenkins returned {status}"})

    def close(self):
        if self._tunnel and self._tunnel.poll() is None:
            self._tunnel.terminate()


def make_handler(panel: Panel, port: int):
    allowed_origins = {f"http://127.0.0.1:{port}", f"http://localhost:{port}"}

    class Handler(BaseHTTPRequestHandler):
        server_version = "BlueGreenPanel"

        def log_message(self, fmt, *args):
            # Keep the console readable during a demo: log actions and errors,
            # not the status/live polls the page makes every few seconds.
            line = fmt % args
            if self.command == "GET" and '" 200 ' in line:
                return
            sys.stderr.write("[panel] " + line + "\n")

        def _send(self, status, body: bytes, ctype: str):
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Content-Security-Policy",
                             "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; "
                             "img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(body)

        def _json(self, status, obj):
            self._send(status, json.dumps(obj).encode(), "application/json")

        def do_GET(self):
            path = urllib.parse.urlparse(self.path).path
            if path == "/":
                page = (STATIC / "index.html").read_text(encoding="utf-8").replace("__CSRF_TOKEN__", panel.csrf)
                return self._send(200, page.encode(), "text/html; charset=utf-8")
            if path in ("/static/panel.js", "/static/panel.css"):
                ctype = "text/javascript" if path.endswith(".js") else "text/css"
                return self._send(200, (STATIC / path.rsplit("/", 1)[1]).read_bytes(), ctype)
            if path == "/api/status":
                return self._json(200, {"cluster": panel.cluster_state(), "jenkins": panel.jenkins_state(),
                                        "jenkins_url": f"{panel.jenkins}/job/{JOB}/", "app_url": f"http://127.0.0.1:{TUNNEL_PORT}/"})
            if path == "/api/live":
                return self._json(200, panel.live())
            return self._json(404, {"error": "not found"})

        def do_POST(self):
            # CSRF defence: same-origin Origin header AND the per-session token.
            if self.headers.get("Origin") not in allowed_origins or self.headers.get("X-Panel-Token") != panel.csrf:
                return self._json(403, {"error": "forbidden"})
            length = min(int(self.headers.get("Content-Length") or 0), 4096)
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except ValueError:
                return self._json(400, {"error": "invalid JSON"})
            stop = "true" if body.get("stop_previous", True) else "false"
            path = urllib.parse.urlparse(self.path).path
            if path == "/api/activate":
                env = body.get("environment")
                if env not in ("blue", "green"):
                    return self._json(400, {"error": "environment must be blue or green"})
                status, result = panel.trigger({"ACTION": "activate", "TARGET_ENV": env, "STOP_PREVIOUS": stop,
                                                "REPLICAS": "2", "MONITOR_SECONDS": "30"})
            elif path == "/api/deploy":
                status, result = panel.trigger({"ACTION": "deploy", "STOP_PREVIOUS": stop, "REPLICAS": "2", "MONITOR_SECONDS": "30"})
            elif path == "/api/rollback":
                status, result = panel.trigger({"ACTION": "rollback", "ROLLBACK_REASON": "control-panel-rollback", "REPLICAS": "2"})
            else:
                return self._json(404, {"error": "not found"})
            return self._json(status, result)

    return Handler


def main():
    default_key = HERE.parent.parent / "devops-lab-key.pem"
    ap = argparse.ArgumentParser(description="Local Blue-Green control panel")
    ap.add_argument("--key", type=pathlib.Path, default=pathlib.Path(os.getenv("HEALTHCARE_SSH_KEY", default_key)),
                    help="SSH private key for ec2-user (never copied anywhere)")
    ap.add_argument("--jenkins", default=os.getenv("JENKINS_URL", "http://localhost:8080"))
    ap.add_argument("--token-file", type=pathlib.Path, default=pathlib.Path.home() / ".jenkins-api-token")
    ap.add_argument("--port", type=int, default=8090)
    args = ap.parse_args()
    if not args.key.is_file():
        raise SystemExit(f"SSH key not found: {args.key} (use --key)")
    panel = Panel(args.key, args.jenkins, args.token_file)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(panel, args.port))
    print(f"Blue-Green control panel: http://127.0.0.1:{args.port}/   (Ctrl+C to stop)")
    print(f"Hospital app (production, via SSH tunnel): http://127.0.0.1:{TUNNEL_PORT}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        panel.close()
        server.server_close()


if __name__ == "__main__":
    main()
