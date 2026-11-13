#!/usr/bin/env bash
# Activity 7 (rolling update) deployment, run on the EC2 K3s node.
# Applies the manifests rendered by Jenkins (exact image tag of the build)
# and verifies the rollout. Any failed check exits non-zero.
#
# Usage: deploy.sh <workdir> <apply|verify> <image> <expected-version> <build-number> <git-commit>
#   apply  - pre-flight checks, server-side validation, kubectl apply
#   verify - rollout status, replica/pod/probe/version/endpoint verification
#
# The rolling environment is labelled environment=rolling so it can coexist
# with the Activity 8 blue/green environments in the same namespace. The
# production Service (healthcare-service) belongs to Activity 8; Activity 7
# owns healthcare-rolling-service.
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
SVC=healthcare-rolling-service
SELECTOR=app=healthcare,environment=rolling
EXPECTED_REPLICAS=2
ROLLOUT_TIMEOUT=240s
LOG_PREFIX=deploy
DIAG_SELECTOR=$SELECTOR
# shellcheck source=k8s-lib.sh
source "$(dirname "$0")/k8s-lib.sh"

log "mode=$MODE build=$BUILD commit=$COMMIT image=$IMAGE"

do_apply() {
  require_node_ready
  grep -Fq "image: $IMAGE" "$WORKDIR/deployment.yaml" \
    || fail "rendered deployment.yaml does not reference $IMAGE"

  kc apply -f "$WORKDIR/namespace.yaml" || fail "applying namespace failed"

  # One-time migration: Deployment selectors are immutable. Before blue/green
  # was introduced this Deployment selected only app=healthcare, which would
  # also match the blue/green pods. Recreate it with the narrower selector.
  if kc -n "$NS" get deployment "$DEPLOY" >/dev/null 2>&1; then
    live_env=$(kc -n "$NS" get deployment "$DEPLOY" -o jsonpath='{.spec.selector.matchLabels.environment}')
    if [[ "$live_env" != "rolling" ]]; then
      log "MIGRATION: $DEPLOY has legacy selector (environment='$live_env'); recreating it with environment=rolling"
      kc -n "$NS" delete deployment "$DEPLOY" --wait=true --timeout=120s || fail "could not delete legacy $DEPLOY"
    fi
  fi

  # Each pod requests 50m CPU / 64Mi. A rolling update temporarily runs one
  # surge pod beyond the replicas that already exist.
  existing=$(kc -n "$NS" get pods -l "$SELECTOR" --no-headers 2>/dev/null | wc -l)
  new_pods=$(( EXPECTED_REPLICAS + 1 - existing ))
  if (( new_pods < 1 )); then new_pods=1; fi
  capacity_check $(( new_pods * 50 )) $(( new_pods * 64 ))

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
  log "Waiting for rollout (timeout $ROLLOUT_TIMEOUT)"
  wait_rollout "$DEPLOY" "$ROLLOUT_TIMEOUT" || fail "rollout did not complete within $ROLLOUT_TIMEOUT"
  verify_deployment "$DEPLOY" "$IMAGE" "$EXPECTED_REPLICAS"
  wait_pod_count "$SELECTOR" "$EXPECTED_REPLICAS"
  stability_window "$SELECTOR" "$IMAGE" "$EXPECTED_REPLICAS"
  verify_pod_versions "$SELECTOR" "$VERSION"
  verify_service_endpoints "$SVC" "$SELECTOR" "$EXPECTED_REPLICAS"

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
