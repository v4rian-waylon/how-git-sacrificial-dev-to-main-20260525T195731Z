#!/usr/bin/env bash
# required.claim.sh - pr-merge-dev sys-layer audit
#
# Fires after every pool/* → dev PR merge to perform the v4rian claim:
# amend the merge commit subject + body into the spec shape, force-push
# dev (preserving the merger's identity), tag the merge SHA with the
# next bin/version --seal, and archive the merged pool/* branch to its
# paired vault/<vYYYY.MAIN>/<suffix> ref. This is the sys layer hook
# that replaces the prior .github/workflows/claim-on-merge-dev.yml.
#
# Delegates to the existing retry-wrapped recipe:
#   .io.v4rian.how-git/scripts/workflows/claim-retry.sh --target dev
#
# The claim-retry wrapper handles exponential backoff for transient
# remote failures and surfaces the final outcome via exit code.
#
# Environment expectations (set by ci-dispatch.yml's matrix runner):
#   CI_TRIGGER=pr-merge-dev
#   CI_LAYER=sys
#   CI_KIND=audits
#   CI_CHECK_NAME=required.claim
#   GITHUB_TOKEN with contents:write so the dev force-push and tag push succeed
#
# Marker gate: the legacy workflow had no marker gate because every
# consumer ALSO runs the claim flow on their own merges. The sys-layer
# script ships as a default consumer override target; consumers needing
# a different claim flow drop their own ci/audits/pr-merge-dev/claim.sh
# at the usr layer to shadow this one.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
RETRY="$REPO_ROOT/.io.v4rian.how-git/scripts/workflows/claim-retry.sh"

if [ ! -x "$RETRY" ]; then
  echo "X required.claim: claim-retry.sh missing or not executable at $RETRY" >&2
  exit 1
fi

exec bash "$RETRY" --target dev
