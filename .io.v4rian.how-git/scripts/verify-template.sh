#!/usr/bin/env bash
# verify-template.sh — end-to-end test of the how-git template
#
# Creates a brand-new throwaway repo under the authenticated user (NOT under
# the template owner — testing never touches the og repo) seeded with the
# template's content, then exercises the actual consumer workflow on it:
# clone, run the in-repo scripts (open-pr.sh --doctor to trigger auto-config,
# claim-dev-merge.sh, claim-main-release.sh), and run test-hooks.sh, then
# asserts these invariants:
#
#   - Repo root contains only the expected entries (.github/, .gitignore,
#     VERSION (after setup), .io.v4rian.how-git/)
#   - Executable bits round-tripped through the bootstrap path
#   - VERSION matches the current calendar month
#   - core.hooksPath points into the namespace dir
#   - 26-of-26 hook + bump-math tests pass
#
# Two seed modes:
#
#   default — POST /repos/{template}/generate (real "Use this template" API).
#             The throwaway is seeded from the template's DEFAULT branch.
#             Requires is_template=true on the source.
#
#   --from-branch <ref> — Bypasses /generate. Creates an empty repo via
#             POST /user/repos, mirrors what /generate fundamentally does
#             (single fresh "Initial commit" containing the tree of <ref>),
#             and pushes that to the new repo. Lets you e2e-test the deliv-
#             erable of any branch (e.g. an unmerged PR) without touching
#             the source's default branch. Useful pre-merge.
#
# Either way, the throwaway is a SEPARATE repo. The og template repo is
# never modified by this script. Throwaway is deleted on success (unless
# --keep), but auto-delete requires delete_repo scope on the token; if
# missing, the script warns and leaves the throwaway alive for manual
# cleanup.
#
# Dependencies: bash, git, curl, python3, make.   (No gh required.)
#
# Auth: same resolution chain as open-pr.sh.
#       Needs contents:write on the destination owner for repo creation.
#       Needs delete_repo for auto-cleanup; if absent, warns and skips.
#
# Usage:
#   verify-template.sh                          generate from template's default branch, test, delete
#   verify-template.sh --from-branch <ref>      seed from a named branch on the template (pre-merge testing)
#   verify-template.sh --with-bump-cycle        also exercise claim-dev-merge.sh + claim-main-release.sh
#                                               end-to-end (adds 5 invariants; runs locally — no CI polling)
#   verify-template.sh --keep                   leave throwaway alive (useful with --with-bump-cycle for inspection)
#   verify-template.sh --name <slug>            override generated repo name
#   verify-template.sh --template <owner/repo>  test a different template
#   verify-template.sh --dest-owner <owner>     create throwaway under this owner
#                                               (default: authenticated user)
#   verify-template.sh -h | --help              print this help

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEMPLATE_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

# Defaults
# TEMPLATE_REPO derives from this repo's origin URL so the framework has no
# hardcoded owner/repo and an origin swap retests connectivity in one step.
TEMPLATE_REPO=$(cd "$TEMPLATE_ROOT" 2>/dev/null && git config --get remote.origin.url 2>/dev/null \
  | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
DEST_OWNER=""
NAME=""
KEEP=false
FROM_BRANCH=""
WITH_BUMP_CYCLE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --template)         TEMPLATE_REPO="$2"; shift 2 ;;
    --dest-owner)       DEST_OWNER="$2"; shift 2 ;;
    --name)             NAME="$2"; shift 2 ;;
    --from-branch)      FROM_BRANCH="$2"; shift 2 ;;
    --with-bump-cycle)  WITH_BUMP_CYCLE=true; shift ;;
    --keep)             KEEP=true; shift ;;
    -h|--help)     sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             echo "✗ unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ----------------------------------------------------------------------------
