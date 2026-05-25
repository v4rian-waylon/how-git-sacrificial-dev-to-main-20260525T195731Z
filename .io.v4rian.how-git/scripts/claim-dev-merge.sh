#!/usr/bin/env bash
# claim-dev-merge.sh - git-native claim of the next dev version.
#
# Run this LOCALLY on the `dev` branch immediately after a working-branch
# PR has landed (via GitHub merge-button, manual `git merge --no-ff`, or
# any other path). Tags the merge commit with the dev version returned
# by `bin/version --seal`. No VERSION file is touched - tags are the
# canonical version state ("seal of approval"). No CI required.
#
# This script is the canonical source of truth for the dev → dev claim
# operation. It is the same logic CI would run, but it runs from git, on
# anyone's machine, with no GitHub Actions dependency.
#
# Version derivation: this script never computes the dev tag itself.
# `bin/version` is the single authority for version math across the
# template (claim flow, open-pr, build-on-tag, auto-rebase, status).
# The script's only job here is to consume what `bin/version` returns
# and tag the merge commit with it. The flag used is `--seal`: claim
# runs AFTER the pool->dev merge has landed, so the merge already
# counts in `bin/version`'s first-parent walk and `--seal` returns the
# correct vYEAR.SERIES.DEV value for that merge commit. `--next-dev`
# is what the FOLLOWING merge would claim.
#
# Steps:
#   1. Verify HEAD is `dev`
#   2. Verify working tree is clean (no uncommitted changes)
#   3. Pull dev (unless --skip-pull)
#   4. Ask `bin/version --seal` for the tag to claim on the merge commit
#   5. Refuse if the tag already exists (claim is already in)
#   6. Annotated-tag HEAD, push tag
#   7. Invoke auto-rebase-pools-after-dev-merge.sh as a best-effort pass
#
# Dependencies: bash, git.
#
# Usage:
#   claim-dev-merge.sh                  do the claim
#   claim-dev-merge.sh --dry-run        show what would happen, no mutations
#   claim-dev-merge.sh --skip-pull      skip `git pull origin dev`
#   claim-dev-merge.sh -h | --help      print this help

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  echo "✗ claim-dev-merge.sh: not inside a git repo" >&2
  exit 2
fi

NS_DIR=$(basename "$(dirname "$SCRIPT_DIR")")
HOOKS_PATH_OVERRIDE="$NS_DIR/githooks"
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"
( cd "$REPO_ROOT" && ensure_hooks_path )

VERSION_BIN="$REPO_ROOT/$NS_DIR/bin/version"

DRY_RUN=false
SKIP_PULL=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; shift ;;
    --skip-pull) SKIP_PULL=true; shift ;;
    -h|--help)   sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Mode-aware mutation gate. Off-grid repos do not accept CI-driven claims —
# the workflow may still be wired up in the repo for a future flip back, but
# in off-grid mode the authoritative path is local (bin/finalize-pool-merge).
# Connected repos require CI=true (or --dry-run / LIFECYCLE_TEST_MODE=1) so
# local invocations cannot race the workflow and produce duplicate tags on
# the same commit (the 2026-05-23 incident).
MODE_VAL=$(get_mode)
if [ "$MODE_VAL" = "off-grid" ] && [ "${CI:-}" = "true" ]; then
  echo "→ mode is off-grid; CI-driven claim is a no-op (off-grid claims run locally via bin/finalize-pool-merge)"
  exit 0
fi
if [ "$MODE_VAL" != "off-grid" ] \
    && [ "${CI:-}" != "true" ] \
    && [ "${LIFECYCLE_TEST_MODE:-}" != "1" ] \
    && ! $DRY_RUN; then
  echo "✗ claim-dev-merge is a CI-only operation in connected mode. Trigger a tag claim by pushing to dev; use --dry-run for local diagnostic, or flip to off-grid via bin/set-mode off-grid for local-driven ceremonies." >&2
  exit 2
fi

cd "$REPO_ROOT"

HEAD=$(git rev-parse --abbrev-ref HEAD)
[ "$HEAD" = "dev" ] || { echo "✗ HEAD is '$HEAD', not 'dev'. Switch to dev first." >&2; exit 2; }

if [ -n "$(git status --porcelain)" ]; then
  echo "✗ working tree dirty - commit or stash before claiming" >&2
  git status --short >&2
  exit 2
fi

if ! $SKIP_PULL; then
  echo "→ pulling origin/dev (use --skip-pull to bypass)"
  git pull -q --ff-only origin dev
fi

# --- Compute the dev tag to claim via the single authority: bin/version ---
# Delegated entirely to `bin/version --seal`. Any other consumer that
# needs to know the current dev tag must call the same binary; never
# duplicate the math here or anywhere else. `--seal` (not --next-dev)
# is the right flag because claim runs AFTER the pool->dev merge lands
# and the merge already counts in `bin/version`'s first-parent walk.
if [ ! -x "$VERSION_BIN" ]; then
  echo "✗ bin/version missing or not executable at $VERSION_BIN" >&2
  exit 2
fi

