#!/usr/bin/env bash
# Shared Kubernetes helpers for the remote deployment scripts (sourced, not
# executed). Every check fails loudly via `fail`; nothing here converts a
# failure into success. `|| true` appears only inside best-effort diagnostic
# output that runs AFTER a failure has already been decided.
#
# Callers must set: NS, LOG_PREFIX and DIAG_SELECTOR (used for diagnostics).

CONTAINER=${CONTAINER:-healthcare-app}
# Liveness probe: initialDelay 15s + 3 failures x 10s period = 45s worst case.
STABILISE_SECONDS=${STABILISE_SECONDS:-50}
LOCK_NAME=healthcare-deploy-lock
LOCK_TTL_SECONDS=2700        # a lock older than 45 min is considered stale
LOCK_WAIT_ATTEMPTS=30        # 30 x 10 s = 5 min maximum wait for another job

kc() { sudo -n kubectl "$@"; }
log() { printf '[%s] %s\n' "$LOG_PREFIX" "$*"; }

diagnostics() {
  echo "----- diagnostics -----" >&2
  kc -n "$NS" get deploy,rs,pods,svc -o wide >&2 || true
  kc -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 25 >&2 || true
  for pod in $(kc -n "$NS" get pods -l "$DIAG_SELECTOR" -o name 2>/dev/null); do
    echo "--- logs $pod ---" >&2
    kc -n "$NS" logs "$pod" -c "$CONTAINER" --tail=20 >&2 || true
  done
}
fail() { printf '[%s] ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; diagnostics; exit 1; }

require_node_ready() {
  kc get nodes -o wide || fail "cannot reach the K3s API via sudo kubectl"
  local not_ready
  not_ready=$(kc get nodes --no-headers | awk '$2 !~ /^Ready/' | wc -l)
  [[ "$not_ready" -eq 0 ]] || fail "$not_ready node(s) are not Ready"
}

# ---- Namespace deployment lock ------------------------------------------------
# A ConfigMap is created atomically; creation fails if another pipeline holds
# it. This serialises Activity 7 and Activity 8 deployments in the namespace.
lock_acquire() {
  local holder=$1 attempt now created current age
  for attempt in $(seq 1 "$LOCK_WAIT_ATTEMPTS"); do
    now=$(date +%s)
    if kc -n "$NS" create configmap "$LOCK_NAME" \
         --from-literal=holder="$holder" --from-literal=acquired="$now" >/dev/null 2>&1; then
      log "deploy lock acquired by $holder"
      return 0
    fi
    current=$(kc -n "$NS" get configmap "$LOCK_NAME" -o jsonpath='{.data.holder}' 2>/dev/null) || current=""
    created=$(kc -n "$NS" get configmap "$LOCK_NAME" -o jsonpath='{.data.acquired}' 2>/dev/null) || created=""
    if [[ "$current" == "$holder" ]]; then
      log "deploy lock already held by this build ($holder)"
      return 0
    fi
    if [[ "$created" =~ ^[0-9]+$ ]]; then
      age=$((now - created))
      if (( age > LOCK_TTL_SECONDS )); then
        log "removing stale deploy lock held by '$current' for ${age}s"
        kc -n "$NS" delete configmap "$LOCK_NAME" --ignore-not-found >/dev/null || fail "could not remove stale lock"
        continue
      fi
    fi
    log "deploy lock held by '$current' (attempt $attempt/$LOCK_WAIT_ATTEMPTS); waiting 10s"
    sleep 10
  done
  fail "deploy lock is still held by '$current' after $((LOCK_WAIT_ATTEMPTS * 10))s; another deployment is running"
}

lock_release() {
  local holder=$1 current
  current=$(kc -n "$NS" get configmap "$LOCK_NAME" -o jsonpath='{.data.holder}' 2>/dev/null) || current=""
  if [[ -z "$current" ]]; then
    log "deploy lock not present (nothing to release)"
  elif [[ "$current" == "$holder" ]]; then
    kc -n "$NS" delete configmap "$LOCK_NAME" >/dev/null || fail "could not release deploy lock"
    log "deploy lock released by $holder"
  else
    # This build never obtained the lock (another pipeline holds it); leave it.
    log "deploy lock is held by '$current', not '$holder'; leaving it in place"
  fi
}

# ---- Capacity -------------------------------------------------------------------
to_millicores() { local v=$1; if [[ "$v" == *m ]]; then echo "${v%m}"; else awk -v c="$v" 'BEGIN{printf "%d", c*1000}'; fi; }
to_mebibytes() {
  local v=$1
  case "$v" in
    *Ki) echo $(( ${v%Ki} / 1024 )) ;;
    *Mi) echo "${v%Mi}" ;;
    *Gi) echo $(( ${v%Gi} * 1024 )) ;;
    *M)  echo $(( ${v%M} * 1000000 / 1048576 )) ;;
    *G)  echo $(( ${v%G} * 1000000000 / 1048576 )) ;;
    *)   echo $(( v / 1048576 )) ;;
  esac
}

