from __future__ import annotations

import argparse
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
out["production"] = svc["spec"]["selector"].get("environment", "")
for env in ("blue", "green"):
    try:
        d = kc("get", "deployment", "healthcare-" + env)
    except subprocess.CalledProcessError:
        out["environments"][env] = None
        continue
    a = d["metadata"].get("annotations", {})
    out["environments"][env] = {
        "desired": d["spec"].get("replicas", 0), "ready": d.get("status", {}).get("readyReplicas", 0) or 0,
        "version": a.get("healthcare.pbl/verified-version", ""),
        "verified": bool(a.get("healthcare.pbl/verified-image")) and
                    a.get("healthcare.pbl/verified-image") == d["spec"]["template"]["spec"]["containers"][0]["image"]}
print(json.dumps(out))
'''

# Fast switch executed on the node: start the target if it is OFF, wait until
# Ready, point the production Service at it, confirm the website answers from
# it, then turn the other environment OFF. Only an environment whose current
# image is the one recorded as verified by the Jenkins pipeline can be used.
SWITCH_SCRIPT = r'''
set -euo pipefail
T=$1; NS=healthcare; A=healthcare.pbl
kc() { sudo -n kubectl -n "$NS" "$@"; }
ann() { kc get deployment "$1" -o jsonpath="{.metadata.annotations.healthcare\.pbl/$2}" 2>/dev/null || true; }
[[ "$T" == blue || "$T" == green ]] || { echo "ERROR: target must be blue or green"; exit 2; }
if ! kc create configmap healthcare-deploy-lock --from-literal=holder=control-panel \
       --from-literal=acquired="$(date +%s)" >/dev/null 2>&1; then
  echo "ERROR: a deployment is already in progress ($(kc get configmap healthcare-deploy-lock -o jsonpath='{.data.holder}' 2>/dev/null)); try again shortly"
  exit 3
fi
trap 'kc delete configmap healthcare-deploy-lock --ignore-not-found >/dev/null 2>&1' EXIT
OTHER=green; [[ "$T" == green ]] && OTHER=blue
DEP=healthcare-$T
ACTIVE=$(kc get service healthcare-service -o jsonpath='{.spec.selector.environment}')
VIMG=$(ann "$DEP" verified-image); VVER=$(ann "$DEP" verified-version)
IMG=$(kc get deployment "$DEP" -o jsonpath='{.spec.template.spec.containers[0].image}')
if [[ -z "$VIMG" || "$IMG" != "$VIMG" ]]; then
  echo "ERROR: $T has no verified release; deploy it once with the Healthcare-Blue-Green Jenkins job"
  exit 4
fi
if [[ "$ACTIVE" == "$T" ]]; then
  echo "STEP: $T is already serving the website"
else
  if [[ "$(kc get deployment "$DEP" -o jsonpath='{.spec.replicas}')" == "0" ]]; then
    echo "STEP: starting $T ($VVER)"
    kc scale deployment "$DEP" --replicas=2 >/dev/null
    kc annotate deployment "$DEP" --overwrite "$A/stopped-" >/dev/null
  fi
  if ! kc rollout status "deployment/$DEP" --timeout=120s >/dev/null; then
    echo "ERROR: $T did not become ready; the website still runs on $ACTIVE"
    exit 5
  fi
  echo "STEP: $T is ready"
  PREVIMG=""; PREVVER=""
  if [[ "$ACTIVE" == blue || "$ACTIVE" == green ]]; then
    PREVIMG=$(kc get deployment "healthcare-$ACTIVE" -o jsonpath='{.spec.template.spec.containers[0].image}'); PREVVER=$(ann "healthcare-$ACTIVE" verified-version)
  fi
  kc patch service healthcare-service --type merge \
    -p "{\"spec\":{\"selector\":{\"app\":\"healthcare\",\"environment\":\"$T\"}}}" >/dev/null
  kc annotate service healthcare-service --overwrite "$A/active-environment=$T" "$A/active-image=$VIMG" \
    "$A/active-version=$VVER" "$A/previous-environment=$ACTIVE" "$A/previous-image=$PREVIMG" \
    "$A/previous-version=$PREVVER" "$A/last-operation=control-panel-switch" \
    "$A/last-change-utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$A/rollback-reason-" >/dev/null
  echo "STEP: website switched from $ACTIVE to $T"
fi
body=""
for i in $(seq 1 20); do
  body=$(curl -s --max-time 3 "http://127.0.0.1:30060/api/deployment" || true)
  [[ "$body" == *"\"environment\":\"$T\""* ]] && break
  sleep 1
done
if [[ "$body" != *"\"environment\":\"$T\""* ]]; then
  echo "ERROR: the website is not answering from $T; switching back to $ACTIVE"
  if [[ -n "$ACTIVE" && "$ACTIVE" != "$T" ]]; then
    kc patch service healthcare-service --type merge \
      -p "{\"spec\":{\"selector\":{\"app\":\"healthcare\",\"environment\":\"$ACTIVE\"}}}" >/dev/null
  fi
  exit 6
fi
echo "STEP: website answers from $T"
if [[ "$(kc get deployment "healthcare-$OTHER" -o jsonpath='{.spec.replicas}' 2>/dev/null)" =~ ^[1-9] ]]; then
  kc scale deployment "healthcare-$OTHER" --replicas=0 >/dev/null
  kc annotate deployment "healthcare-$OTHER" --overwrite "$A/stopped=true" "$A/stopped-by-build=control-panel" >/dev/null
  echo "STEP: $OTHER turned OFF"