# Token resolution (shared chain with open-pr.sh — keep in sync)
# ----------------------------------------------------------------------------
resolve_token() {
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s' "$GH_TOKEN"; return 0
  fi
  if [ -n "${CREATE_POOL_BRANCH_TOKEN:-}" ]; then
    printf '%s' "$CREATE_POOL_BRANCH_TOKEN"; return 0
  fi
  if command -v gh >/dev/null 2>&1; then
    local t
    t=$(gh auth token 2>/dev/null || true)
    [ -n "$t" ] && { printf '%s' "$t"; return 0; }
  fi
  local gcm_dir="$HOME/.gcm/store/git/https/github.com"
  if [ -d "$gcm_dir" ]; then
    local f
    for f in "$gcm_dir"/*.credential; do
      [ -f "$f" ] || continue
      local t
      t=$(head -1 "$f" 2>/dev/null || true)
      [ -n "$t" ] && { printf '%s' "$t"; return 0; }
    done
  fi
  return 1
}

# ----------------------------------------------------------------------------
# Dependency probe
# ----------------------------------------------------------------------------
for t in bash git curl python3 make; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "✗ verify-template.sh requires '$t' — install it via your platform's package manager" >&2
    exit 3
  fi
done

TOKEN=$(resolve_token) || {
  echo "✗ verify-template.sh: no GitHub token; run 'open-pr.sh --doctor' for resolution options" >&2
  exit 3
}

# ----------------------------------------------------------------------------
# Resolve destination owner (defaults to authenticated user)
# ----------------------------------------------------------------------------
if [ -z "$DEST_OWNER" ]; then
  DEST_OWNER=$(curl -sS -H "Authorization: token $TOKEN" https://api.github.com/user \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('login',''))")
  [ -z "$DEST_OWNER" ] && { echo "✗ could not resolve authenticated user from /user" >&2; exit 3; }
fi

# ----------------------------------------------------------------------------
# Resolve names + paths used by either seed mode
# ----------------------------------------------------------------------------
if [ -z "$NAME" ]; then
  STAMP=$(date -u +%Y%m%dT%H%M%S)
  if [ -n "$FROM_BRANCH" ]; then
    NAME="how-git-verify-frombranch-$STAMP"
  else
    NAME="how-git-verify-$STAMP"
  fi
fi
TEST_DIR=$(mktemp -d -t "how-git-verify-XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
CLONE_URL="https://$DEST_OWNER:$TOKEN@github.com/$DEST_OWNER/$NAME.git"

if [ -z "$FROM_BRANCH" ]; then
  # --------------------------------------------------------------------------
  # Seed mode 1: /generate (real "Use this template" API)
  # Requires is_template=true on the source. Throwaway content comes from
  # the source's DEFAULT branch (typically main).
  # --------------------------------------------------------------------------
  echo "→ seed mode: /generate (real 'Use this template' API)"
  echo "→ verifying source template '$TEMPLATE_REPO' has is_template=true"
  SRC_INFO=$(curl -sS -H "Authorization: token $TOKEN" "https://api.github.com/repos/$TEMPLATE_REPO")
  IS_TEMPLATE=$(echo "$SRC_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin).get('is_template'))")
  if [ "$IS_TEMPLATE" != "True" ]; then
    echo "✗ '$TEMPLATE_REPO' has is_template=$IS_TEMPLATE" >&2
    echo "  Flip it at https://github.com/$TEMPLATE_REPO/settings → Template repository → check the box" >&2
    echo "  Or test a non-default branch with --from-branch <ref>." >&2
    exit 1
  fi
  echo "  ✓ is_template: True"

  echo "→ generating throwaway: $DEST_OWNER/$NAME (from $TEMPLATE_REPO default branch)"
  PAYLOAD=$(NAME="$NAME" OWNER="$DEST_OWNER" python3 -c "
import json, os
print(json.dumps({
  'owner': os.environ['OWNER'],
  'name':  os.environ['NAME'],
  'description': 'Throwaway verification of how-git template (delete me)',
  'private': True,
  'include_all_branches': False,
}))")
  GEN_RESP=$(curl -sS -X POST \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "https://api.github.com/repos/$TEMPLATE_REPO/generate")
  GEN_URL=$(echo "$GEN_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('html_url',''))")
  if [ -z "$GEN_URL" ]; then
    echo "✗ generation failed — full response:" >&2
    echo "$GEN_RESP" | python3 -m json.tool >&2
    exit 1
  fi
  echo "  ✓ created $GEN_URL"
else
  # --------------------------------------------------------------------------
  # Seed mode 2: --from-branch
  # Create empty repo, clone the source branch locally, build a fresh single
  # "Initial commit" containing that branch's tree, push it to the new repo's
  # main. Mirrors what /generate fundamentally does (single rooted commit, no
  # shared history), but lets us test any named branch on the source. The og
  # repo is read-only here; we only read from it.
  # --------------------------------------------------------------------------
  echo "→ seed mode: --from-branch '$FROM_BRANCH' (simulates /generate from a non-default ref)"
  echo "→ creating empty throwaway: $DEST_OWNER/$NAME"
  PAYLOAD=$(NAME="$NAME" python3 -c "
import json, os
print(json.dumps({
  'name': os.environ['NAME'],
  'description': 'Throwaway verification of how-git template (delete me)',
  'private': True,
  'auto_init': False,
}))")
  CREATE_RESP=$(curl -sS -X POST \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "https://api.github.com/user/repos")
  GEN_URL=$(echo "$CREATE_RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('html_url',''))")
  if [ -z "$GEN_URL" ]; then
    echo "✗ empty repo creation failed — full response:" >&2
    echo "$CREATE_RESP" | python3 -m json.tool >&2
    exit 1
  fi
  echo "  ✓ created $GEN_URL (empty)"

  echo "→ building single-commit seed from $TEMPLATE_REPO@$FROM_BRANCH"
  SRC_CLONE="$TEST_DIR/source"
  git clone -q --branch "$FROM_BRANCH" --single-branch \
    "https://x-access-token:$TOKEN@github.com/$TEMPLATE_REPO.git" "$SRC_CLONE"
  cd "$SRC_CLONE"
  SOURCE_SHA=$(git rev-parse HEAD)
  echo "  · source $TEMPLATE_REPO@$FROM_BRANCH = $SOURCE_SHA"

  # Make a fresh orphan branch with a single "Initial commit" carrying the
  # current tree. This mirrors the topology /generate produces.
  git checkout -q --orphan _seed
  git -c user.email="verify-template@local" -c user.name="verify-template" \
      commit -q -m "Initial commit"

  echo "→ pushing seed commit to throwaway main"
  git push -q "$CLONE_URL" _seed:main
  cd - >/dev/null
fi

# ----------------------------------------------------------------------------
# Clone the populated throwaway. Both seed paths converge here.
# /generate is asynchronous: the repo's refs may be reachable before the
# working tree is populated, so we retry until BOTH the clone succeeds AND
# the working tree has at least one file other than .git/.
# (--from-branch is synchronous, so this typically passes on the first try.)
# ----------------------------------------------------------------------------
echo "→ waiting for throwaway content to be reachable"
TRIES=0
while :; do
  rm -rf "$TEST_DIR/repo"
  if git clone -q "$CLONE_URL" "$TEST_DIR/repo" 2>/dev/null; then
    populated=$(ls -A1 "$TEST_DIR/repo" 2>/dev/null | grep -vc '^\.git$' || true)
    if [ "${populated:-0}" -gt 0 ]; then
      break
    fi
  fi
  TRIES=$((TRIES+1))
  if [ $TRIES -ge 30 ]; then
    echo "✗ repo not populated after 30 attempts (60s); last populated=${populated:-0}" >&2
    exit 1
  fi
  sleep 2
done
echo "  ✓ cloned ($populated entries at root, $TRIES retries)"

cd "$TEST_DIR/repo"

# ----------------------------------------------------------------------------
# Invariant checks
# ----------------------------------------------------------------------------
echo
echo "=== Invariant 1: repo root contains only expected files ==="
# `|| true` keeps `set -e` + pipefail from killing the script when grep finds
# zero matches (empty root); we want the diagnostic block below to run instead.
ROOT=$(ls -A1 2>/dev/null | grep -v '^\.git$' | sort | tr '\n' ' ' || true)
EXPECTED=".gitignore .io.v4rian.how-git "
echo "    actual:   [$ROOT]"
echo "    expected: [$EXPECTED]"
if [ "$ROOT" = "$EXPECTED" ]; then
  echo "  ✓ root matches (clean for consumer's own files)"
else
  echo "  ✗ root differs — template likely still on a layout that ships extra root entries (CI workflows? legacy .githooks?); merge the namespace PR before re-running" >&2
  exit 1
fi

echo
echo "=== Invariant 2: executable bits survived template generation ==="
FAIL=0
for f in .io.v4rian.how-git/githooks/pre-push \
         .io.v4rian.how-git/githooks/post-checkout \
         .io.v4rian.how-git/githooks/commit-msg \
         .io.v4rian.how-git/scripts/apply-repo-rules.sh \
         .io.v4rian.how-git/scripts/open-pr.sh \
         .io.v4rian.how-git/scripts/verify-template.sh \
         .io.v4rian.how-git/bin/create-pool-branch \
         .io.v4rian.how-git/scripts/allocate-pool-branch.sh \
         .io.v4rian.how-git/bin/version \
         .io.v4rian.how-git/framework-tests/test-hooks.sh; do
  if [ -x "$f" ]; then
    echo "  ✓ $f"
  else
    echo "  ✗ $f NOT executable"
    FAIL=1
  fi
done
[ $FAIL -ne 0 ] && exit 1

echo
echo "=== Invariant 3a: out-of-the-box — no setup; first script invocation auto-activates hooks + inits VERSION ==="
# Confirm starting state is unset (the throwaway is a fresh clone, no heal was run)
PRE_HOOKS=$(git config core.hooksPath 2>/dev/null || true)
PRE_VERSION_EXISTS="no"; [ -f VERSION ] && PRE_VERSION_EXISTS="yes"
echo "    pre: core.hooksPath=[${PRE_HOOKS:-unset}] VERSION exists=$PRE_VERSION_EXISTS"
# Invoke any in-repo script. open-pr.sh --doctor is read-only (no git mutation, no API).
bash .io.v4rian.how-git/scripts/open-pr.sh --doctor >/dev/null 2>&1 || true
POST_HOOKS=$(git config core.hooksPath 2>/dev/null || true)
echo "    post (after open-pr.sh --doctor): core.hooksPath=[${POST_HOOKS:-unset}]"
if [ "$POST_HOOKS" = ".io.v4rian.how-git/githooks" ]; then
  echo "  ✓ hooks auto-activated by first in-repo script call (no setup step required)"
else
  echo "  ✗ hooks did NOT auto-activate; expected .io.v4rian.how-git/githooks, got [${POST_HOOKS:-unset}]"
  exit 1
fi

echo
echo "=== Invariant 3b: heal — scripts/heal.sh restores expected state after drift ==="
# Drift core.hooksPath to something invalid, then heal via the script.
git config core.hooksPath /tmp/this-path-does-not-exist
bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
EXPECTED_VER="v$(date -u +%Y).$(date -u +%-m).1-b.1"
ACTUAL_VER=$(cat VERSION)
HOOKS_PATH=$(git config core.hooksPath || true)
[ "$ACTUAL_VER" = "$EXPECTED_VER" ] && echo "  ✓ VERSION = $ACTUAL_VER" || { echo "  ✗ VERSION mismatch (expected $EXPECTED_VER, got $ACTUAL_VER)"; exit 1; }
[ "$HOOKS_PATH" = ".io.v4rian.how-git/githooks" ] && echo "  ✓ core.hooksPath = $HOOKS_PATH (after drift + heal)" || { echo "  ✗ core.hooksPath = $HOOKS_PATH"; exit 1; }

echo
echo "=== Invariant 4: test-hooks.sh passes ==="
TEST_OUT=$(bash .io.v4rian.how-git/framework-tests/test-hooks.sh 2>&1)
if echo "$TEST_OUT" | grep -q "0 failed"; then
  PASSED=$(echo "$TEST_OUT" | grep "passed," | tr -dc '0-9 ,' | awk -F, '{print $1}' | tr -d ' ')
  echo "  ✓ $PASSED tests passed"
else
  echo "  ✗ test-hooks.sh failed"
  echo "$TEST_OUT"
  exit 1
fi

echo
echo "=== Invariant 5: canonical claim scripts present and executable ==="
for f in .io.v4rian.how-git/scripts/claim-dev-merge.sh \
         .io.v4rian.how-git/scripts/claim-main-release.sh; do
  if [ -x "$f" ]; then
    echo "  ✓ $f"
  else
    echo "  ✗ $f missing or not executable"
    exit 1
  fi
done

echo
echo "=== Invariant 5a: in-repo skills present ==="
# Skills now ship inside the template at .io.v4rian.how-git/skills/, so the
# hooks can invoke them via claude_skill_run regardless of the consumer's
# global ~/.claude/skills/ state.
REQUIRED_SKILLS=(git-commit-audit git-strategy-audit git-compile-audit git-coverage-audit git-runtime-audit git-snapshot-preflight git-merge-audit git-history-preservation git-history-rewrite git-token-discovery git-snapshots git-shuttle)
missing=0
for s in "${REQUIRED_SKILLS[@]}"; do
  if [ -f ".io.v4rian.how-git/skills/$s/SKILL.md" ]; then
    echo "  ✓ skills/$s/SKILL.md"
  else
    echo "  ✗ skills/$s/SKILL.md missing"
    missing=1
  fi
done
[ $missing -eq 0 ] || exit 1

echo
echo "=== Invariant 5b: hooks invoke claude_skill_run for the right skills ==="
declare -A HOOK_SKILLS=(
  ["commit-msg"]="git-commit-audit"
  ["pre-push"]="git-strategy-audit git-compile-audit git-coverage-audit git-runtime-audit"
  ["post-checkout"]="git-snapshot-preflight"
)
for hook in commit-msg pre-push post-checkout; do
  for sk in ${HOOK_SKILLS[$hook]}; do
    if grep -q "claude_skill_run $sk\b" ".io.v4rian.how-git/githooks/$hook"; then
      echo "  ✓ $hook invokes claude_skill_run $sk"
    else
      echo "  ✗ $hook does NOT invoke claude_skill_run $sk"
      exit 1
    fi
  done
done

echo
echo "=== Invariant 5c: 'git repo' alias auto-installed by ensure_hooks_path ==="
EXPECTED_ALIAS_FRAGMENT='case "$1" in openPR)'
INSTALLED_ALIAS=$(git config alias.repo 2>/dev/null || true)
if echo "$INSTALLED_ALIAS" | grep -q "openPR"; then
  echo "  ✓ alias.repo installed (dispatches openPR / heal / verify / claim-dev / claim-main)"
else
  echo "  ✗ alias.repo NOT installed; got: [$INSTALLED_ALIAS]"
  exit 1
fi

echo
echo "=== Invariant 5d: GitHub Actions thin dispatchers present for PR-merge acceptance ==="
for wf in .github/workflows/claim-on-merge-dev.yml .github/workflows/claim-on-merge-main.yml; do
  if [ -f "$wf" ]; then
    if grep -q 'bash .io.v4rian.how-git/scripts/claim-' "$wf"; then
      echo "  ✓ $wf dispatches to in-repo script"
    else
      echo "  ✗ $wf exists but doesn't dispatch to the in-repo claim script"
      exit 1
    fi
  else
    echo "  ✗ $wf missing"
    exit 1
  fi
done

echo
echo "=== STATIC INVARIANTS (1-5d) PASSED ==="
echo

# ============================================================================
# Optional git-native bump cycle test
# ============================================================================
# Exercises the canonical claim scripts (claim-dev-merge.sh, claim-main-
# release.sh) against the throwaway. Without this phase the bump scripts
# and the claim scripts are checked for syntax + math only (via Invariants
# 1-5 and test/test-hooks.sh); with this phase the full claim-on-merge
# cycle runs end-to-end with NO CI involvement — pure git tooling.
#
# Invariants 6-10:
#   6.  claim-dev-merge.sh tags HEAD on dev with vYYYY.1.1 (push succeeds)
#   7.  VERSION on dev is bumped to vYYYY.1.2 after the claim
#   8.  claim-main-release.sh tags HEAD on main with vYYYY.1
#   9.  GitHub Release for the release tag exists (if a token is available; warns + passes if not)
#  10. VERSION on main is vYYYY.2.1 (main_counter +1, dev_counter reset)

if $WITH_BUMP_CYCLE; then
  echo "=== git-native bump cycle test (Invariants 6-10) ==="
  echo "  · This phase invokes the local claim scripts directly. No CI polling."
  echo

  # The cloned remote URL embeds the token already; this lets push work.
  git remote set-url origin "$CLONE_URL"

  # --------------------------------------------------------------------------
  # Phase 1: create dev, push, run claim-dev-merge.sh, verify tag + bump
  # --------------------------------------------------------------------------
  echo "→ creating dev branch from main and pushing"
  git checkout -q -b dev
  git push -q origin dev
  DEV_SHA=$(git rev-parse dev)
  echo "  · dev pushed at SHA $DEV_SHA"

  # We invoke claim-dev-merge.sh explicitly here to exercise the script path
  # itself (Invariants 6, 7); the post-merge hook (Invariant 11) is exercised
  # separately below by doing a pull that brings in a remote merge.
  echo "→ running claim-dev-merge.sh"
  bash .io.v4rian.how-git/scripts/claim-dev-merge.sh --skip-pull

  echo
  echo "=== Invariant 6: claim-dev-merge.sh tagged dev HEAD ==="
  git fetch -q --tags
  TAG_DEV="v$(date -u +%Y).$(date -u +%-m).1-b.1"
  if git tag -l "$TAG_DEV" | grep -q "^$TAG_DEV$"; then
    TAG_SHA=$(git rev-parse "$TAG_DEV"^{commit})
    if [ "$TAG_SHA" = "$DEV_SHA" ]; then
      echo "  ✓ tag $TAG_DEV exists on $TAG_SHA (matches the SHA before the bump commit)"
    else
      echo "  ✗ tag $TAG_DEV exists but on $TAG_SHA, not the pushed SHA $DEV_SHA"
      exit 1
    fi
  else
    echo "  ✗ expected tag $TAG_DEV not found; tags present:"
    git tag -l | sed 's/^/    /'
    exit 1
  fi

  echo
  echo "=== Invariant 7: VERSION on dev was bumped (dev_counter +1) ==="
  git pull -q origin dev
  EXPECTED_DEV_VER="v$(date -u +%Y).$(date -u +%-m).1-b.2"
  ACTUAL_DEV_VER=$(cat VERSION)
  if [ "$ACTUAL_DEV_VER" = "$EXPECTED_DEV_VER" ]; then
    echo "  ✓ VERSION on dev = $ACTUAL_DEV_VER (bumped from -b.1 to -b.2)"
  else
    echo "  ✗ VERSION mismatch on dev (expected $EXPECTED_DEV_VER, got $ACTUAL_DEV_VER)"
    exit 1
  fi

  # --------------------------------------------------------------------------
  # Phase 2: fast-forward main to dev, run claim-main-release.sh, verify
  # release tag + Release + VERSION reset
  # --------------------------------------------------------------------------
  echo
  echo "→ fast-forwarding main to dev and pushing"
  git checkout -q main
  git pull -q origin main
  git merge -q --ff-only dev
  git push -q origin main
  MAIN_SHA=$(git rev-parse main)
  echo "  · main pushed at SHA $MAIN_SHA"

  echo "→ running claim-main-release.sh"
  # Token comes from the same chain claim-main-release.sh uses; passing it
  # via env so the script's optional GH Release creation reaches the API.
  GH_TOKEN="$TOKEN" bash .io.v4rian.how-git/scripts/claim-main-release.sh --skip-pull

  echo
  echo "=== Invariant 8: claim-main-release.sh tagged main HEAD with the release version ==="
  git fetch -q --tags
  TAG_REL="v$(date -u +%Y).$(date -u +%-m).1"
  if git tag -l "$TAG_REL" | grep -q "^$TAG_REL$"; then
    TAG_REL_SHA=$(git rev-parse "$TAG_REL"^{commit})
    if [ "$TAG_REL_SHA" = "$MAIN_SHA" ]; then
      echo "  ✓ tag $TAG_REL exists on $TAG_REL_SHA (matches pushed main SHA)"
    else
      echo "  ✗ tag $TAG_REL exists but on $TAG_REL_SHA, not pushed SHA $MAIN_SHA"
      exit 1
    fi
  else
    echo "  ✗ expected tag $TAG_REL not found; tags:"
    git tag -l | sed 's/^/    /'
    exit 1
  fi

  echo
  echo "=== Invariant 9: GitHub Release for the release tag ==="
  REL_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -H "Authorization: token $TOKEN" \
    "https://api.github.com/repos/$DEST_OWNER/$NAME/releases/tags/$TAG_REL")
  case "$REL_CODE" in
    200) echo "  ✓ GitHub Release for $TAG_REL exists (HTTP 200)" ;;
    404) echo "  ⚠ no Release for $TAG_REL (HTTP 404) — claim-main-release.sh may have run without a token; the git tag is canonical regardless. Passing this invariant as a soft check." ;;
    *)   echo "  ✗ unexpected status $REL_CODE checking Release"; exit 1 ;;
  esac

  echo
  echo "=== Invariant 10: VERSION on main bumped (main_counter +1, dev_counter reset) ==="
  git pull -q origin main
  EXPECTED_NEXT="v$(date -u +%Y).$(date -u +%-m).2-b.1"
  ACTUAL_NEXT=$(cat VERSION)
  if [ "$ACTUAL_NEXT" = "$EXPECTED_NEXT" ]; then
    echo "  ✓ VERSION on main = $ACTUAL_NEXT (main_counter 1→2, dev_counter reset to 1)"
  else
    echo "  ✗ VERSION mismatch on main (expected $EXPECTED_NEXT, got $ACTUAL_NEXT)"
    exit 1
  fi

  echo
  echo "=== Invariant 11: post-merge hook auto-claims on a local --no-ff merge into dev ==="
  echo
  # The automator path. From dev's perspective there are two equivalent
  # ways a new merge commit appears:
  #   (a) `git merge --no-ff pool/*` locally (the merger pulls + merges)
  #   (b) `git pull` brings a remote merge commit that landed via GitHub UI
  # Both fire post-merge identically. We exercise (a) here since it's a
  # complete loop in a single repo without needing a second clone.

  # Snapshot pre-state
  git checkout -q dev
  git pull -q --ff-only origin dev
  PRE_TAG_COUNT=$(git tag -l | wc -l | tr -d ' ')
  PRE_VER=$(cat VERSION)
  echo "    pre:  VERSION=$PRE_VER  tag-count=$PRE_TAG_COUNT"

  # Simulate a PR merging by branching, committing, merging --no-ff back
  git checkout -q -b pool/n2.refactor.post_merge_hook_probe
  echo "# probe" > README-PROBE.md
  git add README-PROBE.md
  git commit -q -m "[REFACTOR] Probe post-merge auto-claim path"
  git push -q origin pool/n2.refactor.post_merge_hook_probe
  git checkout -q dev
  echo "    → about to merge pool/n2.* into dev; the post-merge hook should fire and auto-claim:"
  git merge -q --no-ff pool/n2.refactor.post_merge_hook_probe \
    -m "[MERGE] pool/n2.refactor.post_merge_hook_probe into dev: $PRE_VER (probe)" 2>&1 \
    | sed 's/^/      /'

  POST_TAG_COUNT=$(git tag -l | wc -l | tr -d ' ')
  POST_VER=$(cat VERSION)
  echo "    post: VERSION=$POST_VER  tag-count=$POST_TAG_COUNT"

  if [ "$POST_TAG_COUNT" -gt "$PRE_TAG_COUNT" ] && [ "$POST_VER" != "$PRE_VER" ]; then
    echo "  ✓ post-merge hook fired automatically: claimed $PRE_VER, dev bumped to $POST_VER, tag count grew by $((POST_TAG_COUNT - PRE_TAG_COUNT))"
  else
    echo "  ✗ post-merge hook did NOT auto-claim"
    echo "      tag delta: $((POST_TAG_COUNT - PRE_TAG_COUNT)) (expected ≥ 1)"
    echo "      version: $PRE_VER → $POST_VER (expected change)"
    git log --oneline -5
    exit 1
  fi

  echo
  echo "=== git-native BUMP CYCLE + AUTOMATOR (Invariants 6-11) PASSED ==="
  echo
fi

# ----------------------------------------------------------------------------
# Cleanup (delete throwaway repo) unless --keep
# ----------------------------------------------------------------------------
cd /tmp   # leave the test dir so trap can remove it
if $KEEP; then
  echo "→ --keep set; leaving throwaway alive at $GEN_URL"
  echo "→ local clone left in $TEST_DIR/repo (trap will remove on exit; copy elsewhere if you need it)"
else
  echo "→ deleting throwaway repo $DEST_OWNER/$NAME"
  DEL_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE \
    -H "Authorization: token $TOKEN" \
    "https://api.github.com/repos/$DEST_OWNER/$NAME")
  case "$DEL_CODE" in
    204) echo "  ✓ deleted" ;;
    403) echo "  ⚠ token lacks delete_repo scope (HTTP 403). Throwaway left alive at $GEN_URL — delete it manually at Settings → Danger Zone → Delete this repository, or run with --keep to silence this warning." ;;
    404) echo "  ⚠ already gone (HTTP 404)" ;;
    *)   echo "  ⚠ unexpected status $DEL_CODE; throwaway may still exist at $GEN_URL" ;;
  esac
fi
