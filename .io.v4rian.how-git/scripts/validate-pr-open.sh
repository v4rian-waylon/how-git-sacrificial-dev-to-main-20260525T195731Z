#!/usr/bin/env bash
# validate-pr-open.sh — canonical PR-open validator for the v4rian model.
#
# Invoked by .github/workflows/validate-pr-open.yml on every
# pull_request: [opened, edited, synchronize] event targeting dev or
# main. Same script handles both pool→dev and dev→main flows so the
# shielding, body amendment, and status-check posting all funnel
# through one place. Devs cannot evade by opening a PR a different
# way — the workflow re-runs server side and the dev branch ruleset
# requires the opened-via-correct-flow check before merge.
#
# Behavior in order:
#
#   1. Hard reject when the source branch shape is wrong for the
#      target. pool/* → dev and dev → main are the only legal pairs.
#      Anything else gets the PR closed via `gh pr close` with a
#      comment naming the rule violated.
#
#   2. Hard reject when the target is `main` AND the actor (PR author)
#      is not an admin on the repo. Releases are admin-only by design.
#      PRs into `dev` (the pool→dev path) are openable by any dev with
#      write access — the deeper enforcement on dev happens via the
#      server-side ruleset and the async audit-pushed-branch checks.
#
#   3. Run the shared auto-fix pass (scripts/lib/auto-fix-commit-message.sh)
#      over the PR body. Embed the workflow signature as an HTML
#      comment so re-runs can detect a body that has already been
#      validated and skip the diff-and-amend round trip when nothing
#      changed.
#
#   4. Post the opened-via-correct-flow status check on the PR head
#      commit. Green when all checks above passed; red when the PR
#      was closed for a rule violation.
#
# PR title amendment was previously Step 3 but moved into the claim
# scripts (claim-dev-merge.sh and claim-main-release.sh), which now
# derive the canonical merge subject directly from the source branch
# and version. The PR title is no longer load-bearing for merge log
# canonicity; the merge commit subject is the source of truth.
#
# Env contract (all set by the workflow):
#
#   PR_NUMBER       — PR number (e.g. 42)
#   PR_HEAD_REF     — source branch (e.g. pool/n7.feature.foo)
#   PR_BASE_REF     — target branch (dev or main)
#   PR_HEAD_SHA     — head commit SHA the status check attaches to
#   PR_ACTOR        — PR author login
#   PR_BODY         — current body text
#   GH_TOKEN        — workflow token, scopes contents:read + pull-requests:write + statuses:write
#   GITHUB_REPOSITORY — owner/repo
#   GITHUB_RUN_ID   — for signature embedding
#
# Exit codes:
#   0  — validation passed (PR amended where needed, status check green)
#   1  — validation failed for a recoverable reason; status check red, PR may stay open
#   2  — fatal: PR closed with comment because source/actor was illegal
#   3  — env contract violation (missing required input)

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate the script + lib + bin under the namespace dir, regardless of cwd.
# ---------------------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NS_DIR=$(dirname "$SCRIPT_DIR")
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)
AUTO_FIX_LIB="$SCRIPT_DIR/lib/auto-fix-commit-message.sh"

# Test mode short-circuit: when LIFECYCLE_TEST_MODE=1 is set and the
# required env vars are absent, skip the gh-touching path so the unit
# tests can source this file or invoke its helpers without a live API.
if [ "${LIFECYCLE_TEST_MODE:-0}" = "1" ] && [ -z "${PR_NUMBER:-}" ]; then
  echo "→ test-mode: PR_NUMBER unset; sourcing helpers without gh dispatch"
  return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# Env contract validation
# ---------------------------------------------------------------------------
require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "X validate-pr-open: required env var $name is unset" >&2
    exit 3
  fi
}

require_env PR_NUMBER
require_env PR_HEAD_REF
require_env PR_BASE_REF
require_env PR_HEAD_SHA
require_env PR_ACTOR
require_env GH_TOKEN
require_env GITHUB_REPOSITORY

# Optional fields default to empty so amending against a blank body works.
PR_BODY="${PR_BODY:-}"
GITHUB_RUN_ID="${GITHUB_RUN_ID:-0}"

REPO="$GITHUB_REPOSITORY"
SIGNATURE="<!-- opened-via-correct-flow run=${GITHUB_RUN_ID} -->"
STATUS_CONTEXT="opened-via-correct-flow"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Post a commit status (the required check on the PR head commit).
post_status() {
  local state="$1"   # success | failure | pending | error
  local desc="$2"
  gh api -X POST \
    "repos/${REPO}/statuses/${PR_HEAD_SHA}" \
    -f "state=${state}" \
    -f "context=${STATUS_CONTEXT}" \
    -f "description=${desc}" \
    --silent 2>/dev/null || true
}

# Close the PR with a comment naming the rule violated. Used only on
# the hard-reject paths (illegal source branch, non-admin actor).
close_pr_with_reason() {
  local reason="$1"
  gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$reason" >/dev/null 2>&1 || true
  gh pr close "$PR_NUMBER" --repo "$REPO" --comment "$reason" >/dev/null 2>&1 || true
  post_status "failure" "PR closed: rule violated"
}

# Derive [KIND] from a pool/* branch name. Returns the bracketed
# canonical tag for the auto-derived title. Mapping mirrors the
# allocator's kind set.
kind_to_tag() {
  case "$1" in
    feature)    echo "[NEW]" ;;
    fix)        echo "[FIX]" ;;
    refactor)   echo "[REFACTOR]" ;;
    r\&d)       echo "[REFACTOR]" ;;
    reconcile)  echo "[REFACTOR]" ;;
    doc)        echo "[DOCS]" ;;
    *)          echo "[REFACTOR]" ;;
  esac
}

