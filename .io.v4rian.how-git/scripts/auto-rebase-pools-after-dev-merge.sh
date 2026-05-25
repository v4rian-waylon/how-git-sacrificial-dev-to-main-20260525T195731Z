#!/usr/bin/env bash
# auto-rebase-pools-after-dev-merge.sh: produce a reconcile candidate for
# every active pool/* PR after a successful dev merge claim. The script
# NEVER mutates a developer's pool branch and NEVER closes or opens any
# PR. The developer is sovereign in their pool/* sandbox; only the admin
# decides what lands on dev via review.
#
# Triggered from claim-dev-merge.sh after the post-claim tag + push.
# For each open PR whose head branch matches the pool/* shape:
#
#   1. Update the PR title's aspirational version prefix to the version
#      it would actually claim if merged next. This is a metadata edit
#      only - it does not touch the pool branch or the PR's open state.
#   2. Cut `pool/nN.reconcile.<short>` off the new dev tip (same nN as
#      the original pool, kind=reconcile, short=original short). If the
#      same name already exists from a prior reconcile pass, append a
#      -N suffix so the iterative chain stays traceable.
#   3. Cherry-pick the pool branch's commits (OLD_BASE..OLD_TIP) onto
#      the reconcile branch one at a time. On any cherry-pick conflict,
#      escalate through the L1-L5 ladder via claude_skill_run to attempt
#      smart resolution. The original pool branch is read-only here.
#   4. All commits cherry-picked successfully (clean or with claude help):
#        a. Push the reconcile branch as a CREATE (no force-push). CI
#           fires on the new ref normally - no PAT needed because the
#           anti-recursion suppression only applies to UPDATE events.
#        b. Comment on the existing PR with the recap directed at the
#           admin: dev advanced to <sha>, reconcile candidate is
#           `pool/nN.reconcile.<short>`, conflicts resolved as follows.
#        c. Do NOT close the original PR. Do NOT open a new PR. Do NOT
#           push to the original pool branch. The reconcile branch is
#           a candidate the admin can merge into dev; the original PR
#           is the developer's record.
#   5. Some commits unresolvable after L5: push the partial reconcile
#      state for review, comment on the original PR with the unresolved
#      file list plus the full L1-L5 attempt log. The PR stays open;
#      the developer or admin picks up from the partial state.
#   6. Iterative: if dev advances again before either party acts, the
#      next auto-rebase pass creates pool/nN.reconcile.<short>-2,
#      then -3, etc. Each reconcile attempt leaves its own branch as
#      a receipt.
#
# The dev's window of action is organic, not turn-taking: they own the
# pool branch and can push their own resolution at any time. If they
# push a clean state before the admin reviews, the reconcile candidate
# is moot and stays as a receipt only. If the admin reviews first and
# acts on the reconcile, a slow dev's in-progress work becomes wasted
# time. The system gives no protection for slowness; admin's review is
# the gate (see feedback_how_git_never_rewrites_history).
#
# Network-bound: requires gh CLI for PR enumeration + edit + create +
# comment. Skipped silently in LIFECYCLE_TEST_MODE so offline e2e
# doesn't reach GitHub.
#
# Usage:
#   auto-rebase-pools-after-dev-merge.sh                do the rebase pass
#   auto-rebase-pools-after-dev-merge.sh --dry-run      show what would change
#   auto-rebase-pools-after-dev-merge.sh -h | --help    print this help

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  echo "X auto-rebase-pools-after-dev-merge.sh: not inside a git repo" >&2
  exit 2
fi

# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=true; shift ;;
    -h|--help)  sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "X unknown flag: $1" >&2; exit 2 ;;
  esac
done

cd "$REPO_ROOT"

if [ "${LIFECYCLE_TEST_MODE:-}" = "1" ]; then
  echo "  . [test-mode] auto-rebase-pools-after-dev-merge skipped (would have iterated open PRs)" >&2
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "  . gh CLI not installed; skipping auto-rebase pass (install gh to enable)" >&2
  exit 0
fi

