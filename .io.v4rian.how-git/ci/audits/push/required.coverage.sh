#!/usr/bin/env bash
# required.coverage.sh — sys-layer push audit that fronts the
# existing coverage recipe through the new layered dispatcher.
#
# Runs on every push that lands a new head SHA. The pr-open event
# does NOT re-run this audit; the PR reuses the latest push-
# validation result for the head SHA via the bound check context
# name 'required.coverage'.
#
# Delegates to audit-retry.sh --audit coverage so the established
# retry semantics survive the migration. Posts as
# 'required.coverage'; required.* prefix binds it as a required
# status check via bin/bootstrap-ci step 5.

set -uo pipefail
exec bash "$(git rev-parse --show-toplevel)/.io.v4rian.how-git/scripts/workflows/audit-retry.sh" --audit coverage
