#!/usr/bin/env bash
# Runs on the EC2 K3s node. Applies the manifests rendered by Jenkins (with
# the exact image tag of the current build) and verifies the rollout.
# Any failed check exits non-zero and fails the Jenkins build.
#
# Usage: deploy.sh <workdir> <apply|verify> <image> <expected-version> <build-number> <git-commit>
#   apply  - pre-flight checks, server-side validation, kubectl apply
#   verify - rollout status, replica/pod/probe/version/endpoint verification
set -Eeuo pipefail

if [[ $# -ne 6 ]]; then
  echo "usage: $0 <workdir> <apply|verify> <image> <expected-version> <build-number> <git-commit>" >&2
  exit 2
fi
WORKDIR=$1
MODE=$2
IMAGE=$3
VERSION=$4
BUILD=$5
COMMIT=$6

NS=healthcare
DEPLOY=healthcare-deployment
SVC=healthcare-service
CONTAINER=healthcare-app
SELECTOR=app=healthcare
EXPECTED_REPLICAS=2
ROLLOUT_TIMEOUT=240s
# Liveness probe: initialDelay 15s + 3 failures x 10s period = 45s worst case.
STABILISE_SECONDS=50

kc() { sudo -n kubectl "$@"; }
log() { printf '[deploy] %s\n' "$*"; }

diagnostics() {
  echo "----- diagnostics -----" >&2
  kc -n "$NS" get deploy,rs,pods,svc -o wide >&2 || true
  kc -n "$NS" describe deployment "$DEPLOY" 2>/dev/null | tail -n 25 >&2 || true
  kc -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 25 >&2 || true
  for pod in $(kc -n "$NS" get pods -l "$SELECTOR" -o name 2>/dev/null); do
    echo "--- logs $pod ---" >&2
    kc -n "$NS" logs "$pod" -c "$CONTAINER" --tail=20 >&2 || true
  done
}
fail() { printf '[deploy] ERROR: %s\n' "$*" >&2; diagnostics; exit 1; }

pod_table() {
  kc -n "$NS" get pods -l "$SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.status.containerStatuses[0].ready}{"|"}{.status.containerStatuses[0].restartCount}{"|"}{.spec.containers[0].image}{"|"}{.status.podIP}{"|"}{.metadata.deletionTimestamp}{"\n"}{end}'
}

verify_pods() {
  local table count=0 name phase ready restarts image ip deleting
  table=$(pod_table)
  while IFS='|' read -r name phase ready restarts image ip deleting; do
    [[ -z "$name" ]] && continue
    count=$((count + 1))
    log "pod $name phase=$phase ready=$ready restarts=$restarts image=$image ip=$ip"
    [[ -z "$deleting" ]]          || fail "pod $name is terminating"
    [[ "$phase" == "Running" ]]   || fail "pod $name is not Running (phase=$phase)"
    [[ "$ready" == "true" ]]      || fail "pod $name is not Ready (readiness probe failing)"
    [[ "$restarts" == "0" ]]      || fail "pod $name restarted $restarts time(s) (liveness probe or crash)"
    [[ "$image" == "$IMAGE" ]]    || fail "pod $name runs $image, expected $IMAGE"
  done <<< "$table"
  [[ "$count" -eq "$EXPECTED_REPLICAS" ]] || fail "found $count pods, expected $EXPECTED_REPLICAS"
}

log "mode=$MODE build=$BUILD commit=$COMMIT image=$IMAGE"

do_apply() {
# ---- Pre-flight -----------------------------------------------------------
kc get nodes -o wide || fail "cannot reach the K3s API via sudo kubectl"
not_ready=$(kc get nodes --no-headers | awk '$2 !~ /^Ready/' | wc -l)
[[ "$not_ready" -eq 0 ]] || fail "$not_ready node(s) are not Ready"
log "Node resource allocation before deployment:"
kc describe nodes | sed -n '/Allocated resources/,/Events/p' | grep -E 'cpu|memory' || true

grep -Fq "image: $IMAGE" "$WORKDIR/deployment.yaml" \
  || fail "rendered deployment.yaml does not reference $IMAGE"

# ---- Apply ----------------------------------------------------------------
kc apply -f "$WORKDIR/namespace.yaml" || fail "applying namespace failed"
kc apply --dry-run=server -f "$WORKDIR/service.yaml" -f "$WORKDIR/deployment.yaml" \
  || fail "server-side validation of the manifests failed"
kc apply -f "$WORKDIR/service.yaml" || fail "applying service failed"
kc apply -f "$WORKDIR/deployment.yaml" || fail "applying deployment failed"
kc -n "$NS" annotate deployment "$DEPLOY" --overwrite \
  "kubernetes.io/change-cause=Jenkins build $BUILD commit $COMMIT image $IMAGE" >/dev/null \
  || fail "annotating deployment failed"
log "Manifests applied for $IMAGE"
}

do_verify() {
# ---- Rollout ----------------------------------------------------------------
log "Waiting for rollout (timeout $ROLLOUT_TIMEOUT)"
kc -n "$NS" rollout status "deployment/$DEPLOY" --timeout="$ROLLOUT_TIMEOUT" \
  || fail "rollout did not complete within $ROLLOUT_TIMEOUT"

spec_image=$(kc -n "$NS" get deployment "$DEPLOY" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$CONTAINER\")].image}")
[[ "$spec_image" == "$IMAGE" ]] || fail "deployment spec image is $spec_image, expected $IMAGE"

# Here-string (not process substitution): jsonpath output has no trailing
# newline, which makes `read` return 1 and abort the script under set -e.
replica_status=$(kc -n "$NS" get deployment "$DEPLOY" \
  -o jsonpath='{.spec.replicas} {.status.readyReplicas} {.status.updatedReplicas} {.status.availableReplicas}') \
  || fail "could not read deployment status"
read -r desired ready updated available <<< "$replica_status"
log "deployment replicas desired=$desired ready=$ready updated=$updated available=$available"
[[ "$desired" -eq "$EXPECTED_REPLICAS" ]] || fail "deployment wants $desired replicas, expected $EXPECTED_REPLICAS"
[[ "${ready:-0}" -eq "$EXPECTED_REPLICAS" && "${updated:-0}" -eq "$EXPECTED_REPLICAS" && "${available:-0}" -eq "$EXPECTED_REPLICAS" ]] \
  || fail "deployment is not fully ready/updated/available"

# Old ReplicaSet pods may still be terminating right after the rollout.
for attempt in $(seq 1 45); do
  total=$(kc -n "$NS" get pods -l "$SELECTOR" --no-headers | wc -l)
  [[ "$total" -eq "$EXPECTED_REPLICAS" ]] && break
  [[ "$attempt" -eq 45 ]] && fail "old pods did not terminate within 90s ($total pods present)"
  sleep 2
done
verify_pods
pods_before=$(pod_table | cut -d'|' -f1 | sort)

# ---- Probe stability --------------------------------------------------------
log "Observing pods for ${STABILISE_SECONDS}s to confirm readiness and liveness probes keep passing"
sleep "$STABILISE_SECONDS"
verify_pods
pods_after=$(pod_table | cut -d'|' -f1 | sort)
[[ "$pods_before" == "$pods_after" ]] || fail "pods were replaced during the stability window"
unhealthy=0
for pod in $pods_after; do
  n=$(kc -n "$NS" get events --field-selector "involvedObject.name=$pod,reason=Unhealthy" --no-headers 2>/dev/null | wc -l)
  [[ "$n" -gt 0 ]] && log "note: pod $pod has $n 'Unhealthy' probe event(s)"
  unhealthy=$((unhealthy + n))
done
log "probe check: all pods Ready, 0 restarts, $unhealthy Unhealthy event(s)"

# ---- Per-pod version check ----------------------------------------------------
for pod in $pods_after; do
  got=$(kc -n "$NS" exec "$pod" -c "$CONTAINER" -- python -c \
    "import json,urllib.request;print(json.load(urllib.request.urlopen('http://127.0.0.1:5000/version',timeout=5))['version'])") \
    || fail "could not query /version inside pod $pod"
  [[ "$got" == "$VERSION" ]] || fail "pod $pod reports version '$got', expected '$VERSION'"
  log "pod $pod reports version $got"
done

# ---- Service endpoints ---------------------------------------------------------
endpoint_ips=$(kc -n "$NS" get endpointslices -l "kubernetes.io/service-name=$SVC" \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"|"}{.conditions.ready}{"\n"}{end}' \
  | awk -F'|' '$2 == "true" {print $1}' | sort)
pod_ips=$(kc -n "$NS" get pods -l "$SELECTOR" -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' | sort)
log "ready service endpoints: $(echo $endpoint_ips)"
[[ $(echo "$endpoint_ips" | grep -c .) -eq "$EXPECTED_REPLICAS" ]] \
  || fail "service $SVC has $(echo "$endpoint_ips" | grep -c .) ready endpoints, expected $EXPECTED_REPLICAS"
[[ "$endpoint_ips" == "$pod_ips" ]] || fail "service endpoints do not match the running pod IPs"

# ---- Summary ------------------------------------------------------------------
kc -n "$NS" get deployments -o wide
kc -n "$NS" get pods -o wide
kc -n "$NS" get services -o wide
kc -n "$NS" get endpointslices -o wide
kc -n "$NS" rollout history "deployment/$DEPLOY" | tail -n 5
log "SUCCESS: $IMAGE rolled out with $EXPECTED_REPLICAS ready replicas reporting version $VERSION"
}

case "$MODE" in
  apply)  do_apply ;;
  verify) do_verify ;;
  *) echo "unknown mode: $MODE" >&2; exit 2 ;;
esac
