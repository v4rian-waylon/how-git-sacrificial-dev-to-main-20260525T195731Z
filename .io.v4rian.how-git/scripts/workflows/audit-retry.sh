#!/usr/bin/env bash
# audit-retry.sh — body of each audit-pushed-branch job's retry loop.
#
# Wraps a single audit script (compile / coverage / runtime) in the
# exponential-backoff retry loop the workflow used to inline. Same loop
# shape for every audit, so the three jobs share one script instead of
# duplicating the bash. The audit script name is passed as --audit.
#
# Exit code propagation: the wrapped audit's actual rc is captured
# directly via `bash cmd; rc=$?` (NOT via `if bash cmd; then exit 0; fi`
# which always reads rc=0 on the else branch — pool/n42's regression
# guard catches that pattern via the lifecycle suite).
#
# Usage:
#   audit-retry.sh --audit compile|coverage|runtime|commit-audit
#
# Environment:
#   MAX_ATTEMPTS  default 8
#   BASE_DELAY    default 5  (seconds; doubles per attempt)
#   MAX_DELAY     default 300 (cap on backoff)

set -uo pipefail

AUDIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --audit) AUDIT="$2"; shift 2 ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "X audit-retry.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

if [ -z "$AUDIT" ]; then
  echo "X audit-retry.sh: --audit <name> is required" >&2
  exit 2
fi

case "$AUDIT" in
  compile|coverage|runtime|commit-audit) ;;
  *) echo "X audit-retry.sh: --audit must be compile, coverage, or runtime (got '$AUDIT')" >&2; exit 2 ;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
AUDIT_SCRIPT="$REPO_ROOT/.io.v4rian.how-git/scripts/audits/${AUDIT}.sh"
if [ ! -x "$AUDIT_SCRIPT" ]; then
  echo "X audit-retry.sh: audit script not found or not executable at $AUDIT_SCRIPT" >&2
  exit 2
fi

MAX_ATTEMPTS="${MAX_ATTEMPTS:-8}"
BASE_DELAY="${BASE_DELAY:-5}"
MAX_DELAY="${MAX_DELAY:-300}"
delay=$BASE_DELAY

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  echo "=== ${AUDIT} attempt $attempt of $MAX_ATTEMPTS ==="
  bash "$AUDIT_SCRIPT"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    exit 0
  fi
  if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
    echo "${AUDIT} failed after $MAX_ATTEMPTS attempts (last rc=$rc)"
    exit "$rc"
  fi
  echo "${AUDIT} attempt $attempt failed (rc=$rc); sleeping ${delay}s before retry"
  sleep "$delay"
  delay=$(( delay * 2 ))
  if [ "$delay" -gt "$MAX_DELAY" ]; then delay=$MAX_DELAY; fi
done