# capacity_check <additional_cpu_millicores> <additional_memory_Mi>
# Compares node allocatable resources with the requests of every non-terminal
# pod on the node plus the requests the new rollout needs.
capacity_check() {
  local need_cpu=$1 need_mem=$2 alloc_cpu alloc_mem used_cpu=0 used_mem=0 cpu mem
  alloc_cpu=$(to_millicores "$(kc get nodes -o jsonpath='{.items[0].status.allocatable.cpu}')")
  alloc_mem=$(to_mebibytes "$(kc get nodes -o jsonpath='{.items[0].status.allocatable.memory}')")
  # One line per container: "<cpu request>/<memory request>" (either may be empty).
  while IFS=/ read -r cpu mem; do
    if [[ -n "$cpu" ]]; then used_cpu=$((used_cpu + $(to_millicores "$cpu"))); fi
    if [[ -n "$mem" ]]; then used_mem=$((used_mem + $(to_mebibytes "$mem"))); fi
  done < <(kc get pods -A --field-selector=status.phase!=Succeeded,status.phase!=Failed \
             -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.requests.cpu}{"/"}{.resources.requests.memory}{"\n"}{end}{end}')
  log "capacity: allocatable cpu=${alloc_cpu}m mem=${alloc_mem}Mi; requested cpu=${used_cpu}m mem=${used_mem}Mi; this rollout needs cpu=${need_cpu}m mem=${need_mem}Mi"
  (( used_cpu + need_cpu <= alloc_cpu )) || fail "insufficient CPU: ${used_cpu}m requested + ${need_cpu}m needed > ${alloc_cpu}m allocatable"
  (( used_mem + need_mem <= alloc_mem )) || fail "insufficient memory: ${used_mem}Mi requested + ${need_mem}Mi needed > ${alloc_mem}Mi allocatable"
  log "capacity check passed: cpu $(( (used_cpu + need_cpu) * 100 / alloc_cpu ))% and memory $(( (used_mem + need_mem) * 100 / alloc_mem ))% of allocatable after rollout"
}

# ---- Rollout / pod verification -------------------------------------------------
pod_table() {   # pod_table <selector>
  kc -n "$NS" get pods -l "$1" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.status.containerStatuses[0].ready}{"|"}{.status.containerStatuses[0].restartCount}{"|"}{.spec.containers[0].image}{"|"}{.status.podIP}{"|"}{.metadata.deletionTimestamp}{"\n"}{end}'
}

verify_pods() {  # verify_pods <selector> <image> <replicas>
  local selector=$1 image=$2 replicas=$3 table count=0 name phase ready restarts pimage ip deleting
  table=$(pod_table "$selector")
  while IFS='|' read -r name phase ready restarts pimage ip deleting; do
    [[ -z "$name" ]] && continue
    count=$((count + 1))
    log "pod $name phase=$phase ready=$ready restarts=$restarts image=$pimage ip=$ip"
    [[ -z "$deleting" ]]          || fail "pod $name is terminating"
    [[ "$phase" == "Running" ]]   || fail "pod $name is not Running (phase=$phase)"
    [[ "$ready" == "true" ]]      || fail "pod $name is not Ready (readiness probe failing)"
    [[ "$restarts" == "0" ]]      || fail "pod $name restarted $restarts time(s) (liveness probe or crash)"
    [[ "$pimage" == "$image" ]]   || fail "pod $name runs $pimage, expected $image"
  done <<< "$table"
  [[ "$count" -eq "$replicas" ]] || fail "found $count pods for '$selector', expected $replicas"
}

# wait_rollout <deployment> <timeout> -- returns non-zero instead of failing so
# callers can decide how to react (e.g. undo a rejected candidate).
wait_rollout() { kc -n "$NS" rollout status "deployment/$1" --timeout="$2"; }