fi
echo "DONE: $T"
'''


class Panel:
    def __init__(self, key: pathlib.Path):
        self.key = key
        self.csrf = secrets.token_urlsafe(24)
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="bg-panel-"))
        self.known_hosts = self.tmp / "known_hosts"
        self._pin_host_key()
        self._tunnel = None
        self._tunnel_lock = threading.Lock()
        self._switch_lock = threading.Lock()

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

    def _ssh(self):
        return ["ssh", "-i", str(self.key), "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={self.known_hosts.as_posix()}",
                "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "LogLevel=ERROR"]

    def cluster_state(self):
        try:
            r = subprocess.run(self._ssh() + [f"{EC2_USER}@{EC2_HOST}", "python3", "-"], input=STATE_SCRIPT,
                               capture_output=True, text=True, timeout=30)
            return json.loads(r.stdout) if r.returncode == 0 else {"error": "cannot reach the cluster"}
        except (subprocess.TimeoutExpired, ValueError):
            return {"error": "cannot reach the cluster"}

    def switch(self, target: str):
        if not self._switch_lock.acquire(blocking=False):
            return 409, {"ok": False, "steps": ["A switch is already running."]}
        started = time.time()
        try:
            # Send raw LF bytes: in text mode Windows would turn "\n" into
            # "\r\n" on stdin, and bash rejects "pipefail\r" (exit 2).
            r = subprocess.run(self._ssh() + [f"{EC2_USER}@{EC2_HOST}", "bash", "-s", "--", target],
                               input=SWITCH_SCRIPT.replace("\r\n", "\n").encode("utf-8"), capture_output=True, timeout=240)
            out = r.stdout.decode("utf-8", errors="replace")
            steps = [l.split(": ", 1)[1] for l in out.splitlines() if l.startswith(("STEP: ", "ERROR: "))]
            ok = r.returncode == 0 and any(l.startswith("DONE: ") for l in out.splitlines())
            if not steps:
                steps = ["The switch did not complete (ssh exit %d)." % r.returncode]
        except subprocess.TimeoutExpired:
            ok, steps = False, ["The switch timed out after 4 minutes."]
        finally:
            self._switch_lock.release()
        return (200 if ok else 500), {"ok": ok, "steps": steps, "seconds": round(time.time() - started, 1)}

    def ensure_tunnel(self):
        with self._tunnel_lock:
            if self._tunnel and self._tunnel.poll() is None:
                return
            self._tunnel = subprocess.Popen(
                self._ssh() + ["-N", "-o", "ExitOnForwardFailure=yes",
                               "-L", f"127.0.0.1:{TUNNEL_PORT}:127.0.0.1:{PROD_NODEPORT}", f"{EC2_USER}@{EC2_HOST}"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(2)

    def live(self):
        self.ensure_tunnel()
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{TUNNEL_PORT}/api/deployment", timeout=4) as resp:
                return json.loads(resp.read())
        except Exception as exc:
            return {"error": f"website unreachable ({type(exc).__name__})"}

    def close(self):
        if self._tunnel and self._tunnel.poll() is None:
            self._tunnel.terminate()


def make_handler(panel: Panel, port: int):
    allowed_origins = {f"http://127.0.0.1:{port}", f"http://localhost:{port}"}

    class Handler(BaseHTTPRequestHandler):
        server_version = "BlueGreenPanel"

        def log_message(self, fmt, *args):
            # Log actions and errors only, not the status polls.
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
                return self._json(200, {"cluster": panel.cluster_state(), "website": f"http://127.0.0.1:{TUNNEL_PORT}/"})
            if path == "/api/live":
                return self._json(200, panel.live())
            return self._json(404, {"error": "not found"})

        def do_POST(self):
            # Only this page may trigger a switch: same-origin Origin + per-session token.
            if self.headers.get("Origin") not in allowed_origins or self.headers.get("X-Panel-Token") != panel.csrf:
                return self._json(403, {"error": "forbidden"})
            if urllib.parse.urlparse(self.path).path != "/api/switch":
                return self._json(404, {"error": "not found"})
            try:
                body = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length") or 0), 1024)) or b"{}")
            except ValueError:
                return self._json(400, {"error": "invalid JSON"})
            env = body.get("environment")
            if env not in ("blue", "green"):
                return self._json(400, {"error": "environment must be blue or green"})
            status, result = panel.switch(env)
            return self._json(status, result)

    return Handler


def main():
    default_key = HERE.parent.parent / "devops-lab-key.pem"
    ap = argparse.ArgumentParser(description="Blue-Green demo panel (local only)")
    ap.add_argument("--key", type=pathlib.Path, default=pathlib.Path(os.getenv("HEALTHCARE_SSH_KEY", default_key)),
                    help="SSH private key for ec2-user (never copied anywhere)")
    ap.add_argument("--port", type=int, default=8090)
    args = ap.parse_args()
    if not args.key.is_file():
        raise SystemExit(f"SSH key not found: {args.key} (use --key)")
    panel = Panel(args.key)
    panel.ensure_tunnel()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(panel, args.port))
    print(f"Blue-Green demo panel:  http://127.0.0.1:{args.port}/")
    print(f"Website (production):   http://127.0.0.1:{TUNNEL_PORT}/")
    print("Press Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        panel.close()
        server.server_close()


if __name__ == "__main__":
    main()
