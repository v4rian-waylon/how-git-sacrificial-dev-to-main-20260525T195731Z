#!/usr/bin/env bash
# required.claim.sh - pr-merge-main sys-layer audit
#
# Fires after every dev → main PR merge to perform the v4rian release
# claim: amend the merge commit, force-push main (preserving identity),
# promote the dev tag to the main release tag, archive the merged dev
# state, and run the 3-gate safety GC (paired vault exists + vault is
# ancestor of main + release tag exists → archive paired safety under
# safety/<vYYYY.MAIN>/<suffix>). This is the sys layer hook that
# replaces the prior .github/workflows/claim-on-merge-main.yml.
#
# Delegates to the existing retry-wrapped recipe:
#   .io.v4rian.how-git/scripts/workflows/claim-retry.sh --target main
#
# Environment expectations (set by ci-dispatch.yml's matrix runner):
#   CI_TRIGGER=pr-merge-main
#   CI_LAYER=sys
#   CI_KIND=audits
#   CI_CHECK_NAME=required.claim
#   GITHUB_TOKEN with contents:write so the main force-push and tag promotion succeed

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
RETRY="$REPO_ROOT/.io.v4rian.how-git/scripts/workflows/claim-retry.sh"

if [ ! -x "$RETRY" ]; then
  echo "X required.claim: claim-retry.sh missing or not executable at $RETRY" >&2
  exit 1
fi

exec bash "$RETRY" --target main
