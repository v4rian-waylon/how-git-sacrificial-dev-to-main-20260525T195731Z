#!/usr/bin/env bash
# apply-repo-rules.sh — apply v4rian branch protection and Repository Rules
# to a GitHub repo via the `gh` CLI. Idempotent.
#
# Run:
#   ./scripts/apply-repo-rules.sh
#
# Inputs:
#   ORG, REPO derive by default from `git config --get remote.origin.url`
#   so the script targets the current repo without any hardcoded owner/repo.
#   Override either with the same-named env var when applying rules to a
#   different target. ALLOCATOR_APP_ID is per-org and must be exported.
#
# Prerequisites:
#   - gh CLI installed and authenticated as a repo admin
#   - The branch-creator App is installed on the org/repo
#   - The branch-creator App's ID is known
#
# This script is a starting point; review carefully before running against a
# production repo. See docs/repo-config.md for the full set of rules and the
# verification checklist.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

# Off-grid repos do not run on GitHub-style Repository Rules. Refuse here
# so an admin does not accidentally apply rules against a remote the repo
# no longer considers authoritative.
MODE_VAL=$(get_mode 2>/dev/null || echo "connected")
if [ "$MODE_VAL" = "off-grid" ]; then
  echo "X apply-repo-rules: repo is in off-grid mode; Repository Rules do not apply." >&2
  echo "  Off-grid governance lives in admins.txt plus local hooks; remote rulesets are inert." >&2
  echo "  Flip back to connected first if this repo is rejoining a GitHub remote:" >&2
  echo "    bin/set-mode connected" >&2
  exit 2
fi

