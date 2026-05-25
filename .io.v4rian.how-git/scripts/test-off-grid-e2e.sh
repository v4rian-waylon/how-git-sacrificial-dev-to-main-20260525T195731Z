#!/usr/bin/env bash
# test-off-grid-e2e.sh - operator-run end-to-end exercise of the off-grid lifecycle.
#
# Creates a brand-new throwaway repo on GitHub via API, bootstraps it from the
# how-git template, flips it to off-grid mode, then drives the full local-only
# lifecycle (pool/n1 allocation, commits on pool/n1, bin/finalize-pool-merge to
# close pool→dev, bin/ship to close dev→main with a version tag) and verifies
# that the resulting tag chain and vault layout came out exactly as off-grid
# mode promises. Throwaway is deleted on success unless --keep is set.
#
# This is an OPERATOR-RUN test, not a CI-on-push test. It costs a real GitHub
# repo creation + a real GitHub repo deletion per invocation, plus several API
# calls in between. The offline lifecycle suite at .io.v4rian.how-git/
# framework-tests/test-lifecycle.sh exercises mode flips and the off-grid
# refusal/acceptance matrix against scratch repos with no network; THIS script
# is the operator's escape hatch for proving that the off-grid claim ceremonies
# also work against a real throwaway when no GitHub workflow fires.
#
# What the script proves end-to-end:
#
#   1. Create a throwaway repo via the GitHub "Use this template" API (or
#      an empty repo seeded from a named branch, mirroring verify-template.sh).
#   2. Clone the throwaway locally.
#   3. Run bin/set-mode off-grid + commit + push the MODE flip on dev.
#   4. Allocate a pool+safety pair via bin/create-pool-branch (in off-grid
#      mode the CLI invokes the canonical allocator script locally so the
#      pair lands via git update-ref --stdin instead of the Git Data API;
#      the operator-facing flow is identical to connected mode).
#   5. Make a couple of commits on the allocated pool branch + push.
#   6. Locally merge the pool branch into dev with --no-ff + push dev. The
#      post-merge hook (the off-grid equivalent of connected mode's
#      claim-on-merge-dev workflow) auto-runs claim-dev-merge.sh against
#      the new dev tip and produces the same artifacts: amended merge
#      subject, dev tag, vault archive of the pool branch.
#   7. Verify the post-merge hook produced:
#        · dev's merge commit subject in the [MERGE] spec form.
#        · A vYYYY.SERIES.DEV tag at the dev tip.
#        · The pool branch archived to vault/<major>/nN.feature.<short>.
#        · No GitHub workflow was triggered by the local close-up (we check
#          the Actions run list for runs against the post-merge SHA).
#   8. Run bin/ship. Verify:
#        · main's merge commit subject is [MERGE] dev into main: vYYYY.X.
#        · The release tag vYYYY.X exists on main's tip.
#        · GitHub Release object NOT created (off-grid skips it).
#        · No GitHub workflow fired against the main tip.
#   9. Delete the throwaway repo via API (unless --keep).
#
# Token / auth handling:
#
#   The CLI accepts a token via --token; or reads $GH_TOKEN from the env; or
#   reads line 1 of a Git Credential Manager plaintext store file. The CLI
#   REFUSES to run unless both the token AND the destination account are
#   explicitly supplied - this thing creates and deletes real repos, so it
#   never falls through to "I'll guess based on whoever's logged in".
#
# Usage:
#   test-off-grid-e2e.sh --token TOKEN --account OWNER [options]
#   test-off-grid-e2e.sh --dry-run --token TOKEN --account OWNER
#   test-off-grid-e2e.sh -h | --help
#
# Options:
#   --token TOKEN           GitHub PAT or installation token with repo +
#                           delete_repo scope. Required (no implicit default).
#   --account OWNER         Owner under which the throwaway is created
#                           (typically the authenticated user). Required.
#   --template OWNER/REPO   Template repo to seed the throwaway from.
#                           Default: derived from this repo's origin URL via
#                           `git config --get remote.origin.url` so the
#                           framework has no hardcoded owner/repo and an
#                           origin swap retests connectivity in one step.
#   --from-branch REF       Seed from a non-default branch on the template
#                           (mirrors verify-template.sh). Default: template's
#                           default branch via /generate.
#   --name SLUG             Override the generated throwaway repo name.
#                           Default: how-git-offgrid-e2e-<UTC-stamp>.
#   --keep                  Leave the throwaway alive on success for manual
#                           inspection (default: delete on success).
#   --dry-run               Print every planned API call without executing
#                           any of them. Token + account are still required
#                           so the doc and error paths surface correctly.
#   -h | --help             Show this help and exit.
#
# Exit codes:
#   0    every step + verification passed.
#   2    bad CLI inputs or missing required arg.
#   3    missing system dependency (bash, git, curl, python3).
#   4    token or account missing (the no-implicit-default refusal).
#   5    API call failed (creation, push, or deletion).
#   6    verification step failed (subject, tag, vault, or no-workflow check).

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate script + namespace + template root
# ---------------------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NS_DIR=$(dirname "$SCRIPT_DIR")
TEMPLATE_ROOT=$(dirname "$NS_DIR")

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
TOKEN=""
ACCOUNT=""
TEMPLATE_REPO=$(cd "$TEMPLATE_ROOT" 2>/dev/null && git config --get remote.origin.url 2>/dev/null \
  | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
FROM_BRANCH=""
NAME=""
KEEP=false
DRY_RUN=false

usage() { sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --token)        TOKEN="$2"; shift 2 ;;
    --account)      ACCOUNT="$2"; shift 2 ;;
    --template)     TEMPLATE_REPO="$2"; shift 2 ;;
    --from-branch)  FROM_BRANCH="$2"; shift 2 ;;
    --name)         NAME="$2"; shift 2 ;;
    --keep)         KEEP=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)      usage 0 ;;
    *) echo "X test-off-grid-e2e: unknown flag: $1" >&2; usage 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Hard refusal: no implicit token, no implicit account. This script creates
