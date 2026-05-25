#!/usr/bin/env bash
# required.compile.sh — sys-layer push audit that fronts the
# existing compile recipe through the new layered dispatcher.
#
# Runs on every push that lands a new head SHA. The pr-open event
# does NOT re-run this audit; instead the PR reuses the latest
# push-validation result for the head SHA. Branch protection on dev
# binds the check by context name ('required.compile') regardless of
# which event published it, so the PR turns green as soon as the
# push audit lands a successful status on the head SHA.
#
# Delegates to the canonical audit-retry.sh wrapper around
# .io.v4rian.how-git/scripts/audits/compile.sh so the established
# exponential-backoff retry semantics survive the migration. The
# required. prefix on this filename signals to bin/bootstrap-ci that
# the check is required for PR merge (added to dev branch protection
# in step 5 of bootstrap-ci).
#
# The check posts as 'required.compile' via the ci-dispatch matrix
# (the basename minus the .sh extension is the check context name).
# A consumer adopting the framework can ship its own usr-layer
# ci/audits/push/required.compile.sh which the dispatcher will
# layer alongside this one — both run as separate checks with
# distinct names per their layer.

set -uo pipefail
exec bash "$(git rev-parse --show-toplevel)/.io.v4rian.how-git/scripts/workflows/audit-retry.sh" --audit compile
