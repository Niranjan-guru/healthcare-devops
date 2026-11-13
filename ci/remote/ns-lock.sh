#!/usr/bin/env bash
# Namespace-wide deployment lock shared by the Activity 7 and Activity 8
# pipelines (Jenkins has no Lockable Resources plugin installed).
#
# Usage: ns-lock.sh <workdir> <acquire|release> <holder>
set -Eeuo pipefail
if [[ $# -ne 3 ]]; then
  echo "usage: $0 <workdir> <acquire|release> <holder>" >&2
  exit 2
fi
NS=healthcare
LOG_PREFIX=lock
DIAG_SELECTOR=app=healthcare
# shellcheck source=k8s-lib.sh
source "$(dirname "$0")/k8s-lib.sh"
diagnostics() { :; }   # lock failures need no workload diagnostics

case "$2" in
  acquire) lock_acquire "$3" ;;
  release) lock_release "$3" ;;
  *) echo "unknown action: $2" >&2; exit 2 ;;
esac
