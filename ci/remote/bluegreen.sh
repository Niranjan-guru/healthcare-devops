#!/usr/bin/env bash
# Activity 8 - Blue-Green deployment operations, run on the EC2 K3s node.
#
# The production Service `healthcare-service` selects
#   app=healthcare, environment=<active>
# where <active> is blue or green (or `rolling`, the Activity 7 Deployment,
# when production was adopted from the pre-blue/green setup). All state is
# read from the cluster: the Service selector is the source of truth for the
# active environment, and Service annotations record the previous one.
#
# Usage: bluegreen.sh <workdir> <mode> [args...]
#   prepare  <holder> <replicas> [target]         lock, adopt legacy production, choose (or force) target
#   start    <target> <replicas>                  turn an environment ON with its recorded verified image
#   stop     <env> <build>                        turn a non-live environment OFF (scale to 0)
#   deploy   <target> <image> <build> <commit>    apply candidate + point preview Service at it
#   wait     <target> <image> <replicas>          bounded rollout wait; undo candidate on failure
#   validate <target> <image> <version> <replicas> probes, restarts, per-pod version, preview endpoints
#   switch   <target> <image> <version> <build> <commit> <replicas>
#   monitor  <target> <version> <seconds> <replicas>
#   rollback <build> <reason-token> [replicas]    switch back to the recorded previous environment
#                                                 (restarting it first if it was turned OFF)
#   state                                         print deployment state as JSON
#   unlock   <holder>                             release the namespace deploy lock
set -Eeuo pipefail

if [[ $# -lt 2 ]]; then echo "usage: $0 <workdir> <mode> [args...]" >&2; exit 2; fi
WORKDIR=$1; MODE=$2; shift 2

NS=healthcare
PROD_SVC=healthcare-service
PREVIEW_SVC=healthcare-preview-service
NODE_PORT=30060
ROLLOUT_TIMEOUT=240s
A=healthcare.pbl           # annotation prefix
LOG_PREFIX="bluegreen:$MODE"
DIAG_SELECTOR=app=healthcare
# shellcheck source=k8s-lib.sh
source "$(dirname "$0")/k8s-lib.sh"

deploy_of() {
  case "$1" in
    blue) echo healthcare-blue ;; green) echo healthcare-green ;;
    rolling) echo healthcare-deployment ;; *) echo "" ;;
  esac
}
selector_of() { echo "app=healthcare,environment=$1"; }
require_target() { [[ "$1" == "blue" || "$1" == "green" ]] || fail "target must be blue or green, got '$1'"; }
active_env() { kc -n "$NS" get service "$PROD_SVC" -o jsonpath='{.spec.selector.environment}'; }
annotation() { kc -n "$NS" get service "$PROD_SVC" -o jsonpath="{.metadata.annotations.${A//./\\.}/$1}"; }
deploy_image() { kc -n "$NS" get deployment "$1" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$CONTAINER\")].image}"; }

