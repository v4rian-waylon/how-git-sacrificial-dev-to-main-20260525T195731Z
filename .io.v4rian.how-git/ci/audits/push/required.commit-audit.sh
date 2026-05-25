#!/usr/bin/env bash
# required.commit-audit.sh — sys-layer push audit that runs the
# git-commit-audit lens against every commit in the push range.
#
# Runs on every push that lands a new head SHA. The pr-open event
# does NOT re-run this audit; the PR reuses the latest push-
# validation result for the head SHA via the bound check context
# name 'required.commit-audit', which is auto-discovered as a
# required status check on PRs into dev by bin/bootstrap-ci's
# _discover_required_checks walk.
#
# Delegates to audit-retry.sh --audit commit-audit so the
# exponential-backoff retry semantics the other push audits use
# survive transient claude API failures.

set -uo pipefail
exec bash "$(git rev-parse --show-toplevel)/.io.v4rian.how-git/scripts/workflows/audit-retry.sh" --audit commit-audit