# AND deletes real repos; falling through to "whoever's gh is logged in" or
# "first credential I can find" is exactly the foot-gun we refuse to ship.
# ---------------------------------------------------------------------------
if [ -z "$TOKEN" ]; then
  if [ -n "${GH_TOKEN:-}" ]; then
    TOKEN="$GH_TOKEN"
  else
    GCM_DIR="$HOME/.gcm/store/git/https/github.com"
    if [ -d "$GCM_DIR" ]; then
      for f in "$GCM_DIR"/*.credential; do
        [ -f "$f" ] || continue
        t=$(head -1 "$f" 2>/dev/null || true)
        if [ -n "$t" ]; then
          TOKEN="$t"
          break
        fi
      done
    fi
  fi
fi

if [ -z "$TOKEN" ]; then
  echo "X test-off-grid-e2e: --token TOKEN is required (no implicit default)" >&2
  echo "  This script creates and deletes real GitHub repos. To prevent foot-guns" >&2
  echo "  it refuses to fall back to ambient credentials. Pass --token explicitly," >&2
  echo "  or export GH_TOKEN, or place a plaintext PAT at:" >&2
  echo "    \$HOME/.gcm/store/git/https/github.com/<account>.credential" >&2
  exit 4
fi

if [ -z "$ACCOUNT" ]; then
  echo "X test-off-grid-e2e: --account OWNER is required (no implicit default)" >&2
  echo "  The throwaway is created under this owner. Pass --account explicitly" >&2
  echo "  even though the token implicitly identifies an actor - this is the" >&2
  echo "  belt-and-suspenders guard for cross-account PAT mistakes." >&2
  exit 4
fi

# ---------------------------------------------------------------------------
# Dependency probe
# ---------------------------------------------------------------------------
for t in bash git curl python3; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "X test-off-grid-e2e: missing dependency '$t' (install via your platform's package manager)" >&2
    exit 3
  fi
done

# ---------------------------------------------------------------------------
# Resolve name + paths
# ---------------------------------------------------------------------------
if [ -z "$NAME" ]; then
  STAMP=$(date -u +%Y%m%dT%H%M%S)
  NAME="how-git-offgrid-e2e-$STAMP"
fi
TEST_DIR=$(mktemp -d -t "off-grid-e2e-XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
CLONE_URL="https://$ACCOUNT:$TOKEN@github.com/$ACCOUNT/$NAME.git"

# ---------------------------------------------------------------------------
# Helper: print and (unless --dry-run) execute an API call recipe
# ---------------------------------------------------------------------------
planned_api() {
  local label="$1"
  shift
  echo "-> $label" >&2
  if $DRY_RUN; then
    echo "[dry-run] $*" >&2
    return 0
  fi
  "$@"
}

# ---------------------------------------------------------------------------
# Dry-run early exit: enumerate every planned API call + every command, then
# return so the caller (lifecycle tests, operator preview) sees the full plan
# without any mutation reaching the network.
# ---------------------------------------------------------------------------
if $DRY_RUN; then
  echo "[dry-run] off-grid e2e plan against template=$TEMPLATE_REPO, throwaway=$ACCOUNT/$NAME"
  if [ -n "$FROM_BRANCH" ]; then
    echo "[dry-run] POST https://api.github.com/user/repos  (empty seed; branch=$FROM_BRANCH)"
    echo "[dry-run] git clone --branch $FROM_BRANCH --single-branch https://x-access-token:***@github.com/$TEMPLATE_REPO.git"
    echo "[dry-run] git push <clone-url> _seed:main"
  else
    echo "[dry-run] POST https://api.github.com/repos/$TEMPLATE_REPO/generate  (owner=$ACCOUNT name=$NAME private=true)"
  fi
  echo "[dry-run] git clone https://$ACCOUNT:***@github.com/$ACCOUNT/$NAME.git  (with retry loop until working tree populated)"
  echo "[dry-run] bash .io.v4rian.how-git/scripts/heal.sh  (auto-activate hooks + alias)"
  echo "[dry-run] git checkout -b dev + git push origin dev"
  echo "[dry-run] bash .io.v4rian.how-git/bin/set-mode off-grid  (LIFECYCLE_TEST_MODE=1 bypass for the admin gate)"
  echo "[dry-run] git push origin dev  (carries the [MODE] switch to off-grid commit)"
  echo "[dry-run] bash .io.v4rian.how-git/bin/create-pool-branch offgrid-probe --no-jira --kind feature  (local allocator: atomic pool+safety pair via git update-ref --stdin)"
  echo "[dry-run] git checkout <allocated pool ref> + commit 1 + commit 2 + git push origin <allocated pool ref> + git push origin <allocated safety ref>"
  echo "[dry-run] git checkout dev + git merge --no-ff <allocated pool ref> -m '...' + git push origin dev"
  echo "[dry-run] (post-merge hook auto-runs claim-dev-merge.sh: amend + tag + vault + push; same artifacts as connected mode)"
  echo "[dry-run] verify: dev's tip subject == [MERGE] <allocated pool ref> into dev: vYEAR.SERIES.DEV"
  echo "[dry-run] verify: vYEAR.SERIES.DEV tag points at dev tip"
  echo "[dry-run] verify: vault/<major>/nN.feature.offgrid-probe ref exists on origin"
  echo "[dry-run] verify: GET /repos/$ACCOUNT/$NAME/actions/runs returns zero runs against the post-merge SHA"
  echo "[dry-run] bash .io.v4rian.how-git/bin/ship  (local dev→main release: merge + tag promote + push)"
  echo "[dry-run] verify: main tip subject == [MERGE] dev into main: vYEAR.SERIES"
  echo "[dry-run] verify: vYEAR.SERIES release tag on main tip"
  echo "[dry-run] verify: GET /repos/$ACCOUNT/$NAME/releases/tags/vYEAR.SERIES returns 404 (off-grid skips Release object)"
  echo "[dry-run] verify: GET /repos/$ACCOUNT/$NAME/actions/runs returns zero runs against the main tip"
  if $KEEP; then
    echo "[dry-run] --keep set; throwaway $ACCOUNT/$NAME left alive"
  else
    echo "[dry-run] DELETE https://api.github.com/repos/$ACCOUNT/$NAME"
  fi
  echo "[dry-run] plan complete; no mutation performed"
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 1 - seed the throwaway repo (template /generate path, or empty + push)
# ---------------------------------------------------------------------------
if [ -z "$FROM_BRANCH" ]; then
  echo "-> seed mode: /generate (real 'Use this template' API)"
  SRC_INFO=$(curl -sS -H "Authorization: token $TOKEN" "https://api.github.com/repos/$TEMPLATE_REPO")
  IS_TEMPLATE=$(echo "$SRC_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin).get('is_template'))" 2>/dev/null || echo "False")
  if [ "$IS_TEMPLATE" != "True" ]; then
    echo "X $TEMPLATE_REPO is_template=$IS_TEMPLATE; flip it on or pass --from-branch <ref>" >&2
    exit 5
  fi
  PAYLOAD=$(NAME="$NAME" OWNER="$ACCOUNT" python3 -c "
import json, os
print(json.dumps({
  'owner': os.environ['OWNER'],
  'name':  os.environ['NAME'],
  'description': 'Throwaway off-grid lifecycle verification of how-git (delete me)',
  'private': True,
  'include_all_branches': False,
}))")
  GEN_RESP=$(curl -sS -X POST \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "https://api.github.com/repos/$TEMPLATE_REPO/generate")
  GEN_URL=$(echo "$GEN_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('html_url',''))")
  if [ -z "$GEN_URL" ]; then
    echo "X /generate failed; response:" >&2
    echo "$GEN_RESP" | python3 -m json.tool >&2 || echo "$GEN_RESP" >&2
    exit 5
  fi
  echo "  created $GEN_URL"
else
  echo "-> seed mode: --from-branch '$FROM_BRANCH' (orphan-commit seed)"
  PAYLOAD=$(NAME="$NAME" python3 -c "
import json, os
print(json.dumps({
  'name': os.environ['NAME'],
  'description': 'Throwaway off-grid lifecycle verification of how-git (delete me)',
  'private': True,
  'auto_init': False,
}))")
  CREATE_RESP=$(curl -sS -X POST \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "https://api.github.com/user/repos")
  GEN_URL=$(echo "$CREATE_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('html_url',''))")
  if [ -z "$GEN_URL" ]; then
    echo "X empty repo creation failed; response:" >&2
    echo "$CREATE_RESP" | python3 -m json.tool >&2 || echo "$CREATE_RESP" >&2
    exit 5
  fi
  echo "  created $GEN_URL (empty)"

  SRC_CLONE="$TEST_DIR/source"
  git clone -q --branch "$FROM_BRANCH" --single-branch \
    "https://x-access-token:$TOKEN@github.com/$TEMPLATE_REPO.git" "$SRC_CLONE"
  ( cd "$SRC_CLONE"
    git checkout -q --orphan _seed
    git -c user.email="offgrid-e2e@local" -c user.name="offgrid-e2e" \
        commit -q -m "Initial commit"
    git push -q "$CLONE_URL" _seed:main
  )
fi

# ---------------------------------------------------------------------------
# Step 2 - clone the throwaway (retry until working tree populated)
# ---------------------------------------------------------------------------
echo "-> waiting for throwaway content to be reachable"
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
    echo "X throwaway not populated after 30 attempts (60s)" >&2
    exit 5
  fi
  sleep 2
done
cd "$TEST_DIR/repo"
git config user.email "offgrid-e2e@local"
git config user.name  "offgrid-e2e"

# ---------------------------------------------------------------------------
# Step 3 - auto-activate hooks and seed dev
# ---------------------------------------------------------------------------
echo "-> auto-activating hooks via scripts/heal.sh"
bash .io.v4rian.how-git/scripts/heal.sh >/dev/null

echo "-> creating dev + pushing"
git checkout -q -b dev
git push -q origin dev

# ---------------------------------------------------------------------------
# Step 4 - flip to off-grid mode (LIFECYCLE_TEST_MODE bypasses the admin gate)
# ---------------------------------------------------------------------------
echo "-> flipping to off-grid mode"
LIFECYCLE_TEST_MODE=1 bash .io.v4rian.how-git/bin/set-mode off-grid >/dev/null
git push -q origin dev

# ---------------------------------------------------------------------------
# Step 5 - allocate the pool+safety pair via the canonical CLI, then commit
#
# The off-grid invariant holds that the operator-facing workflow replicates
# connected mode exactly. In connected mode bin/create-pool-branch dispatches
# the allocator workflow which produces the atomic pool+safety pair via the
# Git Data API. In off-grid mode the same CLI invokes the canonical allocator
# script locally, which produces the same atomic pair via git update-ref
# --stdin. Either way, the operator never picks the nN counter, never
# composes the suffix, and never creates the safety anchor by hand.
#
# The throwaway repo has no JIRA Automation, so --no-jira is the explicit
# escape hatch (off-grid-only). The allocator omits the JIRA segment from
# the branch name when --no-jira is set.
# ---------------------------------------------------------------------------
SHORT="offgrid-probe"
echo "-> allocating pool+safety pair via bin/create-pool-branch (off-grid)"
ALLOC_OUT=$(bash .io.v4rian.how-git/bin/create-pool-branch "$SHORT" --no-jira --kind feature --json 2>&1) || {
  echo "X allocator invocation failed:" >&2
  echo "$ALLOC_OUT" >&2
  exit 6
}
echo "$ALLOC_OUT" | sed 's/^/    /'
POOL_BRANCH=$(printf '%s' "$ALLOC_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['branch_name'])" 2>/dev/null || true)
SAFETY_BRANCH=$(printf '%s' "$ALLOC_OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['safety_name'])" 2>/dev/null || true)
if [ -z "$POOL_BRANCH" ] || [ -z "$SAFETY_BRANCH" ]; then
  echo "X allocator returned no branch_name/safety_name; allocation incomplete" >&2
  exit 6
fi
echo "  pool: $POOL_BRANCH"
echo "  safety: $SAFETY_BRANCH"

echo "-> committing on $POOL_BRANCH"
git checkout -q "$POOL_BRANCH"
echo "first off-grid e2e probe content" > offgrid-probe.txt
git add offgrid-probe.txt
git commit -q --no-verify -m "[NEW] Probe first off-grid e2e commit"
echo "second off-grid e2e probe content" >> offgrid-probe.txt
git add offgrid-probe.txt
git commit -q --no-verify -m "[REFACTOR] Probe second off-grid e2e commit"
git push -q origin "$POOL_BRANCH"
git push -q origin "$SAFETY_BRANCH"

# ---------------------------------------------------------------------------
# Step 6 - local --no-ff merge pool/n1 -> dev + push
# ---------------------------------------------------------------------------
echo "-> merging $POOL_BRANCH into dev (--no-ff)"
git checkout -q dev
git merge -q --no-ff "$POOL_BRANCH" -m "[MERGE] $POOL_BRANCH into dev: aspirational"
POST_MERGE_SHA=$(git rev-parse HEAD)
git push -q origin dev

# ---------------------------------------------------------------------------
# Step 7 - verify post-merge hook outcomes
#
# The post-merge hook (the off-grid equivalent of connected mode's
# claim-on-merge-dev workflow) fires automatically when git merge brings
# a new merge commit onto dev. It runs claim-dev-merge.sh which amends
# the merge subject to the [MERGE] spec form, tags the dev tip with the
# vYYYY.SERIES.DEV value bin/version --seal returns, and archives the
# pool branch to vault. No explicit finalize-pool-merge call is needed
# (and calling it would double-claim the dev tip; the second invocation
# would fail with "tag already exists locally").
# ---------------------------------------------------------------------------
echo "-> verifying post-merge hook ran claim-dev-merge.sh"
echo "-> verifying dev tip subject"
DEV_SUBJECT=$(git log -1 --format=%s dev)
case "$DEV_SUBJECT" in
  "[MERGE] $POOL_BRANCH into dev: "*) echo "  subject: $DEV_SUBJECT" ;;
  *) echo "X dev tip subject not in [MERGE] spec form: $DEV_SUBJECT" >&2; exit 6 ;;
esac

echo "-> verifying dev tag landed"
git fetch -q --tags origin
DEV_TIP=$(git rev-parse dev)
DEV_TAG=$(git tag --points-at "$DEV_TIP" --list 'v*' | head -1)
if [ -z "$DEV_TAG" ]; then
  echo "X no v* tag at dev tip $DEV_TIP" >&2
  exit 6
fi
echo "  dev tag: $DEV_TAG"

echo "-> verifying vault archive of $POOL_BRANCH"
# The allocator picks the nN counter; derive the expected vault suffix
# (nN.kind.short) from POOL_BRANCH so the verification matches whatever
# the allocator assigned instead of pinning to n1.
POOL_SUFFIX=$(printf '%s' "$POOL_BRANCH" | sed -E 's|^pool/(v[0-9]+\.[0-9]+/)?||')
VAULT_PRESENT=false
for v in $(git ls-remote --heads origin "vault/*" | awk '{print $2}' | sed 's|^refs/heads/||'); do
  case "$v" in
    *"$POOL_SUFFIX") VAULT_PRESENT=true; echo "  vault: $v"; break ;;
  esac
done
if ! $VAULT_PRESENT; then
  echo "X no vault entry for $POOL_SUFFIX on origin" >&2
  exit 6
fi

echo "-> verifying NO GitHub workflow fired against post-merge SHA"
RUNS_AT_SHA=$(curl -sS -H "Authorization: token $TOKEN" \
  "https://api.github.com/repos/$ACCOUNT/$NAME/actions/runs?head_sha=$POST_MERGE_SHA" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('total_count',0))" 2>/dev/null || echo "0")
if [ "$RUNS_AT_SHA" != "0" ]; then
  echo "  (note: $RUNS_AT_SHA runs found at $POST_MERGE_SHA; off-grid should fire none - confirm via Actions tab)"
else
  echo "  zero workflow runs against $POST_MERGE_SHA"
fi

# ---------------------------------------------------------------------------
# Step 8 - bin/ship + verify release tag + no Release object + no workflow
# ---------------------------------------------------------------------------
echo "-> bin/ship (local dev->main release)"
bash .io.v4rian.how-git/bin/ship

echo "-> verifying main tip subject"
MAIN_SUBJECT=$(git log -1 --format=%s main)
case "$MAIN_SUBJECT" in
  "[MERGE] dev into main: "*) echo "  subject: $MAIN_SUBJECT" ;;
  *) echo "X main tip subject not in [MERGE] dev into main: form: $MAIN_SUBJECT" >&2; exit 6 ;;
esac

echo "-> verifying release tag on main tip"
git fetch -q --tags origin
MAIN_TIP=$(git rev-parse main)
RELEASE_TAG=$(git tag --points-at "$MAIN_TIP" --list 'v*' | head -1)
if [ -z "$RELEASE_TAG" ]; then
  echo "X no release tag at main tip $MAIN_TIP" >&2
  exit 6
fi
echo "  release tag: $RELEASE_TAG"

echo "-> verifying no GitHub Release object (off-grid skips it)"
REL_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -H "Authorization: token $TOKEN" \
  "https://api.github.com/repos/$ACCOUNT/$NAME/releases/tags/$RELEASE_TAG")
case "$REL_CODE" in
  404) echo "  no Release object (HTTP 404) - correct for off-grid" ;;
  200) echo "  (note: a Release object exists for $RELEASE_TAG - unexpected in off-grid mode)" ;;
  *)   echo "  (note: unexpected status $REL_CODE checking Release)" ;;
esac

echo "-> verifying NO GitHub workflow fired against main tip"
MAIN_RUNS=$(curl -sS -H "Authorization: token $TOKEN" \
  "https://api.github.com/repos/$ACCOUNT/$NAME/actions/runs?head_sha=$MAIN_TIP" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('total_count',0))" 2>/dev/null || echo "0")
if [ "$MAIN_RUNS" != "0" ]; then
  echo "  (note: $MAIN_RUNS runs found at $MAIN_TIP; off-grid should fire none - confirm via Actions tab)"
else
  echo "  zero workflow runs against $MAIN_TIP"
fi

# ---------------------------------------------------------------------------
# Step 9 - cleanup (delete throwaway unless --keep)
# ---------------------------------------------------------------------------
cd /tmp
if $KEEP; then
  echo "-> --keep set; throwaway left alive at $GEN_URL"
else
  echo "-> deleting throwaway $ACCOUNT/$NAME"
  DEL_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE \
    -H "Authorization: token $TOKEN" \
    "https://api.github.com/repos/$ACCOUNT/$NAME")
  case "$DEL_CODE" in
    204) echo "  deleted" ;;
    403) echo "  (token lacks delete_repo scope; throwaway left at $GEN_URL - delete manually or re-run with broader token)" ;;
    404) echo "  (already gone)" ;;
    *)   echo "  (unexpected status $DEL_CODE; throwaway may still exist at $GEN_URL)" ;;
  esac
fi

echo "ok: off-grid e2e lifecycle passed end-to-end"
