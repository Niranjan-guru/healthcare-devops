#!/usr/bin/env bash
# Runs on the EC2 K3s node. Exercises the deployed application through the
# Kubernetes Service NodePort on localhost, so no inbound port has to be
# opened to the internet. Uses synthetic data only.
#
# Usage: smoke-test.sh <workdir> <expected-version> <build-number>
set -Eeuo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <workdir> <expected-version> <build-number>" >&2
  exit 2
fi
WORKDIR=$1
VERSION=$2
BUILD=$3
EXPECTED_NODE_PORT=30060

node_port=$(sudo -n kubectl -n healthcare get service healthcare-service -o jsonpath='{.spec.ports[0].nodePort}')
if [[ "$node_port" != "$EXPECTED_NODE_PORT" ]]; then
  echo "[smoke] ERROR: service nodePort is '$node_port', expected $EXPECTED_NODE_PORT" >&2
  exit 1
fi
BASE="http://127.0.0.1:$node_port"
BODY="$WORKDIR/body.json"

passed=0
failed=0
pass() { passed=$((passed + 1)); echo "[smoke] PASS: $*"; }
fail() { failed=$((failed + 1)); echo "[smoke] FAIL: $*" >&2; }

# request METHOD PATH [JSON]  -> sets STATUS, response body in $BODY
request() {
  local args=(-sS -o "$BODY" -w '%{http_code}' --max-time 10 -X "$1" "$BASE$2")
  if [[ $# -ge 3 ]]; then args+=(-H 'Content-Type: application/json' --data "$3"); fi
  STATUS=$(curl "${args[@]}") || STATUS=000
}

# json_check PYTHON_EXPRESSION  (evaluated with `d` bound to the parsed body)
json_check() {
  python3 - "$BODY" "$1" "$VERSION" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
version = sys.argv[3]
sys.exit(0 if eval(sys.argv[2]) else 1)
PY
}

# Bounded wait for the service to answer (NodePort routing can lag briefly).
for attempt in $(seq 1 15); do
  request GET /health
  [[ "$STATUS" == "200" ]] && break
  echo "[smoke] /health attempt $attempt/15 returned $STATUS; retrying in 2s"
  sleep 2
done

[[ "$STATUS" == "200" ]] && json_check 'd["status"] == "HEALTHY" and d["version"] == version' \
  && pass "/health -> 200 HEALTHY, version $VERSION" || fail "/health -> $STATUS $(cat "$BODY" 2>/dev/null)"

request GET /
[[ "$STATUS" == "200" ]] && json_check 'd["version"] == version and "/api/doctors" in d["endpoints"]' \
  && pass "/ -> 200 with application metadata" || fail "/ -> $STATUS"

# Hit /version repeatedly so both replicas behind the Service are exercised.
version_ok=1
for i in $(seq 1 10); do
  request GET /version
  if ! { [[ "$STATUS" == "200" ]] && json_check 'd == {"version": version}'; }; then
    version_ok=0
    fail "/version request $i -> $STATUS $(cat "$BODY" 2>/dev/null)"
    break
  fi
done
[[ "$version_ok" -eq 1 ]] && pass "/version -> 200 '$VERSION' on 10/10 requests"

request GET /api/doctors
[[ "$STATUS" == "200" ]] && json_check '[x["id"] for x in d] == [1, 2, 3] and {x["specialty"] for x in d} == {"Cardiology", "Dermatology", "Neurology"}' \
  && pass "/api/doctors -> 200 with the 3 synthetic doctors" || fail "/api/doctors -> $STATUS $(cat "$BODY" 2>/dev/null)"

request POST /api/appointments '{}'
[[ "$STATUS" == "400" ]] && pass "POST empty appointment -> 400" || fail "POST empty appointment -> $STATUS (expected 400)"

request POST /api/appointments '{"doctor_id": 1, "patient_name": "CI Synthetic Patient", "appointment_date": "not-a-date"}'
[[ "$STATUS" == "400" ]] && pass "POST invalid date -> 400" || fail "POST invalid date -> $STATUS (expected 400)"

request POST /api/appointments '{"doctor_id": "1", "patient_name": "CI Synthetic Patient", "appointment_date": "2030-01-15"}'
[[ "$STATUS" == "400" ]] && pass "POST non-integer doctor_id -> 400" || fail "POST non-integer doctor_id -> $STATUS (expected 400)"

request POST /api/appointments '{"doctor_id": 999, "patient_name": "CI Synthetic Patient", "appointment_date": "2030-01-15"}'
[[ "$STATUS" == "404" ]] && pass "POST unknown doctor -> 404" || fail "POST unknown doctor -> $STATUS (expected 404)"

PATIENT="CI Synthetic Patient build $BUILD"
request POST /api/appointments "{\"doctor_id\": 2, \"patient_name\": \"$PATIENT\", \"appointment_date\": \"2030-01-15\"}"
[[ "$STATUS" == "201" ]] && json_check "d['appointment']['patient_name'] == '$PATIENT' and d['appointment']['status'] == 'scheduled' and d['appointment']['doctor'] == 'Dr.Priya Sharma'" \
  && pass "POST valid synthetic appointment -> 201" || fail "POST valid synthetic appointment -> $STATUS $(cat "$BODY" 2>/dev/null)"

echo "[smoke] $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