verify_deployment() {  # verify_deployment <deployment> <image> <replicas>
  local deploy=$1 image=$2 replicas=$3 spec_image status desired ready updated available
  spec_image=$(kc -n "$NS" get deployment "$deploy" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$CONTAINER\")].image}")
  [[ "$spec_image" == "$image" ]] || fail "deployment $deploy spec image is $spec_image, expected $image"
  # Here-string (not process substitution): jsonpath output has no trailing
  # newline, which makes `read` return 1 and abort the script under set -e.
  status=$(kc -n "$NS" get deployment "$deploy" \
    -o jsonpath='{.spec.replicas} {.status.readyReplicas} {.status.updatedReplicas} {.status.availableReplicas}') \
    || fail "could not read deployment status of $deploy"
  read -r desired ready updated available <<< "$status"
  log "deployment $deploy replicas desired=$desired ready=${ready:-0} updated=${updated:-0} available=${available:-0}"
  [[ "$desired" -eq "$replicas" ]] || fail "deployment $deploy wants $desired replicas, expected $replicas"
  [[ "${ready:-0}" -eq "$replicas" && "${updated:-0}" -eq "$replicas" && "${available:-0}" -eq "$replicas" ]] \
    || fail "deployment $deploy is not fully ready/updated/available"
}

wait_pod_count() {  # wait_pod_count <selector> <replicas>  (old pods may still be terminating)
  local selector=$1 replicas=$2 attempt total
  for attempt in $(seq 1 45); do
    total=$(kc -n "$NS" get pods -l "$selector" --no-headers 2>/dev/null | wc -l)
    [[ "$total" -eq "$replicas" ]] && return 0
    sleep 2
  done
  fail "pods for '$selector' did not settle to $replicas within 90s ($total present)"
}

# stability_window <selector> <image> <replicas>: pods must stay Ready with no
# restarts and must not be replaced while liveness probes get several chances.
stability_window() {
  local selector=$1 image=$2 replicas=$3 before after pod n unhealthy=0
  verify_pods "$selector" "$image" "$replicas"
  before=$(pod_table "$selector" | cut -d'|' -f1 | sort)
  log "observing pods for ${STABILISE_SECONDS}s to confirm readiness and liveness probes keep passing"
  sleep "$STABILISE_SECONDS"
  verify_pods "$selector" "$image" "$replicas"
  after=$(pod_table "$selector" | cut -d'|' -f1 | sort)
  [[ "$before" == "$after" ]] || fail "pods were replaced during the stability window"
  for pod in $after; do
    n=$(kc -n "$NS" get events --field-selector "involvedObject.name=$pod,reason=Unhealthy" --no-headers 2>/dev/null | wc -l)
    if [[ "$n" -gt 0 ]]; then log "note: pod $pod has $n 'Unhealthy' probe event(s)"; fi
    unhealthy=$((unhealthy + n))
  done
  log "probe check: all pods Ready, 0 restarts, $unhealthy Unhealthy event(s)"
}

pod_version() {  # pod_version <pod>
  kc -n "$NS" exec "$1" -c "$CONTAINER" -- python -c \
    "import json,urllib.request;print(json.load(urllib.request.urlopen('http://127.0.0.1:5000/version',timeout=5))['version'])"
}

verify_pod_versions() {  # verify_pod_versions <selector> <version>
  local selector=$1 version=$2 pod got
  for pod in $(pod_table "$selector" | cut -d'|' -f1); do
    got=$(pod_version "$pod") || fail "could not query /version inside pod $pod"
    [[ "$got" == "$version" ]] || fail "pod $pod reports version '$got', expected '$version'"
    log "pod $pod reports version $got"
  done
}

ready_endpoint_ips() {  # ready_endpoint_ips <service>
  kc -n "$NS" get endpointslices -l "kubernetes.io/service-name=$1" \
    -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"|"}{.conditions.ready}{"\n"}{end}' \
    | awk -F'|' '$2 == "true" {print $1}' | sort
}
pod_ips() { kc -n "$NS" get pods -l "$1" -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' | sort; }

verify_service_endpoints() {  # verify_service_endpoints <service> <selector> <replicas>
  local service=$1 selector=$2 replicas=$3 eps ips count attempt
  # Endpoint controllers update asynchronously after a selector change.
  for attempt in $(seq 1 15); do
    eps=$(ready_endpoint_ips "$service"); ips=$(pod_ips "$selector")
    count=$(awk 'NF {n++} END {print n + 0}' <<< "$eps")
    [[ "$count" -eq "$replicas" && "$eps" == "$ips" ]] && break
    sleep 2
  done
  log "service $service ready endpoints: $(echo $eps)"
  [[ "$count" -eq "$replicas" ]] || fail "service $service has $count ready endpoints, expected $replicas"
  [[ "$eps" == "$ips" ]] || fail "service $service endpoints ($(echo $eps)) do not match pods of '$selector' ($(echo $ips))"
}