# ---- inputs (ORG + REPO default to origin; ALLOCATOR_APP_ID is per-org) ----
DEFAULT_OWNER_REPO=$(git config --get remote.origin.url 2>/dev/null \
  | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
ORG="${ORG:-${DEFAULT_OWNER_REPO%%/*}}"
REPO="${REPO:-${DEFAULT_OWNER_REPO##*/}}"
# The integration id of the GitHub Actions bot on the target repo.
# Find it via:
#   gh api /orgs/<org>/installations --jq '.installations[] | select(.app_slug=="github-actions") | .id'
# This is the identity the allocator and claim workflows run as.
ALLOCATOR_APP_ID="${ALLOCATOR_APP_ID:-${BRANCH_CREATOR_APP_ID:-CHANGEME}}"
# CI_BOT_APP_ID is no longer required separately; the bypass injection in
# apply_ruleset_from_file uses ALLOCATOR_APP_ID for the Integration actor
# and the OrganizationAdmin role as the escape hatch. The env var is still
# honored upstream by bootstrap-ci for backwards compat.
# ----------------------

if [[ -z "$ORG" || -z "$REPO" || "$ORG" = "$REPO" ]]; then
  echo "✗ apply-repo-rules: cannot derive ORG/REPO from origin URL" >&2
  echo "  Export ORG=<owner> and REPO=<name> explicitly, or run from a repo with a configured origin." >&2
  exit 2
fi
if [[ "$ALLOCATOR_APP_ID" == "CHANGEME" ]]; then
  echo "✗ apply-repo-rules: ALLOCATOR_APP_ID not set; export it before running" >&2
  exit 2
fi

REPO_FULL="$ORG/$REPO"
RULESETS_DIR="$SCRIPT_DIR/../rulesets"

echo "→ applying rules to $REPO_FULL"
echo ""

# --- main branch protection ---
# 'doc-freshness' is the PR-open gate emitted by
# .github/workflows/doc-freshness.yml that compares the dev → main diff
# substance against the user-facing docs (CHANGELOG, RUNBOOK,
# CONTRIBUTING, READMEs). Binding it as a required context here means
# a release cannot land while the docs lag the diff.
echo "→ main branch protection"
gh api -X PUT "repos/$REPO_FULL/branches/main/protection" \
  --field "required_status_checks[strict]=true" \
  --field "required_status_checks[contexts][]=release" \
  --field "required_status_checks[contexts][]=doc-freshness" \
  --field "enforce_admins=true" \
  --field "required_pull_request_reviews[required_approving_review_count]=1" \
  --field "required_pull_request_reviews[dismiss_stale_reviews]=true" \
  --field "restrictions=null" \
  --field "allow_force_pushes=false" \
  --field "allow_deletions=false" \
  >/dev/null
echo "  ✓ main protected (release, doc-freshness required)"

# --- dev branch protection ---
# The async audits and tests emitted by .github/workflows/ci-dispatch.yml on
# the pr-open trigger are required for any PR merge to dev. Names match the
# required.*.sh basenames (minus .sh) under
# .io.v4rian.how-git/ci/{tests,audits}/pr-open/ verbatim. The legacy 'bump'
# context is retained as the historical claim-on-merge gate.
echo "→ dev branch protection"
gh api -X PUT "repos/$REPO_FULL/branches/dev/protection" \
  --field "required_status_checks[strict]=true" \
  --field "required_status_checks[contexts][]=bump" \
  --field "required_status_checks[contexts][]=required.commit-audit" \
  --field "required_status_checks[contexts][]=required.compile" \
  --field "required_status_checks[contexts][]=required.coverage" \
  --field "required_status_checks[contexts][]=required.runtime" \
  --field "required_status_checks[contexts][]=required.offline-test-suites" \
  --field "enforce_admins=true" \
  --field "required_pull_request_reviews=null" \
  --field "restrictions=null" \
  --field "allow_force_pushes=false" \
  --field "allow_deletions=false" \
  >/dev/null
echo "  ✓ dev protected (required.commit-audit, required.compile, required.coverage, required.runtime, required.offline-test-suites required)"

apply_ruleset_from_file() {
  local label="$1"
  local src="$2"
  local out="/tmp/$(basename "$src")"
  # Substitute the ALLOCATOR_APP_ID placeholder where one is needed and drop
  # the human comment field so the GitHub API does not choke on the unknown
  # key. Rulesets whose bypass list is intentionally empty (e.g. required
  # status checks that no integration should ever bypass) keep their empty
  # bypass_actors instead of having the allocator+admin pair injected.
  #
  # When an injection is needed both the Actions bot integration AND the
  # OrganizationAdmin role are added. The bot is the normal automation
  # identity that runs the allocator and claim workflows; the admin role
  # bypass is the operator escape hatch for emergency overrides without
  # needing to flip enforcement off on the ruleset entirely.
  python3 -c '
import json, sys
src, dst, app_id = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as f:
    obj = json.load(f)
obj.pop("_comment", None)
DEFAULT_BYPASS = [
    {"actor_id": int(app_id), "actor_type": "Integration", "bypass_mode": "always"},
    {"actor_id": 1, "actor_type": "OrganizationAdmin", "bypass_mode": "always"},
]
existing = obj.get("bypass_actors")
if existing is None:
    obj["bypass_actors"] = DEFAULT_BYPASS
elif existing and any(
    isinstance(b.get("actor_id"), str) and "{" in b["actor_id"]
    for b in existing
):
    obj["bypass_actors"] = DEFAULT_BYPASS
# else: honor the file explicit bypass list as-is (empty or filled).
with open(dst, "w") as f:
    json.dump(obj, f, indent=2)
' "$src" "$out" "$ALLOCATOR_APP_ID"
  echo "→ $label"
  local resp rc
  resp=$(gh api -X POST "repos/$REPO_FULL/rulesets" --input "$out" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  ✓ created"
  elif printf '%s' "$resp" | grep -q "GitHub Pro"; then
    echo "  ✗ rulesets are not available on $REPO_FULL: GitHub Pro or public visibility required." >&2
    echo "    Branch protection (the legacy layer) still applies; the ruleset layer stays inert." >&2
    echo "    Run bin/lockdown for an exit-coded check, or upgrade and re-run this script." >&2
    return 1
  elif printf '%s' "$resp" | grep -q "name already exists"; then
    echo "  · ruleset already present (use bin/lockdown to update in place)"
  else
    echo "  ✗ ruleset apply failed: $resp" >&2
    return 1
  fi
}

# --- pool/* creation restriction ruleset ---
apply_ruleset_from_file "pool/* creation restriction" "$RULESETS_DIR/pool-creations.json"
echo "  ✓ pool/* creation restricted to allocator workflow identity"

# --- safety/* creation + update + deletion restriction ruleset ---
apply_ruleset_from_file "safety/* full lockdown" "$RULESETS_DIR/safety-lockdown.json"
echo "  ✓ safety/* locked down (created by allocator, deleted by claim, never modified)"

# --- dev required status checks ruleset ---
# Layered ON TOP of the dev branch protection above for belt-and-suspenders
# coverage: branch protection is the legacy mechanism, Repository Rulesets
# are the modern equivalent. GitHub merges the two, so the strictest wins.
apply_ruleset_from_file "dev required status checks" "$RULESETS_DIR/dev-required-checks.json"
echo "  ✓ dev requires required.commit-audit, required.compile, required.coverage, required.runtime, required.offline-test-suites checks before PR merge"

# --- vault/* read-only ruleset ---
apply_ruleset_from_file "vault/* read-only lockdown" "$RULESETS_DIR/vault-readonly.json"
echo "  ✓ vault/* frozen (created by archive flow, immutable afterward, no developer contributions)"

echo ""
echo "✓ rules applied to $REPO_FULL"
echo ""
echo "Next: walk through the verification checklist in docs/repo-config.md"
echo "      using a non-admin developer account. Confirm:"
echo "      - pool/* creation rejected for normal devs"
echo "      - safety/* update/delete rejected for normal devs"
echo "      - vault/* creation, update, and deletion rejected for normal devs (frozen archive)"
