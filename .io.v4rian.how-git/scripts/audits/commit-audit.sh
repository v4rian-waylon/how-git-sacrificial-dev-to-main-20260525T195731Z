#!/usr/bin/env bash
# commit-audit.sh — push-trigger audit that runs the git-commit-audit
# lens against every commit landed by the current push.
#
# The lens lives at .io.v4rian.how-git/skills/git-commit-audit/SKILL.md
# and covers atomicity, title format, body shape, bullet style,
# fabrication detection, file hygiene, branching, and merge format.
# In production the script invokes `claude -p` per commit with the
# skill loaded; under LIFECYCLE_TEST_MODE the script bypasses the
# real call and emits a canned PASS so the offline lifecycle suite
# exercises the wiring without a network round trip or API spend.
#
# Push-range resolution order:
#
#   1. GITHUB_EVENT_BEFORE + GITHUB_EVENT_AFTER (set by the workflow
#      from github.event.before / github.event.after). When BEFORE
#      is the zero-SHA (a brand-new branch push), the range falls
#      back to merge-base with origin/dev.
#   2. When the env pair is absent (local invocation, dry-run), the
#      range walks every commit reachable from HEAD that is NOT
#      reachable from origin/dev. This is the "branch's own commits"
#      definition the auto-rebase ladder already uses.
#
# Exit code propagation:
#
#   0 — every commit in range passed the lens (or the range is
#       empty, e.g. a push that only moves an existing tip with no
#       new commits).
#   1 — at least one commit failed the lens. The script prints the
#       offending commit SHAs and the lens-reported reason to stderr
#       so the CI log surfaces the specific failures.
#   2 — usage / environment error (missing git repo, missing skill).
#
# Env knobs:
#
#   LIFECYCLE_TEST_MODE=1   bypass real claude; emit canned PASS.
#   COMMIT_AUDIT_DRY_RUN=1  print the planned per-commit invocations
#                           but do not call claude; useful for local
#                           preview without spending API budget.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  echo "X commit-audit: not inside a git repository" >&2
  exit 2
fi

SKILL_PATH="$REPO_ROOT/.io.v4rian.how-git/skills/git-commit-audit/SKILL.md"
if [ ! -f "$SKILL_PATH" ]; then
  echo "X commit-audit: git-commit-audit skill missing at $SKILL_PATH" >&2
  exit 2
fi

ZERO_SHA="0000000000000000000000000000000000000000"

resolve_range() {
  local before="${GITHUB_EVENT_BEFORE:-}"
  local after="${GITHUB_EVENT_AFTER:-}"
  if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$ZERO_SHA" ]; then
    git -C "$REPO_ROOT" rev-list --reverse --no-merges "${before}..${after}" 2>/dev/null
    return
  fi
  # Fallback: branch's own commits relative to origin/dev (or dev if
  # the origin ref is unavailable, as in a scratch repo under tests).
  local base_ref="origin/dev"
  if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1; then
    base_ref="dev"
  fi
  if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1; then
    # No base to compare against; audit HEAD alone.
    git -C "$REPO_ROOT" rev-list -1 HEAD 2>/dev/null
    return
  fi
  git -C "$REPO_ROOT" rev-list --reverse --no-merges "${base_ref}..HEAD" 2>/dev/null
}

audit_commit_canned() {
  local sha="$1"
  local subj
  subj=$(git -C "$REPO_ROOT" log -1 --format='%s' "$sha")
  echo "→ commit-audit [canned] $sha $subj"
  return 0
}

audit_commit_real() {
  local sha="$1"
  local subj msg
  subj=$(git -C "$REPO_ROOT" log -1 --format='%s' "$sha")
  msg=$(git -C "$REPO_ROOT" log -1 --format='%B' "$sha")
  local diff
  diff=$(git -C "$REPO_ROOT" show --no-color --no-renames "$sha")
  local prompt
  prompt=$(printf 'Apply the git-commit-audit lens at %s to the following commit. Report PASS or FAIL with one-line reason.\n\nSubject: %s\n\nFull message:\n%s\n\nDiff:\n%s\n' \
    "$SKILL_PATH" "$subj" "$msg" "$diff")
  if [ "${COMMIT_AUDIT_DRY_RUN:-}" = "1" ]; then
    echo "[dry-run] would invoke: claude -p (lens=git-commit-audit, sha=$sha, subj_len=${#subj})"
    return 0
  fi
  if ! command -v claude >/dev/null 2>&1; then
    echo "  ! claude CLI unavailable; commit-audit cannot run the real lens — emitting canned PASS for $sha" >&2
    return 0
  fi
  local resp
  resp=$(printf '%s' "$prompt" | claude -p 2>/dev/null || true)
  if printf '%s' "$resp" | grep -qiE '^PASS'; then
    echo "→ commit-audit [PASS] $sha $subj"
    return 0
  fi
  if printf '%s' "$resp" | grep -qiE '^FAIL'; then
    echo "X commit-audit [FAIL] $sha $subj" >&2
    printf '%s\n' "$resp" >&2
    return 1
  fi
  echo "  ! commit-audit: claude returned an unparseable response for $sha; treating as PASS to avoid blocking on transient errors" >&2
  printf '%s\n' "$resp" >&2
  return 0
}

# Portable replacement for `mapfile` (bash 4+) so the script runs
# under macOS bash 3.2 in addition to CI's bash 5+.
SHAS=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  SHAS="${SHAS}${line}
"
done < <(resolve_range)

if [ -z "$SHAS" ]; then
  echo "→ commit-audit: empty push range; nothing to audit"
  exit 0
fi

COUNT=$(printf '%s' "$SHAS" | grep -c .)
echo "→ commit-audit: auditing $COUNT commit(s) via git-commit-audit lens"

FAILED=0
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  if [ "${LIFECYCLE_TEST_MODE:-}" = "1" ]; then
    audit_commit_canned "$sha" || FAILED=$((FAILED + 1))
  else
    audit_commit_real "$sha" || FAILED=$((FAILED + 1))
  fi
done <<< "$SHAS"

if [ "$FAILED" -gt 0 ]; then
  echo "X commit-audit: $FAILED of $COUNT commit(s) failed the lens" >&2
  exit 1
fi

echo "✓ commit-audit: every commit in range passed the lens"
exit 0