# Aspirational version derivation from latest reachable tag this year.
# (Tags-as-seal model: VERSION isn't tracked. Falls back to the legacy
# VERSION file content if present, for repos pre-redesign that haven't
# adopted the new model yet.)
NOW_YEAR=$(date -u +%Y)
LATEST_TAG=$(git describe --tags --match "v${NOW_YEAR}.*" --abbrev=0 HEAD 2>/dev/null || true)
ASPIRATIONAL=""
if [ -n "$LATEST_TAG" ]; then
  case "$LATEST_TAG" in
    v[0-9]*.[0-9]*.[0-9]*)
      _main=$(echo "$LATEST_TAG" | awk -F. '{print $2}')
      _dev=$(echo "$LATEST_TAG" | awk -F. '{print $3}')
      ASPIRATIONAL="v${NOW_YEAR}.${_main}.$((_dev + 1))"
      ;;
    v[0-9]*.[0-9]*)
      _main=$(echo "$LATEST_TAG" | awk -F. '{print $2}')
      ASPIRATIONAL="v${NOW_YEAR}.$((_main + 1)).1"
      ;;
  esac
elif [ -f VERSION ]; then
  ASPIRATIONAL=$(cat VERSION)
fi

echo "-> auto-rebase pass: dev tip $(git rev-parse --short HEAD)${ASPIRATIONAL:+ aspirational $ASPIRATIONAL}"

REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null || true)
OWNER_REPO=$(echo "$REMOTE_URL" | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
if [ -z "$OWNER_REPO" ]; then
  echo "  . could not derive owner/repo from origin URL; skipping" >&2
  exit 0
fi

# Pool branch shape regex - includes `reconcile` as the 5th legal kind
# so reconcile branches themselves get rebased on subsequent dev merges
# (the iterative chain case in the docstring). Accepts both the legacy
# flat layout (pool/nN.kind.short) and the prefixed layout
# (pool/vYYYY.MAIN/nN.kind.short) so reconcile branches land under the
# same release-line classification as the original allocation.
POOL_PATTERN='^pool/(v[0-9]{4}\.[0-9]+/)?n[0-9]+\.(feature|fix|r&d|refactor|reconcile|doc)\.(sprint[0-9]+-)?([A-Z]+-[0-9]+-)?[a-z0-9][a-z0-9-]*$'

short_name_of() {
  # Strip "pool/[vYYYY.MAIN/]nN.<kind>." prefix to get the trailing
  # short-name. The optional major-prefix segment is consumed first so
  # both layouts collapse to the same short name.
  echo "$1" | sed -E 's|^pool/(v[0-9]+\.[0-9]+/)?n[0-9]+\.[a-z&]+\.||'
}

n_of() {
  # Extract the nN counter, ignoring the optional major-prefix segment.
  echo "$1" | sed -E 's|^pool/(v[0-9]+\.[0-9]+/)?(n[0-9]+)\..*|\2|'
}

major_prefix_of() {
  # Return the vYYYY.MAIN segment when the branch carries one; empty
  # string when on the legacy flat layout. Used so the reconcile branch
  # inherits the original allocation's release-line classification.
  echo "$1" | sed -nE 's|^pool/(v[0-9]+\.[0-9]+)/n[0-9]+\..*|\1|p'
}

PRS_JSON=$(gh pr list --repo "$OWNER_REPO" --state open --base dev \
  --json number,title,headRefName 2>/dev/null || echo "[]")
if [ "$PRS_JSON" = "[]" ] || [ -z "$PRS_JSON" ]; then
  echo "  . no open PRs targeting dev; nothing to rebase"
  exit 0
fi

echo "$PRS_JSON" | python3 -c 'import json,sys
for pr in json.load(sys.stdin):
    print("%s\t%s\t%s" % (pr["number"], pr["headRefName"], pr["title"]))' \
  | while IFS=$'\t' read -r NUM HEAD TITLE; do
      echo
      echo "-- PR #$NUM head=$HEAD --"
      if ! [[ "$HEAD" =~ $POOL_PATTERN ]]; then
        echo "  . head does not match pool/* shape (kinds: feature|fix|r&d|refactor|reconcile|doc); skipping" >&2
        continue
      fi

      # Title aspirational-version update.
      if [ -n "$ASPIRATIONAL" ]; then
        NEW_TITLE=$(printf '%s' "$TITLE" | sed -E "s/v[0-9]{4}\.[0-9]+\.[0-9]+(-b\.[0-9]+)?/$ASPIRATIONAL/")
        if [ "$NEW_TITLE" != "$TITLE" ]; then
          echo "  -> updating title aspirational version -> $ASPIRATIONAL"
          if $DRY_RUN; then
            echo "    [dry-run] would: gh pr edit $NUM --title '$NEW_TITLE'"
          else
            gh pr edit "$NUM" --repo "$OWNER_REPO" --title "$NEW_TITLE" >/dev/null \
              || echo "    warn: title edit failed; continuing"
          fi
        fi
      fi

      # Fetch the pool branch + sync dev locally
      if ! git fetch -q origin "$HEAD:refs/remotes/origin/$HEAD" 2>/dev/null; then
        echo "  . could not fetch $HEAD; skipping" >&2
        continue
      fi
      git fetch -q origin dev 2>/dev/null || true

      OLD_TIP=$(git rev-parse "origin/$HEAD")
      OLD_BASE=$(git rev-parse "origin/$HEAD~1" 2>/dev/null || echo "")
      DEV_TIP=$(git rev-parse origin/dev)

      # Orphan-base detection is informational only now. The cherry-pick
      # path cherry-picks OLD_BASE..OLD_TIP from the pool's own history
      # onto the new dev tip, so it works whether OLD_BASE is in dev's
      # history or was orphaned by a dev rewrite. Log when the orphan
      # case happens so the dev/admin sees why the reconcile branch
      # only carries the pool's delta and not the orphaned ancestors.
      if [ -n "$OLD_BASE" ] && ! git merge-base --is-ancestor "$OLD_BASE" "$DEV_TIP" 2>/dev/null; then
        echo "  . old base $OLD_BASE is NOT in current dev's history -> orphan-base; reconcile cherry-picks only the pool's delta"
      fi

      # No in-place rebase + force-push path: that would rewrite the
      # developer's pool branch, which violates the no-rewrite principle
      # (see feedback_how_git_never_rewrites_history). The cherry-pick
      # onto a fresh reconcile branch is the only path, regardless of
      # whether the rebase would have been clean or conflicted.
      #
      # If OLD_BASE is empty (single-commit pool branch) we still want a
      # well-defined cherry-pick range; fall back to merge-base of dev
      # and the pool tip so we capture exactly the pool's delta.
      if [ -z "$OLD_BASE" ]; then
        OLD_BASE=$(git merge-base "$DEV_TIP" "origin/$HEAD" 2>/dev/null || echo "")
      fi
      if [ -z "$OLD_BASE" ]; then
        echo "  warn: cannot compute OLD_BASE for $HEAD; leaving reconcile to manual review" >&2
        gh pr comment "$NUM" --repo "$OWNER_REPO" \
          --body "Auto-rebase against new dev tip $(git rev-parse --short "$DEV_TIP") could not determine the merge-base for this PR. Reconcile branch was not created. Manual rebase required." \
          >/dev/null 2>&1 || true
        continue
      fi

      # If the pool tip is already an ancestor of the new dev tip, this
      # pool's work is already in dev; nothing to reconcile.
      if git merge-base --is-ancestor "$OLD_TIP" "$DEV_TIP" 2>/dev/null; then
        echo "  . pool tip already in dev history; no reconcile needed"
        continue
      fi

      # Compute reconcile branch name (same nN, kind=reconcile, short=original
      # short). When the original head carried a vYYYY.MAIN/ prefix the
      # reconcile branch inherits the same prefix so the release-line
      # classification stays consistent across the iterative reconcile chain.
      ORIG_SHORT=$(short_name_of "$HEAD")
      ORIG_N=$(n_of "$HEAD")
      ORIG_MAJOR=$(major_prefix_of "$HEAD")
      if [ -n "$ORIG_MAJOR" ]; then
        RECON_BRANCH="pool/${ORIG_MAJOR}/${ORIG_N}.reconcile.${ORIG_SHORT}"
      else
        RECON_BRANCH="pool/${ORIG_N}.reconcile.${ORIG_SHORT}"
      fi

      # Iterative-chain support: if a reconcile branch with this exact name
      # already exists on origin, append a -N suffix to keep names traceable.
      if git ls-remote --heads origin "$RECON_BRANCH" 2>/dev/null | grep -q "$RECON_BRANCH"; then
        ITER=2
        while git ls-remote --heads origin "${RECON_BRANCH}-${ITER}" 2>/dev/null | grep -q "${RECON_BRANCH}-${ITER}"; do
          ITER=$((ITER + 1))
        done
        RECON_BRANCH="${RECON_BRANCH}-${ITER}"
      fi
      echo "  -> cutting reconcile branch: $RECON_BRANCH"

      if $DRY_RUN; then
        echo "    [dry-run] would: cherry-pick $OLD_BASE..$OLD_TIP onto $DEV_TIP, push $RECON_BRANCH (CREATE), comment on PR #$NUM"
        continue
      fi

      # Fresh worktree off the new dev tip; the reconcile branch is created
      # by the worktree add (-b) and only the cherry-picked commits go on it.
      WORKTREE=$(mktemp -d -t "v4rian-reconcile-${NUM}-XXXXXX")
      if ! git worktree add -q -b "$RECON_BRANCH" "$WORKTREE" "$DEV_TIP" 2>/dev/null; then
        echo "  warn: could not create reconcile worktree; leaving reconcile to manual review" >&2
        rm -rf "$WORKTREE"
        gh pr comment "$NUM" --repo "$OWNER_REPO" \
          --body "Auto-rebase against new dev tip $(git rev-parse --short "$DEV_TIP") could not create the reconcile worktree. Manual rebase required." \
          >/dev/null 2>&1 || true
        continue
      fi

      pushd "$WORKTREE" >/dev/null

      # Fetch the active-requirement for this pool branch so the L1-L5
      # ladder can include it in every claude prompt. The requirement
      # is the canonical intent the allocator stamped onto the branch
      # at creation time (initial [REQ] commit body + tracked file at
      # .io.v4rian.how-git/active-requirement). Older branches that
      # predate this lifecycle step return an empty string; the ladder
      # gracefully proceeds without the extra context.
      ACTIVE_REQUIREMENT=""
      if [ -x "$REPO_ROOT/.io.v4rian.how-git/scripts/get-active-requirement.sh" ]; then
        ACTIVE_REQUIREMENT=$(bash "$REPO_ROOT/.io.v4rian.how-git/scripts/get-active-requirement.sh" "origin/$HEAD" 2>/dev/null || true)
      fi
      REQ_HEADER=""
      if [ -n "$ACTIVE_REQUIREMENT" ]; then
        REQ_HEADER="Active requirement for $HEAD (from initial [REQ] commit + .io.v4rian.how-git/active-requirement file; this is the canonical intent for the branch): ${ACTIVE_REQUIREMENT}. "
      fi

      # Cherry-pick each commit from OLD_BASE..OLD_TIP onto the new dev tip
      # one at a time. On conflict, iterate through escalating resolution
      # strategies until cleared or genuinely exhausted. The user's rule is
      # "no excuses, keeps going until resolved" - so we burn every reasonable
      # strategy before signaling human intervention.
      #
      # Escalation ladder per conflicting commit:
      #   L1. claude git-strategy-audit with conflict file list + commit msg
      #   L2. claude with broader context: full pool diff + dev diff + the
      #       conflicting hunks' content from both sides
      #   L3. retry with -X theirs (favor incoming = pool's intent); claude
      #       reviews the result for sanity, can refine
      #   L4. retry with -X ours (favor target = dev's intent); claude reviews
      #   L5. ask claude to PRODUCE a rewritten commit message + manual diff
      #       guidance; apply the guidance, finalize
      # After L5, if still unresolved, push partial state + comment with full
      # attempt log. That comment is the receipt of every strategy tried.
      COMMITS=$(git -C "$REPO_ROOT" rev-list --reverse "$OLD_BASE..$OLD_TIP")
      CONFLICT_RECAP=""
      ALL_CLEAN=true

      attempt_resolve() {
        # $1 = level (1..5), $2 = commit SHA, $3 = original msg, $4 = conflicting files
        local level="$1" c="$2" ORIG_MSG="$3" CONFLICTS="$4"
        local ctx=""
        case "$level" in
          1) ctx="${REQ_HEADER}L1: reconcile of $HEAD against dev tip $(git -C "$REPO_ROOT" rev-parse --short "$DEV_TIP"): cherry-picking $c ($ORIG_MSG); conflicting files: $CONFLICTS. Resolve the conflict markers in those files to land the intent of the cherry-picked commit on top of dev." ;;
          2) ctx="${REQ_HEADER}L2 (L1 failed): same reconcile. Broader context follows. Pool branch full diff against its old base: $(git -C "$REPO_ROOT" diff --stat "$OLD_BASE..$OLD_TIP" | head -30 | tr '\n' '|'). Dev's changes since same base: $(git -C "$REPO_ROOT" diff --stat "$OLD_BASE..$DEV_TIP" | head -30 | tr '\n' '|'). Resolve the markers preserving pool's intent while accommodating dev's progress." ;;
          3) ctx="${REQ_HEADER}L3 (L1+L2 failed): retry the cherry-pick with -X theirs (favor incoming/pool). Claude: verify the result is semantically correct AND aligns with the latest spec on dev. If not, refine in-place." ;;
          4) ctx="${REQ_HEADER}L4 (L1-L3 failed): retry with -X ours (favor target/dev). Claude: verify result preserves pool's intent. If pool's intent is fully lost, this strategy is wrong - signal back." ;;
          5) ctx="${REQ_HEADER}L5 (L1-L4 failed): final attempt. Produce a hand-crafted resolution: for each conflicting file in $CONFLICTS, decide which side wins on a hunk-by-hunk basis, or merge by combining both sides. The original commit message is: $ORIG_MSG. Apply the resolution to clear all markers." ;;
        esac

        # L3 / L4 require resetting state + retrying with a strategy flag
        if [ "$level" = "3" ] || [ "$level" = "4" ]; then
          git cherry-pick --abort >/dev/null 2>&1 || true
          local flag="theirs"
          [ "$level" = "4" ] && flag="ours"
          git cherry-pick -X "$flag" "$c" >/dev/null 2>&1 || true
        fi

        if claude_skill_run git-strategy-audit "$ctx" && [ -z "$(git diff --name-only --diff-filter=U)" ]; then
          if git -c core.editor=true cherry-pick --continue >/dev/null 2>&1; then
            return 0
          fi
        fi
        return 1
      }

      for c in $COMMITS; do
        if git cherry-pick "$c" >/tmp/.reconcile-cherrypick-$NUM.log 2>&1; then
          continue
        fi
        # Conflict on this commit - escalate through strategies
        CONFLICTS=$(git diff --name-only --diff-filter=U | tr '\n' ' ')
        ORIG_MSG=$(git -C "$REPO_ROOT" log -1 --format='%s' "$c")
        echo "  . conflict on cherry-pick of $c ($ORIG_MSG): $CONFLICTS"
        ATTEMPTS=""
        RESOLVED=false
        for level in 1 2 3 4 5; do
          echo "    -> L${level} attempt"
          if attempt_resolve "$level" "$c" "$ORIG_MSG" "$CONFLICTS"; then
            ATTEMPTS="${ATTEMPTS}L${level}(resolved) "
            CONFLICT_RECAP="$CONFLICT_RECAP\n- $c \"$ORIG_MSG\": conflicts in $CONFLICTS resolved at L${level} ($ATTEMPTS)"
            RESOLVED=true
            break
          fi
          ATTEMPTS="${ATTEMPTS}L${level}(failed) "
        done

        if ! $RESOLVED; then
          CONFLICT_RECAP="$CONFLICT_RECAP\n- $c \"$ORIG_MSG\": UNRESOLVED after 5 strategies. Files: $CONFLICTS. Attempts: $ATTEMPTS"
          git cherry-pick --abort >/dev/null 2>&1 || true
          ALL_CLEAN=false
          break
        fi
      done

      DEV_SHORT=$(git -C "$REPO_ROOT" rev-parse --short "$DEV_TIP")
      if $ALL_CLEAN; then
        # All commits cherry-picked successfully (clean or via L1-L5 claude
        # resolution). Push the reconcile branch as a CREATE - CI fires on
        # the new ref normally since anti-recursion only suppresses UPDATE
        # events on existing refs. No PAT needed.
        git push --no-verify origin "$RECON_BRANCH:refs/heads/$RECON_BRANCH" >/dev/null 2>&1 \
          && echo "  ok: reconcile branch $RECON_BRANCH pushed (CREATE)"

        # Comment on the EXISTING PR with the recap. Admin is the sole
        # merge decider on dev (see feedback_how_git_never_rewrites_history);
        # the comment is admin-directed and dev-informational.
        # NEVER close the original PR. NEVER open a new PR. NEVER push to
        # the original pool branch. The reconcile branch is a candidate;
        # the admin reviews and decides via review.
        if [ -n "$CONFLICT_RECAP" ]; then
          RECAP_BODY="### Resolutions recap${CONFLICT_RECAP}"
        else
          RECAP_BODY="_No conflicts during cherry-pick onto new dev tip; pure replay of pool commits._"
        fi
        COMMENT_BODY=$(printf 'Auto-rebase: dev advanced to **%s** under this PR.\n\nThe reconcile branch [`%s`](../tree/%s) carries the pool commits cherry-picked onto the new dev tip. The original `%s` branch and this PR are untouched (receipts).\n\n**Admin** decides via review:\n- merge the reconcile candidate locally with `git checkout dev && git merge --no-ff %s -m "[MERGE] %s into dev: <version>"` and push; `claim-on-merge-dev` handles the close-up.\n- tag the developer in a comment asking for changes.\n- close this PR to reject; reconcile branch stays as a receipt.\n\n**Developer** owns the pool branch and may push their own resolution at any time; if a clean update lands before admin review the reconcile is moot and stays only as a receipt.\n\n%s\n' "$DEV_SHORT" "$RECON_BRANCH" "$RECON_BRANCH" "$HEAD" "$RECON_BRANCH" "$RECON_BRANCH" "$RECAP_BODY")
        gh pr comment "$NUM" --repo "$OWNER_REPO" --body "$COMMENT_BODY" >/dev/null 2>&1 \
          && echo "  ok: commented on PR #$NUM with reconcile candidate"
      else
        # Some commits unresolvable after L5. Push the partial reconcile so
        # the work-so-far is preserved as a receipt. Comment on the PR with
        # the unresolved file list + full L1-L5 attempt log. The PR stays
        # open; dev or admin picks up from the partial state.
        git push --no-verify origin "$RECON_BRANCH:refs/heads/$RECON_BRANCH" >/dev/null 2>&1 \
          && echo "  ok: partial reconcile $RECON_BRANCH pushed (CREATE)"
        COMMENT_BODY=$(printf 'Auto-rebase: dev advanced to **%s** under this PR.\n\nReconcile against the new dev tip hit conflicts that the L1-L5 ladder could not resolve. The partial reconcile state is pushed to [`%s`](../tree/%s) as a receipt of what was attempted. The original `%s` branch and this PR are untouched.\n\n### Unresolved conflicts%b\n\n**Developer** can push a fresh resolution to the pool branch at any time. **Admin** can pick up from the partial reconcile branch directly or apply a different resolution; admin remains the sole merge decider on dev.\n' "$DEV_SHORT" "$RECON_BRANCH" "$RECON_BRANCH" "$HEAD" "$CONFLICT_RECAP")
        gh pr comment "$NUM" --repo "$OWNER_REPO" --body "$COMMENT_BODY" >/dev/null 2>&1 \
          && echo "  ok: commented on PR #$NUM with partial reconcile recap"
        echo "  warn: reconcile incomplete; partial state on $RECON_BRANCH"
      fi

      popd >/dev/null
      git worktree remove --force "$WORKTREE" 2>/dev/null || true
      rm -rf "$WORKTREE"
    done

echo
echo "ok: auto-rebase pass complete"
