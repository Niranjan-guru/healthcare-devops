#!/usr/bin/env bash
# Detached execution of remote operations on the EC2 host.
#
# Remote scripts are NOT run inside the SSH session that starts them: a
# dropped connection would SIGHUP the script (possibly half-way through a
# traffic switch) and lose its output. Instead the script runs detached
# (setsid + nohup), writing to <dir>/run.log and <dir>/exit.code, and the
# Jenkins side polls with short SSH calls.
#
# Usage:
#   job.sh <dir> start <entry-script> [args...]   start detached, print pid
#   job.sh <dir> poll  <from-line>                print log lines >= from-line,
#                                                 then __LINES__=<n> and, when
#                                                 finished, __EXIT__=<code>
#   job.sh <dir> stop                             terminate a still-running job
set -Eeuo pipefail
DIR=$1; ACTION=$2; shift 2
LOG="$DIR/run.log"; CODE="$DIR/exit.code"; PIDF="$DIR/job.pid"

case "$ACTION" in
  start)
    entry=$1; shift
    # Idempotent: a retried start (after a lost SSH response) must never
    # launch the operation twice.
    if [[ -f "$PIDF" ]]; then echo "__STARTED__=$(cat "$PIDF") (already started)"; exit 0; fi
    : > "$LOG"
    setsid nohup bash -c 'bash "$1" "${@:2}" >>"$0" 2>&1; echo $? > "$0.code.tmp"; mv "$0.code.tmp" "'"$CODE"'"' \
      "$LOG" "$DIR/$entry" "$DIR" "$@" </dev/null >/dev/null 2>&1 &
    echo $! > "$PIDF"
    echo "__STARTED__=$(cat "$PIDF")"
    ;;
  poll)
    from=$1
    total=$(wc -l < "$LOG")
    if (( total >= from )); then sed -n "${from},${total}p" "$LOG"; fi
    echo "__LINES__=$total"
    # Only report completion once every complete line has been delivered.
    if [[ -f "$CODE" ]]; then
      final=$(wc -l < "$LOG")
      if (( final == total )); then
        # A last line without a trailing newline is delivered here.
        if [[ -s "$LOG" && "$(tail -c 1 "$LOG" | od -An -c | tr -d ' ')" != '\n' ]]; then tail -n 1 "$LOG"; echo; fi
        echo "__EXIT__=$(cat "$CODE")"
      fi
    fi
    ;;
  stop)
    if [[ -f "$PIDF" ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
      kill -TERM -- "-$(cat "$PIDF")" 2>/dev/null || kill -TERM "$(cat "$PIDF")"
      echo "__STOPPED__"
    fi
    ;;
  *) echo "unknown action: $ACTION" >&2; exit 2 ;;
esac