first_pod_version() {   # first_pod_version <selector>
  local pod
  pod=$(kc -n "$NS" get pods -l "$1" -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$pod" ]] || fail "no pods found for '$1'"
  pod_version "$pod"
}

# Sends 10 requests through the production NodePort; all must return $1.
verify_production_version() {
  local expected=$1 i body
  for i in $(seq 1 10); do
    body=$(curl -sS --fail --max-time 5 "http://127.0.0.1:$NODE_PORT/version") \
      || fail "production request $i to /version failed"
    [[ "$body" == "{\"version\":\"$expected\"}" ]] || fail "production request $i returned $body, expected version $expected"
  done
  log "production Service returned version $expected on 10/10 requests"
}

do_prepare() {
  # prepare <holder> <replicas> [forced-target]  (forced target = ACTION=activate)
  local holder=$1 replicas=$2 forced=${3:-} active target existing new_pods rolling_ready
  require_node_ready
  lock_acquire "$holder"

  if ! kc -n "$NS" get service "$PROD_SVC" >/dev/null 2>&1; then
    log "production Service does not exist; creating it with no active environment (no endpoints) until the first validated switch"
    kc apply -f "$WORKDIR/bg-service.yaml" >/dev/null || fail "creating production Service failed"
    kc -n "$NS" patch service "$PROD_SVC" --type merge \
      -p '{"spec":{"selector":{"app":"healthcare","environment":"none"}}}' >/dev/null || fail "initialising selector failed"
  fi

  active=$(active_env)
  if [[ -z "$active" ]]; then
    # Legacy (pre-blue/green) Service selecting app=healthcare only. Pin it to
    # the Activity 7 rolling pods - the same pods it serves today - so that
    # deploying a candidate can never leak traffic to unvalidated pods.
    rolling_ready=$(kc -n "$NS" get deployment healthcare-deployment -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || rolling_ready=0
    [[ "${rolling_ready:-0}" -ge 1 ]] \
      || fail "production Service is unmanaged (selector app=healthcare) and no Ready environment=rolling pods exist; run Healthcare-CI-CD first to migrate"
    log "ADOPTION: production Service had legacy selector app=healthcare; pinning it to environment=rolling (same pods, no traffic change)"
    kc -n "$NS" patch service "$PROD_SVC" --type merge \
      -p '{"spec":{"selector":{"app":"healthcare","environment":"rolling"}}}' >/dev/null || fail "pinning legacy selector failed"
    verify_service_endpoints "$PROD_SVC" "$(selector_of rolling)" "$rolling_ready"
    kc -n "$NS" annotate service "$PROD_SVC" --overwrite \
      "$A/active-environment=rolling" "$A/active-image=$(deploy_image healthcare-deployment)" \
      "$A/active-version=$(first_pod_version "$(selector_of rolling)")" \
      "$A/last-operation=adopt-legacy" >/dev/null || fail "annotating adoption failed"
    active=rolling
  fi

  if [[ -n "$forced" ]]; then
    require_target "$forced"; target=$forced
    if [[ "$target" == "$active" ]]; then
      log "$target is already the active production environment; nothing to switch"
      echo "BG_ACTIVE=$active"; echo "BG_TARGET=$target"; echo "BG_ALREADY_ACTIVE=true"
      return 0
    fi
  elif [[ "$active" == "blue" ]]; then target=green; else target=blue; fi
  log "current production environment: $active (image $( [[ -n "$(deploy_of "$active")" ]] && deploy_image "$(deploy_of "$active")" || echo none))"
  log "candidate (inactive) environment: $target"

  existing=$(kc -n "$NS" get pods -l "$(selector_of "$target")" --no-headers 2>/dev/null | wc -l)
  new_pods=$(( replicas + 1 - existing ))
  if (( new_pods < 1 )); then new_pods=1; fi
  capacity_check $(( new_pods * 50 )) $(( new_pods * 64 ))

  echo "BG_ACTIVE=$active"
  echo "BG_TARGET=$target"
}

do_deploy() {
  local target=$1 image=$2 build=$3 commit=$4 deploy manifest
  require_target "$target"
  [[ "$(active_env)" != "$target" ]] || fail "refusing to deploy into $target: it is the LIVE production environment"
  deploy=$(deploy_of "$target"); manifest="$WORKDIR/deployment-$target.yaml"
  grep -Fq "image: $image" "$manifest" || fail "rendered $manifest does not reference $image"

  kc apply --dry-run=server -f "$manifest" -f "$WORKDIR/service-preview.yaml" >/dev/null \
    || fail "server-side validation of the candidate manifests failed"
  kc apply -f "$manifest" || fail "applying $deploy failed"
  kc -n "$NS" annotate deployment "$deploy" --overwrite \
    "kubernetes.io/change-cause=Jenkins blue-green build $build commit $commit image $image" \
    "$A/verified=false" >/dev/null || fail "annotating $deploy failed"
  kc apply -f "$WORKDIR/service-preview.yaml" >/dev/null || fail "applying preview Service failed"
  kc -n "$NS" patch service "$PREVIEW_SVC" --type merge \
    -p "{\"spec\":{\"selector\":{\"app\":\"healthcare\",\"environment\":\"$target\"}}}" >/dev/null \
    || fail "pointing preview Service at $target failed"
  log "candidate $deploy applied with $image; preview Service -> $target; production still -> $(active_env)"
}

do_wait() {
  local target=$1 image=$2 replicas=$3 deploy revisions
  require_target "$target"; deploy=$(deploy_of "$target")
  log "waiting for $deploy rollout (timeout $ROLLOUT_TIMEOUT)"
  if ! wait_rollout "$deploy" "$ROLLOUT_TIMEOUT"; then
    echo "[$LOG_PREFIX] candidate $deploy did not become Ready; it is REJECTED and will not be promoted" >&2
    diagnostics
    revisions=$(kc -n "$NS" get rs -l "$(selector_of "$target")" --no-headers 2>/dev/null | wc -l)
    if [[ "$revisions" -gt 1 ]]; then
      log "restoring $deploy to its previous revision (kubectl rollout undo)"
      kc -n "$NS" rollout undo "deployment/$deploy" >/dev/null || fail "rollout undo of rejected candidate failed"
      wait_rollout "$deploy" 180s || fail "restoring $deploy to its previous revision did not complete"
    else
      log "no previous revision of $deploy exists; scaling the rejected candidate to 0"
      kc -n "$NS" scale "deployment/$deploy" --replicas=0 >/dev/null || fail "scaling rejected candidate to 0 failed"
    fi
    log "production Service still routes to: $(active_env) (unchanged)"
    fail "candidate rollout failed; production traffic was NOT switched"
  fi
  verify_deployment "$deploy" "$image" "$replicas"
  wait_pod_count "$(selector_of "$target")" "$replicas"
  verify_pods "$(selector_of "$target")" "$image" "$replicas"
}

do_validate() {
  local target=$1 image=$2 version=$3 replicas=$4 before
  require_target "$target"
  before=$(active_env)
  [[ "$before" != "$target" ]] || fail "candidate $target is already production; pre-switch validation is meaningless"
  stability_window "$(selector_of "$target")" "$image" "$replicas"
  verify_pod_versions "$(selector_of "$target")" "$version"
  verify_service_endpoints "$PREVIEW_SVC" "$(selector_of "$target")" "$replicas"
  [[ "$(active_env)" == "$before" ]] || fail "production selector changed during validation"
  log "candidate $target validated; production still routes to $before"
}

do_switch() {
  local target=$1 image=$2 version=$3 build=$4 commit=$5 replicas=$6
  local prev prev_deploy prev_image="" prev_version="" prev_ready
  require_target "$target"
  prev=$(active_env)
  [[ "$prev" != "$target" ]] || fail "$target is already the active environment"
  prev_deploy=$(deploy_of "$prev")
  if [[ -n "$prev_deploy" ]]; then
    prev_image=$(deploy_image "$prev_deploy")
    prev_version=$(first_pod_version "$(selector_of "$prev")")
  fi
  verify_pods "$(selector_of "$target")" "$image" "$replicas"

  log "SWITCH: production Service $PROD_SVC selector environment=$prev -> environment=$target"
  kc -n "$NS" get service "$PROD_SVC" -o jsonpath='before: {.spec.selector}{"\n"}'
  kc -n "$NS" patch service "$PROD_SVC" --type merge \
    -p "{\"spec\":{\"selector\":{\"app\":\"healthcare\",\"environment\":\"$target\"}}}" >/dev/null \
    || fail "patching production selector failed"
  kc -n "$NS" get service "$PROD_SVC" -o jsonpath='after:  {.spec.selector}{"\n"}'
  kc -n "$NS" annotate service "$PROD_SVC" --overwrite \
    "$A/active-environment=$target" "$A/active-image=$image" "$A/active-version=$version" \
    "$A/previous-environment=$prev" "$A/previous-image=$prev_image" "$A/previous-version=$prev_version" \
    "$A/last-operation=promote" "$A/last-build=$build" "$A/last-commit=$commit" \
    "$A/last-change-utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$A/rollback-reason-" >/dev/null || fail "recording switch annotations failed"
  # verified-image records exactly which image passed validation, so a later
  # "turn ON" (start) can never bring up anything unverified.
  kc -n "$NS" annotate deployment "$(deploy_of "$target")" --overwrite \
    "$A/verified=true" "$A/verified-version=$version" "$A/verified-image=$image" "$A/stopped-" >/dev/null \
    || fail "marking $target verified failed"

  [[ "$(active_env)" == "$target" ]] || fail "production selector is not environment=$target after patch"
  verify_service_endpoints "$PROD_SVC" "$(selector_of "$target")" "$replicas"
  verify_production_version "$version"

  if [[ -n "$prev_deploy" ]]; then
    prev_ready=$(kc -n "$NS" get deployment "$prev_deploy" -o jsonpath='{.status.readyReplicas}')
    [[ "${prev_ready:-0}" -ge 1 ]] || fail "previous environment $prev has no Ready pods; rollback would be impossible"
    log "previous environment $prev kept running for rollback: $prev_deploy ready=$prev_ready image=$prev_image version=$prev_version"
  fi
  echo "BG_SWITCHED=true"
}

do_monitor() {
  local target=$1 version=$2 seconds=$3 replicas=$4 iterations i body
  iterations=$(( seconds / 10 )); if (( iterations < 1 )); then iterations=1; fi
  log "monitoring production for ${seconds}s ($iterations checks, 10s apart)"
  for i in $(seq 1 "$iterations"); do
    [[ "$(active_env)" == "$target" ]] || fail "check $i: production selector no longer points at $target"
    body=$(curl -sS --fail --max-time 5 "http://127.0.0.1:$NODE_PORT/health") || fail "check $i: production /health failed"
    [[ "$body" == "{\"status\":\"HEALTHY\",\"version\":\"$version\"}" ]] || fail "check $i: production /health returned $body (expected HEALTHY $version)"
    verify_pods "$(selector_of "$target")" "$(deploy_image "$(deploy_of "$target")")" "$replicas" >/dev/null
    log "check $i/$iterations: HEALTHY, version $version, $replicas pods Ready with 0 restarts"
    if (( i < iterations )); then sleep 10; fi
  done
  log "post-switch monitoring passed"
}

dep_annotation() {  # dep_annotation <deployment> <key>
  kc -n "$NS" get deployment "$1" -o jsonpath="{.metadata.annotations.${A//./\\.}/$2}"
}

# start <target> <replicas>: turn an environment ON again with the image that
# was verified when it last passed validation (ACTION=activate).
do_start() {
  local target=$1 replicas=$2 deploy vimg vver live current
  require_target "$target"
  [[ "$(active_env)" != "$target" ]] || fail "$target is already the active environment"
  deploy=$(deploy_of "$target")
  kc -n "$NS" get deployment "$deploy" >/dev/null 2>&1 || fail "$deploy does not exist; run a normal deploy first"
  vimg=$(dep_annotation "$deploy" verified-image); vver=$(dep_annotation "$deploy" verified-version)
  [[ -n "$vimg" && -n "$vver" ]] || fail "$deploy has no verified image recorded; it must pass a full blue-green release before it can be turned ON"
  live=$(deploy_image "$deploy")
  [[ "$live" == "$vimg" ]] || fail "$deploy currently has image $live, not its verified image $vimg; refusing to turn it ON"
  current=$(kc -n "$NS" get deployment "$deploy" -o jsonpath='{.spec.replicas}')
  log "turning ON $target: $deploy image $vimg (verified version $vver), replicas $current -> $replicas"
  if [[ "$current" != "$replicas" ]]; then
    kc -n "$NS" scale "deployment/$deploy" --replicas="$replicas" >/dev/null || fail "scaling $deploy failed"
  fi
  kc -n "$NS" annotate deployment "$deploy" --overwrite "$A/stopped-" >/dev/null || fail "annotating $deploy failed"
  kc -n "$NS" patch service "$PREVIEW_SVC" --type merge \
    -p "{\"spec\":{\"selector\":{\"app\":\"healthcare\",\"environment\":\"$target\"}}}" >/dev/null \
    || fail "pointing preview Service at $target failed"
  if ! wait_rollout "$deploy" "$ROLLOUT_TIMEOUT"; then
    log "$target did not become Ready; scaling it back to $current"
    kc -n "$NS" scale "deployment/$deploy" --replicas="$current" >/dev/null \
      || log "WARNING: could not scale $deploy back to $current replicas"
    fail "$target did not become Ready; production unchanged ($(active_env))"
  fi
  verify_deployment "$deploy" "$vimg" "$replicas"
  wait_pod_count "$(selector_of "$target")" "$replicas"
  verify_pods "$(selector_of "$target")" "$vimg" "$replicas"
  log "$target is ON with $replicas Ready pods; production still routes to $(active_env)"
  echo "BG_IMAGE=$vimg"
  echo "BG_VERSION=$vver"
}

# stop <env> <build>: turn an environment OFF (scale to 0). Never the live one.
do_stop() {
  local envname=$1 build=$2 deploy attempt left
  require_target "$envname"
  [[ "$(active_env)" != "$envname" ]] || fail "refusing to stop $envname: it is the LIVE production environment"
  deploy=$(deploy_of "$envname")
  log "turning OFF $envname ($deploy) - production routes to $(active_env)"
  kc -n "$NS" scale "deployment/$deploy" --replicas=0 >/dev/null || fail "scaling $deploy to 0 failed"
  kc -n "$NS" annotate deployment "$deploy" --overwrite "$A/stopped=true" "$A/stopped-by-build=$build" >/dev/null \
    || fail "annotating $deploy failed"
  for attempt in $(seq 1 45); do
    left=$(kc -n "$NS" get pods -l "$(selector_of "$envname")" --no-headers 2>/dev/null | wc -l)
    [[ "$left" -eq 0 ]] && break
    sleep 2
  done
  [[ "$left" -eq 0 ]] || fail "$envname still has $left pod(s) after 90s"
  log "$envname is OFF (0 pods); it keeps its verified image $(dep_annotation "$deploy" verified-image) for a later turn-ON or rollback"
}

do_rollback() {
  local build=$1 reason=$2 replicas=${3:-2} active prev prev_deploy prev_image prev_version desired ready live_image got
  active=$(active_env)
  prev=$(annotation previous-environment)
  prev_image=$(annotation previous-image)
  prev_version=$(annotation previous-version)
  log "rollback requested (build $build, reason: $reason); active=$active recorded-previous=${prev:-<none>}"
  [[ "$(annotation active-environment)" == "$active" ]] \
    || fail "state mismatch: selector says '$active' but annotation says '$(annotation active-environment)'; refusing automatic rollback"
  [[ -n "$prev" && "$prev" != "none" ]] || fail "no previous environment is recorded; nothing to roll back to"
  [[ "$prev" != "$active" ]] || fail "previous environment equals the active one ($prev)"
  prev_deploy=$(deploy_of "$prev"); [[ -n "$prev_deploy" ]] || fail "unknown previous environment '$prev'"

  # Never route traffic to something that is not the recorded, previously
  # verified production image.
  live_image=$(deploy_image "$prev_deploy")
  [[ "$live_image" == "$prev_image" ]] \
    || fail "$prev_deploy now runs $live_image, not the recorded previous production image $prev_image; refusing to roll back to an unverified image"
  read -r desired ready <<< "$(kc -n "$NS" get deployment "$prev_deploy" -o jsonpath='{.spec.replicas} {.status.readyReplicas}')"
  if [[ "$desired" == "0" ]]; then
    # The previous environment was turned OFF; bring it back with its
    # (just verified) recorded image before switching traffic to it.
    log "$prev was turned OFF; starting it with $replicas replicas before rolling back"
    kc -n "$NS" scale "deployment/$prev_deploy" --replicas="$replicas" >/dev/null || fail "scaling $prev_deploy failed"
    kc -n "$NS" annotate deployment "$prev_deploy" --overwrite "$A/stopped-" >/dev/null || fail "annotating $prev_deploy failed"
    wait_rollout "$prev_deploy" "$ROLLOUT_TIMEOUT" || fail "$prev did not become Ready; production unchanged"
    read -r desired ready <<< "$(kc -n "$NS" get deployment "$prev_deploy" -o jsonpath='{.spec.replicas} {.status.readyReplicas}')"
  fi
  [[ "${ready:-0}" -ge 1 && "${ready:-0}" -eq "$desired" ]] || fail "$prev_deploy is not fully Ready (ready=${ready:-0}/$desired)"
  verify_pods "$(selector_of "$prev")" "$prev_image" "$desired"
  got=$(first_pod_version "$(selector_of "$prev")")
  [[ "$got" == "$prev_version" ]] || fail "$prev reports version $got, recorded previous version is $prev_version"

  log "ROLLBACK: production Service selector environment=$active -> environment=$prev"
  kc -n "$NS" get service "$PROD_SVC" -o jsonpath='before: {.spec.selector}{"\n"}'
  kc -n "$NS" patch service "$PROD_SVC" --type merge \
    -p "{\"spec\":{\"selector\":{\"app\":\"healthcare\",\"environment\":\"$prev\"}}}" >/dev/null \
    || fail "patching production selector for rollback failed"
  kc -n "$NS" get service "$PROD_SVC" -o jsonpath='after:  {.spec.selector}{"\n"}'
  kc -n "$NS" annotate service "$PROD_SVC" --overwrite \
    "$A/active-environment=$prev" "$A/active-image=$prev_image" "$A/active-version=$prev_version" \
    "$A/previous-environment=$active" "$A/previous-image=$(annotation active-image)" "$A/previous-version=$(annotation active-version)" \
    "$A/last-operation=rollback" "$A/last-build=$build" "$A/rollback-reason=$reason" \
    "$A/last-change-utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null || fail "recording rollback annotations failed"
  [[ "$(active_env)" == "$prev" ]] || fail "selector is not environment=$prev after rollback patch"
  verify_service_endpoints "$PROD_SVC" "$(selector_of "$prev")" "$desired"
  verify_production_version "$prev_version"
  log "ROLLBACK COMPLETE: production serves $prev ($prev_image, version $prev_version); $active kept running for diagnosis"
}

do_state() {
  kc -n "$NS" get deployments -l app=healthcare -o wide
  kc -n "$NS" get pods -l app=healthcare -o wide
  kc -n "$NS" get services -o wide
  kc -n "$NS" get endpointslices -o wide
  kc -n "$NS" get service "$PROD_SVC" -o json | python3 -c '
import json, sys
svc = json.load(sys.stdin)
ann = {k.split("/", 1)[1]: v for k, v in svc["metadata"].get("annotations", {}).items() if k.startswith("healthcare.pbl/")}
print("STATE_JSON " + json.dumps({"service": svc["metadata"]["name"], "selector": svc["spec"]["selector"], "annotations": ann}, sort_keys=True))
'
}

case "$MODE" in
  prepare)  do_prepare "$@" ;;
  deploy)   do_deploy "$@" ;;
  wait)     do_wait "$@" ;;
  validate) do_validate "$@" ;;
  switch)   do_switch "$@" ;;
  monitor)  do_monitor "$@" ;;
  rollback) do_rollback "$@" ;;
  start)    do_start "$@" ;;
  stop)     do_stop "$@" ;;
  state)    do_state ;;
  unlock)   lock_release "$1" ;;
  *) echo "unknown mode: $MODE" >&2; exit 2 ;;
esac