NEXT=$("$VERSION_BIN" --seal) || {
  echo "✗ bin/version --seal failed; cannot derive dev tag to claim" >&2
  exit 1
}

echo "→ dev tag to claim (from bin/version --seal): $NEXT"

if git rev-parse "$NEXT" >/dev/null 2>&1; then
  echo "✗ tag $NEXT already exists locally - has this merge already been claimed?" >&2
  echo "  Drop the local tag if re-running after a partial failure:" >&2
  echo "    git tag -d $NEXT" >&2
  exit 2
fi
if git ls-remote --tags origin "refs/tags/$NEXT" | grep -q "$NEXT"; then
  echo "✗ tag $NEXT already exists on origin - claim conflict" >&2
  exit 2
fi

# Detect the just-merged pool/* branch from HEAD's merge subject so the
# auto-archive pass downstream knows what to vault. The character class
# includes / so the vYYYY.MAIN/ major-prefix segment (pool/v2026.0/nN.kind
# .short) is captured intact alongside the legacy flat layout.
HEAD_SUBJ=$(git log -1 --format='%s' HEAD)
MERGED_POOL=$(printf '%s' "$HEAD_SUBJ" | sed -nE \
  -e "s|^Merge pull request #[0-9]+ from [^/]+/(pool/[a-zA-Z0-9./&-]+)$|\1|p" \
  -e "s|^Merge branch '(pool/[a-zA-Z0-9./&-]+)'.*|\1|p" \
  -e "s|^\[MERGE\] (pool/[a-zA-Z0-9./&-]+) into dev.*|\1|p" \
  | head -1)

if $DRY_RUN; then
  echo "[dry-run] would tag HEAD ($(git rev-parse HEAD)) as $NEXT, push tag, archive $MERGED_POOL, run auto-rebase pass"
  exit 0
fi

# ---------------------------------------------------------------------------
# Amend the merge commit subject to the spec format
# [MERGE] <source> into dev: vYYYY.SERIES.DEV
# so the dev log reads canonically regardless of how the merge was triggered.
# Connected mode: pull PR title+body via gh for full parity with the PR.
# Off-grid mode: derive title from MERGED_POOL + NEXT; preserve the operator's
# existing merge body (they wrote it via git merge --no-ff -m).
# ---------------------------------------------------------------------------

echo "→ mode: $MODE_VAL"