# Pull the kind segment out of a pool/nN.kind.short branch. Handles both
# the legacy flat layout (pool/nN.kind.short) and the vYYYY.MAIN/ prefixed
# layout (pool/vYYYY.MAIN/nN.kind.short) by consuming the optional major
# segment before extracting the kind.
pool_kind() {
  echo "$1" | sed -E 's|^pool/(v[0-9]+\.[0-9]+/)?n[0-9]+\.([a-z&]+)\..*|\2|'
}

# ---------------------------------------------------------------------------
# Step 1 — source-branch shape validation
# ---------------------------------------------------------------------------

case "$PR_BASE_REF" in
  dev)
    if ! [[ "$PR_HEAD_REF" =~ ^pool/(v[0-9]{4}\.[0-9]+/)?n[0-9]+\.(feature|fix|r\&d|refactor|reconcile|doc)\. ]]; then
      reason="PR closed: only pool/[vYYYY.MAIN/]nN.kind.short-name branches may open PRs into dev. Source '${PR_HEAD_REF}' violates the v4rian branch shape rule. See .io.v4rian.how-git/docs/Git_Strategy.md."
      echo "X $reason" >&2
      close_pr_with_reason "$reason"
      exit 2
    fi
    ;;
  main)
    if [ "$PR_HEAD_REF" != "dev" ]; then
      reason="PR closed: only the dev branch may open PRs into main. Source '${PR_HEAD_REF}' violates the v4rian release-promotion rule. See .io.v4rian.how-git/docs/Git_Strategy.md."
      echo "X $reason" >&2
      close_pr_with_reason "$reason"
      exit 2
    fi
    ;;
  *)
    reason="PR closed: validate-pr-open only governs PRs into dev or main. Target '${PR_BASE_REF}' is out of scope; open the PR against dev (for pool/* sources) or main (for dev)."
    echo "X $reason" >&2
    close_pr_with_reason "$reason"
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# Step 2 — actor (PR author) admin check, ONLY for dev → main PRs
# ---------------------------------------------------------------------------
# Pool → dev PRs are openable by any dev with write access; the deeper
# enforcement on dev is the server-side ruleset plus the async audit
# checks. Dev → main PRs ARE admin-only because they promote a release.

if [ "$PR_BASE_REF" = "main" ]; then
  PERM=$(gh api "repos/${REPO}/collaborators/${PR_ACTOR}/permission" --jq '.permission' 2>/dev/null || echo "unknown")
  echo "→ actor=${PR_ACTOR} permission=${PERM} (base=main; admin required)"
  if [ "$PERM" != "admin" ]; then
    reason="PR closed: actor '${PR_ACTOR}' has permission '${PERM}' on ${REPO} but admin is required to open dev → main release PRs under the v4rian model. Ask a repo admin to open the release PR on your behalf."
    echo "X $reason" >&2
    close_pr_with_reason "$reason"
    exit 2
  fi
else
  echo "→ actor=${PR_ACTOR} (base=${PR_BASE_REF}; admin check not required for pool → dev)"
fi

# ---------------------------------------------------------------------------
# Step 3 — auto-fix pass over the body + signature embed
# ---------------------------------------------------------------------------

if [ ! -f "$AUTO_FIX_LIB" ]; then
  echo "X validate-pr-open: auto-fix library missing at $AUTO_FIX_LIB" >&2
  post_status "error" "auto-fix library missing"
  exit 1
fi

# Persist the body to a temp file so the library can rewrite it in place.
WORK=$(mktemp -d -t validate-pr-open-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
BODY_FILE="$WORK/body.txt"

# Strip any prior signature line so we don't accumulate them on re-runs.
printf '%s\n' "$PR_BODY" \
  | sed -E '/<!-- opened-via-correct-flow run=[^>]* -->/d' \
  > "$BODY_FILE"

# shellcheck disable=SC1090
. "$AUTO_FIX_LIB"

# Derive a best-effort tag hint from the source branch shape so the
# auto-fix layer can prepend it to the body if no tag is present.
# Bodies normally don't carry a title line; this is a no-op for
# well-formed bodies that already lead with [TAG].
case "$PR_BASE_REF" in
  dev)
    KIND_HINT=$(pool_kind "$PR_HEAD_REF" 2>/dev/null || echo "")
    if [ -n "$KIND_HINT" ]; then
      TITLE_TAG=$(kind_to_tag "$KIND_HINT")
    else
      TITLE_TAG="[REFACTOR]"
    fi
    ;;
  main)
    TITLE_TAG="[MERGE]"
    ;;
  *)
    TITLE_TAG="[REFACTOR]"
    ;;
esac
export AUTO_FIX_DERIVED_TAG="$TITLE_TAG"

auto_fix_message "$BODY_FILE"

# Append the fresh signature line at the bottom.
{
  printf '\n'
  printf '%s\n' "$SIGNATURE"
} >> "$BODY_FILE"

NEW_BODY=$(cat "$BODY_FILE")

if [ "$PR_BODY" != "$NEW_BODY" ]; then
  echo "→ amending body (auto-fix changed content or signature drifted)"
  gh pr edit "$PR_NUMBER" --repo "$REPO" --body "$NEW_BODY" >/dev/null 2>&1 || {
    echo "X body amendment failed" >&2
    post_status "failure" "body amendment failed"
    exit 1
  }
else
  echo "→ body already canonical; no amendment needed"
fi

# ---------------------------------------------------------------------------
# Step 5 — post the green status check
# ---------------------------------------------------------------------------

post_status "success" "PR opened via the v4rian validate-pr-open flow"
echo "OK validate-pr-open: status check posted green for PR #${PR_NUMBER}"
exit 0