if [ -n "$MERGED_POOL" ]; then
  NEW_SUBJECT="[MERGE] $MERGED_POOL into dev: $NEXT"
  CUR_SUBJECT=$(git log -1 --format='%s' HEAD)

  if [ "$CUR_SUBJECT" = "$NEW_SUBJECT" ]; then
    echo "→ merge subject already in spec format; skipping amend"
  else
    OLD_HEAD=$(git rev-parse HEAD)
    ORIG_AUTHOR_NAME=$(git log -1 --format='%an' HEAD)
    ORIG_AUTHOR_EMAIL=$(git log -1 --format='%ae' HEAD)
    ORIG_AUTHOR_DATE=$(git log -1 --format='%aI' HEAD)
    ORIG_COMMITTER_DATE=$(git log -1 --format='%cI' HEAD)

    NEW_BODY=""
    if [ "$MODE_VAL" = "connected" ] && command -v gh >/dev/null 2>&1; then
      # Pull PR title+body. Resolve the PR number from the merge subject's
      # 'Merge pull request #N' shape; if absent (e.g. local merge pushed up),
      # fall back to gh's search for closed PRs whose head matches MERGED_POOL.
      PR_NUM=$(printf '%s' "$CUR_SUBJECT" | sed -nE 's|^Merge pull request #([0-9]+) from .*|\1|p')
      if [ -z "$PR_NUM" ]; then
        REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null || true)
        OWNER_REPO=$(echo "$REMOTE_URL" | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
        if [ -n "$OWNER_REPO" ]; then
          PR_NUM=$(gh pr list --repo "$OWNER_REPO" --state merged --head "${MERGED_POOL#pool/}" --json number --jq '.[0].number' 2>/dev/null || true)
          # gh pr list --head wants the branch name without owner prefix; try once with pool/ stripped.
          if [ -z "$PR_NUM" ]; then
            PR_NUM=$(gh pr list --repo "$OWNER_REPO" --state merged --head "$MERGED_POOL" --json number --jq '.[0].number' 2>/dev/null || true)
          fi
        fi
      fi
      if [ -n "$PR_NUM" ]; then
        REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null || true)
        OWNER_REPO=$(echo "$REMOTE_URL" | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
        NEW_BODY=$(gh pr view "$PR_NUM" --repo "$OWNER_REPO" --json body --jq '.body' 2>/dev/null || true)
        if [ -z "$NEW_BODY" ]; then
          echo "  ! PR #$PR_NUM body fetch returned empty (gh auth missing? rate limit? body genuinely empty?); falling back to existing merge body so the recap section is not silently dropped" >&2
          NEW_BODY=$(git log -1 --format='%b' HEAD)
        else
          echo "→ amend body source: PR #$PR_NUM via gh"
        fi
      else
        echo "  ! no PR number resolvable; amend body falls back to current merge body"
        NEW_BODY=$(git log -1 --format='%b' HEAD)
      fi
    else
      # Off-grid path or gh unavailable: preserve current merge body.
      NEW_BODY=$(git log -1 --format='%b' HEAD)
      [ "$MODE_VAL" = "off-grid" ] && echo "→ amend body source: existing merge body (off-grid mode)"
    fi

    # Prepend the PR backreference as the first body paragraph (right
    # after the subject line) so the merge commit's PR pointer is the
    # first thing a reader sees under the spec-format subject, before
    # the recap section. The PR number is followed by the full GitHub
    # PR URL so a reader can click straight through to the source PR
    # from any terminal that auto-links URLs. The URL append is
    # gated on OWNER_REPO being resolvable; when it is not, the
    # reference falls back to the bare "PR #N" form.
    if [ -n "${PR_NUM:-}" ]; then
      PR_LINE="PR #${PR_NUM}"
      if [ -n "${OWNER_REPO:-}" ]; then
        PR_LINE="${PR_LINE} https://github.com/${OWNER_REPO}/pull/${PR_NUM}"
      fi
      NEW_BODY="${PR_LINE}

${NEW_BODY}"
    fi

    MSG_FILE=$(mktemp)
    { printf '%s\n\n' "$NEW_SUBJECT"; printf '%s\n' "$NEW_BODY"; } > "$MSG_FILE"
    # When this script runs from the post-merge hook, git has just created
    # the merge commit but has not yet removed MERGE_HEAD / MERGE_MSG /
    # MERGE_MODE / AUTO_MERGE. The lingering state makes git commit --amend
    # refuse with "You are in the middle of a merge -- cannot amend." The
    # merge IS complete (HEAD already points at the merge commit), so the
    # state files are stale metadata; remove them before the amend.
    GIT_DIR=$(git rev-parse --git-dir)
    rm -f "$GIT_DIR/MERGE_HEAD" "$GIT_DIR/MERGE_MSG" "$GIT_DIR/MERGE_MODE" "$GIT_DIR/AUTO_MERGE" 2>/dev/null || true
    GIT_AUTHOR_NAME="$ORIG_AUTHOR_NAME" GIT_AUTHOR_EMAIL="$ORIG_AUTHOR_EMAIL" \
    GIT_AUTHOR_DATE="$ORIG_AUTHOR_DATE" GIT_COMMITTER_DATE="$ORIG_COMMITTER_DATE" \
      git commit --amend -F "$MSG_FILE"
    rm -f "$MSG_FILE"
    NEW_HEAD=$(git rev-parse HEAD)
    echo "→ amended merge: $OLD_HEAD -> $NEW_HEAD"

    # Force-push dev with explicit lease against origin/dev's current SHA
    # (which may equal OLD_HEAD when the CI workflow drives this, or the
    # pre-merge dev tip when a local post-merge hook drives it). Skip the
    # push when origin/dev does not exist (off-grid scratch repos, no
    # remote tracking ref yet) — the local amend stands on its own.
    if ORIGIN_DEV_SHA=$(git rev-parse --verify --quiet origin/dev 2>/dev/null); then
      git push --force-with-lease="refs/heads/dev:$ORIGIN_DEV_SHA" origin "HEAD:refs/heads/dev" || {
        echo "X force-push of amended dev rejected; aborting before tag to avoid orphaning the tag" >&2
        exit 1
      }
    else
      echo "→ origin/dev not present; skipping force-push of amended dev (local-only repo)"
    fi
  fi
else
  echo "  · MERGED_POOL not detected from HEAD subject; skipping amend (cannot derive spec subject without source ref)"
fi

echo "→ tagging $NEXT on $(git rev-parse HEAD)"
git tag -a "$NEXT" -m "dev tag $NEXT (internal)"
git push -q origin "$NEXT"

echo "✓ claimed $NEXT"

# Archive the merged pool/* branch to vault/<same-suffix>. See
# archive-pool-branch.sh for behavior. Skip silently if the merge subject
# didn't carry a recognizable pool/* reference; the user can rerun
# manually in that case.
if [ -n "$MERGED_POOL" ] && [ -x "$SCRIPT_DIR/archive-pool-branch.sh" ]; then
  echo "→ archiving $MERGED_POOL (vault path resolved by archive-pool-branch.sh: prefixed when bin/version --seal returns vN.N.N, flat otherwise)"
  "$SCRIPT_DIR/archive-pool-branch.sh" "$MERGED_POOL" || \
    echo "  ⚠ archive failed; $MERGED_POOL left as-is on origin (rerun archive-pool-branch.sh manually)"
elif [ -n "$MERGED_POOL" ]; then
  echo "  · archive-pool-branch.sh not present in this template revision; skipping auto-archive"
fi

# Sync every active pool/* branch + its open PR title to the new tag.
# Best-effort: failures don't roll back the claim.
if [ -x "$SCRIPT_DIR/auto-rebase-pools-after-dev-merge.sh" ]; then
  "$SCRIPT_DIR/auto-rebase-pools-after-dev-merge.sh" || \
    echo "  ⚠ auto-rebase pass returned non-zero; the claim is still in place"
fi
