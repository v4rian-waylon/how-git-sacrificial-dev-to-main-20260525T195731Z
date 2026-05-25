#!/usr/bin/env bash
# allocate-pool-branch.sh — canonical v4rian pool branch allocator.
#
# Single source of truth for atomic creation of a pool/nN.kind.* branch
# and its paired safety/nN.kind.* anchor. Invoked from:
#
#   - .github/workflows/allocate-pool-branch.yml (repository_dispatch
#     from JIRA Automation, or workflow_dispatch from a human admin)
#   - bin/create-pool-branch (local CLI wrapper that triggers the
#     workflow above via `gh workflow run`)
#
# Behavior:
#
#   1. Parses inputs (kind, short_name, jira_key, sprint). kind is
#      optional; when absent it is classified via the Claude API from
#      the JIRA payload. short_name and jira_key are required.
#   2. Idempotency: scans existing pool/*, safety/*, vault/* refs for
#      the JIRA key (both flat and vYYYY.MAIN/-prefixed layouts). If
#      found, prints the existing branch URL on stdout (as JSON) and
#      exits 0 with no mutation.
#   3. Allocates the next nN as max(existing pool/n*, safety/n*) + 1
#      across both layouts so the n-counter remains globally unique.
#   4. Derives the vYYYY.MAIN major-version prefix from bin/version
#      --seal at allocation time (e.g. v2026.0.47 -> v2026.0) so the
#      same release-line classification that the vault and archived
#      safety paths carry applies from allocation onward. When the
#      seal is unreachable or unparseable, falls back to the legacy
#      flat layout for offline-test and bootstrap scenarios.
#   5. Composes the branch name as
#      pool/<vYYYY.MAIN>/nN.{kind}.[sprintX-]JIRA-NNN-{slug} (or the
#      legacy flat pool/nN.* when the prefix could not be derived),
#      then validates max ref length (255 chars).
#   6. Resolves current dev HEAD SHA via the Git Data API.
#   7. Creates pool/* and safety/* at that SHA atomically via POST
#      /repos/{owner}/{repo}/git/refs. If safety creation fails after
#      pool was already created, the pool is deleted and the operation
#      reported as partial_pair_rollback.
#   8. Prints JSON {branch_name, safety_name, branch_url, safety_url,
#      sha, kind, jira_key, major_prefix} to stdout for caller
#      consumption.
#
# All claude classification requests use aggressive exponential backoff
# capped at 5 minutes between attempts; the workflow timeout (4320
# minutes) is the only ceiling. The expected real-world finish is
# seconds.
#
# Required environment:
#
#   GITHUB_REPOSITORY  owner/repo (auto-set in GitHub Actions; pass
#                      explicitly when running locally). REQUIRED in
#                      connected mode; IGNORED in off-grid mode.
#   GH_TOKEN           token with contents:write on the repo. REQUIRED
#                      in connected mode; IGNORED in off-grid mode.
#   ANTHROPIC_API_KEY  required only if kind classification is needed
#                      (kind input is empty)
#
# Required input env (or --flag form when invoked directly):
#
#   ALLOC_SHORT_NAME                      required
#   ALLOC_JIRA_KEY                        required UNLESS ALLOC_NO_JIRA=1
#                                         (or --no-jira). The off-grid
#                                         exemption exists because the
#                                         JIRA Automation pipeline is a
#                                         connected-mode entry point.
#   ALLOC_NO_JIRA                         optional, set to "1" to omit
#                                         the JIRA segment from the branch
#                                         name. Idempotency-by-JIRA is
#                                         skipped when no JIRA key is
#                                         supplied. Off-grid-only.
#   ALLOC_KIND                            optional (classified if absent)
#   ALLOC_SPRINT                          optional
#   ALLOC_JIRA_TITLE, ALLOC_JIRA_DESC     optional, used as classification
#                                         context when ALLOC_KIND is absent
#   ALLOC_MODE                            optional, "connected" (default)
#                                         or "off-grid". In off-grid mode
#                                         the allocator skips the GitHub
#                                         Git Data API entirely and creates
#                                         the pool+safety pair atomically
#                                         via `git update-ref --stdin` in
#                                         the local repo. The requirement
#                                         commit (when supplied) is built
#                                         via local git plumbing
#                                         (hash-object, mktree, commit-tree).
#                                         Off-grid replicates the connected
#                                         operator workflow exactly; only
#                                         the under-the-hood implementation
#                                         differs.
#   ALLOC_REQUIREMENT                     optional, the active-requirement
#                                         text for the branch (verbatim).
#                                         When supplied, the allocator
#                                         writes it to
#                                         .io.v4rian.how-git/active-requirement
#                                         and creates the initial [REQ]
#                                         commit on the pool branch with the
#                                         requirement text as the body. The
#                                         safety anchor stays at the dev
#                                         tip (no requirement commit) so it
#                                         remains the pristine fork point.
#   ALLOC_REQUIREMENT_FILE                optional, path to a file whose
#                                         content is the requirement text.
#                                         Overrides ALLOC_REQUIREMENT when
#                                         both are set.

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing — accept env vars (workflow path) or --flags (direct path)
# ---------------------------------------------------------------------------
KIND="${ALLOC_KIND:-}"
SHORT="${ALLOC_SHORT_NAME:-}"
JIRA="${ALLOC_JIRA_KEY:-}"
SPRINT="${ALLOC_SPRINT:-}"
JIRA_TITLE="${ALLOC_JIRA_TITLE:-}"
JIRA_DESC="${ALLOC_JIRA_DESC:-}"
REQUIREMENT="${ALLOC_REQUIREMENT:-}"
REQUIREMENT_FILE="${ALLOC_REQUIREMENT_FILE:-}"
REPO_FULL="${GITHUB_REPOSITORY:-}"
MODE="${ALLOC_MODE:-connected}"
NO_JIRA="${ALLOC_NO_JIRA:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --kind)              KIND="$2"; shift 2 ;;
    --short-name)        SHORT="$2"; shift 2 ;;
    --jira)              JIRA="$2"; shift 2 ;;
    --sprint)            SPRINT="$2"; shift 2 ;;
    --jira-title)        JIRA_TITLE="$2"; shift 2 ;;
    --jira-desc)         JIRA_DESC="$2"; shift 2 ;;
    --requirement)       REQUIREMENT="$2"; shift 2 ;;
    --requirement-file)  REQUIREMENT_FILE="$2"; shift 2 ;;
    --repo)              REPO_FULL="$2"; shift 2 ;;
    --mode)              MODE="$2"; shift 2 ;;
    --no-jira)           NO_JIRA="1"; shift ;;
    -h|--help)
      sed -n '2,88p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "allocate-pool-branch: unknown flag: $1" >&2; exit 2 ;;
  esac
done

case "$MODE" in
  connected|off-grid) ;;
  *) echo "allocate-pool-branch: invalid mode '$MODE' (expected: connected or off-grid)" >&2; exit 2 ;;
esac

# --requirement-file (if supplied) overrides --requirement.
if [ -n "$REQUIREMENT_FILE" ]; then
  if [ ! -f "$REQUIREMENT_FILE" ]; then
    echo "allocate-pool-branch: requirement file '$REQUIREMENT_FILE' does not exist" >&2
    exit 2
  fi
  REQUIREMENT=$(cat "$REQUIREMENT_FILE")
fi

# ---------------------------------------------------------------------------
# Required input validation. The GitHub API inputs (GITHUB_REPOSITORY,
# GH_TOKEN) are connected-mode requirements only; off-grid mutates local
# refs and needs neither. JIRA is required by default in both modes
# because the connected path always carries a key (JIRA Automation
# supplies it; admin workflow_dispatch enforces it). The --no-jira escape
# hatch is off-grid-only: JIRA Automation does not exist in off-grid so
# the key has no upstream source. When --no-jira is set the branch name
# omits the JIRA segment entirely (per the optional ([A-Z]+-[0-9]+-)?
# group in the pre-push regex); idempotency-by-JIRA is also skipped.
# ---------------------------------------------------------------------------
if [ "$MODE" = "connected" ]; then
  # Mode-fit checks first (wrong flag for this mode), then dep checks.
  if [ "$NO_JIRA" = "1" ]; then
    echo "allocate-pool-branch: --no-jira / ALLOC_NO_JIRA is off-grid-only (connected mode JIRA Automation always carries a key)" >&2
    exit 2
  fi
  if [ -z "$REPO_FULL" ]; then
    echo "allocate-pool-branch: GITHUB_REPOSITORY (or --repo) is required in connected mode" >&2
    exit 2
  fi
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "allocate-pool-branch: GH_TOKEN is required in connected mode" >&2
    exit 2
  fi
fi
if [ -z "$SHORT" ]; then
  echo "allocate-pool-branch: short_name is required" >&2
  exit 2
fi
if [ "$NO_JIRA" != "1" ]; then
  if [ -z "$JIRA" ]; then
    echo "allocate-pool-branch: jira_key is required (or pass --no-jira in off-grid mode)" >&2
    exit 2
  fi
  if ! [[ "$JIRA" =~ ^[A-Z]+-[0-9]+$ ]]; then
    echo "allocate-pool-branch: jira_key '$JIRA' must match PROJ-NNN" >&2
    exit 2
  fi
fi
if [ -n "$SPRINT" ] && ! [[ "$SPRINT" =~ ^[0-9]+$ ]]; then
  echo "allocate-pool-branch: sprint '$SPRINT' must be a positive integer" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Slug the short_name into branch-name safe form (lowercase, hyphens only)
# ---------------------------------------------------------------------------
slug_short() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | sed -E 's/-+/-/g'
}
SHORT_SLUG=$(slug_short "$SHORT")
if [ -z "$SHORT_SLUG" ]; then
  echo "allocate-pool-branch: short_name slugs to empty" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Mode-dispatched ref-listing helpers. Connected mode queries the GitHub
# Git Data API; off-grid mode reads local refs via git for-each-ref. Both
# emit the same one-ref-per-line stream so downstream consumers
# (next_n, idempotency scan) stay layout-agnostic.
# ---------------------------------------------------------------------------
api() {
  curl -sS \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

list_refs_for_prefix() {
  local prefix="$1"
  if [ "$MODE" = "off-grid" ]; then
    # ** is required (not *) so the glob traverses the optional
    # vYYYY.MAIN/ segment introduced by the prefixed layout. A bare *
    # only matches a single path segment and silently misses
    # pool/v2026.0/n3.* style refs.
    git for-each-ref --format='%(refname:short)' "refs/heads/$prefix**" 2>/dev/null || true
  else
    api "https://api.github.com/repos/$REPO_FULL/git/matching-refs/heads/$prefix" \
      | grep -oE '"ref":[[:space:]]*"refs/heads/[^"]+"' \
      | sed -E 's|.*"refs/heads/([^"]+)".*|\1|'
  fi
}

existing_with_jira() {
  local jira="$1"
  { list_refs_for_prefix "pool/"
    list_refs_for_prefix "safety/"
    list_refs_for_prefix "vault/"
  } | grep -E "(^|[^A-Z0-9])${jira}([^0-9]|$)" || true
}

# Skip idempotency-by-JIRA when --no-jira is set (no key to match against).
if [ "$NO_JIRA" = "1" ]; then
  EXISTING=""
else
  EXISTING=$(existing_with_jira "$JIRA")
fi
if [ -n "$EXISTING" ]; then
  echo "→ idempotent no-op: refs containing $JIRA already exist" >&2
  echo "$EXISTING" | sed 's/^/    /' >&2
  EXISTING_POOL=$(printf '%s\n' "$EXISTING" | grep '^pool/' | head -1 || true)
  if [ -n "$EXISTING_POOL" ]; then
    if [ "$MODE" = "off-grid" ]; then
      EXISTING_URL="file://$(git rev-parse --show-toplevel)#$EXISTING_POOL"
    else
      EXISTING_URL="https://github.com/$REPO_FULL/tree/$EXISTING_POOL"
    fi
    cat <<JSON
{
  "status": "no-op",
  "branch_name": "$EXISTING_POOL",
  "branch_url": "$EXISTING_URL",
  "jira_key": "$JIRA",
  "reason": "ref containing JIRA key already exists"
}
JSON
  else
    cat <<JSON
{
  "status": "no-op",
  "branch_name": null,
  "branch_url": null,
  "jira_key": "$JIRA",
  "reason": "ref containing JIRA key already exists (no pool match; safety or vault)"
}
JSON
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Kind classification via Claude API when --kind was not supplied
# ---------------------------------------------------------------------------
classify_kind_via_claude() {
  local title="$1"
  local desc="$2"
  local key="${ANTHROPIC_API_KEY:-}"
  if [ -z "$key" ]; then
    echo "allocate-pool-branch: ANTHROPIC_API_KEY required to classify kind" >&2
    return 1
  fi
  local prompt
  prompt=$(printf '%s\n\n%s\n\n%s\n\n%s' \
    "Classify the following JIRA ticket into exactly one of: feature, fix, refactor, r&d, reconcile, doc." \
    "Title: ${title:-(none)}" \
    "Description: ${desc:-(none)}" \
    "Reply with ONLY the single classification token, lowercase, no other text.")
  local body
  body=$(printf '{"model":"claude-opus-4-5","max_tokens":32,"messages":[{"role":"user","content":%s}]}' \
    "$(printf '%s' "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")
  local attempt=1
  local delay=2
  local cap=300
  while true; do
    local resp
    resp=$(curl -sS \
      -H "x-api-key: $key" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      --data "$body" \
      https://api.anthropic.com/v1/messages 2>&1) || resp=""
    local extracted
    extracted=$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    parts = d.get("content", [])
    text = "".join(p.get("text","") for p in parts if p.get("type")=="text").strip().lower()
    print(text)
except Exception:
    pass
' 2>/dev/null || true)
    case "$extracted" in
      feature|fix|refactor|r\&d|reconcile|doc)
        printf '%s' "$extracted"
        return 0
        ;;
    esac
    echo "  · claude classification attempt $attempt failed (got: ${extracted:-<empty>}); backing off ${delay}s" >&2
    sleep "$delay"
    delay=$(( delay * 2 ))
    [ "$delay" -gt "$cap" ] && delay=$cap
    attempt=$(( attempt + 1 ))
  done
}

if [ -z "$KIND" ]; then
  echo "→ kind not supplied; classifying via Claude from JIRA payload" >&2
  KIND=$(classify_kind_via_claude "$JIRA_TITLE" "$JIRA_DESC")
fi

case "$KIND" in
  feature|fix|r\&d|refactor|reconcile|doc) ;;
  *)
    echo "allocate-pool-branch: invalid kind '$KIND' (must be feature|fix|r&d|refactor|reconcile|doc)" >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# Allocate next nN — max(existing pool/n*, safety/n*) + 1, walking BOTH the
# legacy flat layout (pool/nN.kind.suffix) and the prefixed layout
# (pool/<vYYYY.MAIN>/nN.kind.suffix). The sed expression strips the optional
# major-version segment before extracting the n-counter so the scan is
# layout-agnostic and the counter remains globally unique across cycles.
# ---------------------------------------------------------------------------
next_n() {
  # Two-step n-counter extraction. Anchoring with grep first and then
  # stripping the surrounding delimiters with sed avoids BSD sed's long-
  # standing parenthesised-alternation parser bug -- /n([0-9]+)\./ in a
  # single sed pass with `t; d` crashes on macOS even with `-E`. The
  # equivalent expression with the alternation up front in the grep
  # filter works portably across GNU sed (Ubuntu CI), BSD sed (operator
  # Macs), and busybox sed (slim CI images).
  local maxn=0
  local n
  for ref in $(list_refs_for_prefix "pool/") $(list_refs_for_prefix "safety/"); do
    n=$(printf '%s' "$ref" | grep -oE '/n[0-9]+\.' | head -1 | sed -E 's|/n([0-9]+)\.|\1|')
    [ -z "$n" ] && continue
    if [ "$n" -gt "$maxn" ]; then maxn="$n"; fi
  done
  echo $(( maxn + 1 ))
}
N=$(next_n)

# ---------------------------------------------------------------------------
# Derive the vYYYY.MAIN major-version prefix from bin/version --seal so the
# branch lands under the same release-line classification that vault/* and
# archived safety/* already carry. The seal output is vYYYY.MAIN.DEV; trim
# the trailing .DEV segment via parameter expansion. When the seal binary
# is unreachable (running outside a repo clone, offline tests, bootstrap
# scenarios) or returns an unparseable value, the script falls back to the
# legacy flat layout so existing tooling keeps working.
# ---------------------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")
VERSION_BIN=""
if [ -n "$SCRIPT_DIR" ] && [ -x "$SCRIPT_DIR/../bin/version" ]; then
  VERSION_BIN="$SCRIPT_DIR/../bin/version"
fi
MAJOR_PREFIX=""
if [ -n "$VERSION_BIN" ]; then
  SEAL=$("$VERSION_BIN" --seal 2>/dev/null | tr -d '\r\n')
  if [[ "$SEAL" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    MAJOR_PREFIX="${SEAL%.*}"
  fi
fi

# ---------------------------------------------------------------------------
# Compose branch name. Prefixed layout when MAJOR_PREFIX resolved; legacy
# flat layout otherwise. Both shapes round-trip cleanly through the pre-push
# regex, the rulesets, the archive flow, and the auto-rebase reconcile path.
# When --no-jira is set the JIRA segment is omitted from the suffix (the
# pre-push regex accepts both shapes because ([A-Z]+-[0-9]+-)? is optional).
# ---------------------------------------------------------------------------
SPRINT_PREFIX=""
[ -n "$SPRINT" ] && SPRINT_PREFIX="sprint${SPRINT}-"
if [ "$NO_JIRA" = "1" ]; then
  SUFFIX="n${N}.${KIND}.${SPRINT_PREFIX}${SHORT_SLUG}"
else
  SUFFIX="n${N}.${KIND}.${SPRINT_PREFIX}${JIRA}-${SHORT_SLUG}"
fi
if [ -n "$MAJOR_PREFIX" ]; then
  POOL_REF="pool/$MAJOR_PREFIX/$SUFFIX"
  SAFETY_REF="safety/$MAJOR_PREFIX/$SUFFIX"
else
  POOL_REF="pool/$SUFFIX"
  SAFETY_REF="safety/$SUFFIX"
fi

if [ ${#POOL_REF} -gt 255 ] || [ ${#SAFETY_REF} -gt 255 ]; then
  echo "allocate-pool-branch: composed ref exceeds 255 chars (pool=${#POOL_REF}, safety=${#SAFETY_REF})" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Resolve dev HEAD SHA. Connected mode queries the Git Data API; off-grid
# reads the local ref via git rev-parse. Both modes refuse to proceed if
# dev does not exist or cannot be resolved.
# ---------------------------------------------------------------------------
if [ "$MODE" = "off-grid" ]; then
  DEV_SHA=$(git rev-parse --verify refs/heads/dev 2>/dev/null || true)
else
  DEV_SHA=$(api "https://api.github.com/repos/$REPO_FULL/git/refs/heads/dev" \
    | grep -oE '"sha":[[:space:]]*"[^"]+"' | head -1 | sed -E 's|.*"sha":[[:space:]]*"([^"]+)".*|\1|')
fi

if [ -z "$DEV_SHA" ]; then
  echo "allocate-pool-branch: failed to resolve dev HEAD SHA" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Create both refs atomically.
#
# Connected mode: POST /git/refs twice in sequence (pool first, safety
# second); on partial failure, DELETE the pool to roll back.
#
# Off-grid mode: feed both ref creations to `git update-ref --stdin` as a
# single transaction. git applies the transaction atomically -- either
# both refs land at the dev SHA, or neither does. The transaction also
# enforces that neither ref already exists (the "create" verb requires
# the old-value to be the zero SHA), so a stale local ref blocks the
# allocation instead of silently overwriting it.
# ---------------------------------------------------------------------------
create_ref() {
  local ref="$1"
  local sha="$2"
  api -X POST "https://api.github.com/repos/$REPO_FULL/git/refs" \
    --data "$(printf '{"ref":"refs/heads/%s","sha":"%s"}' "$ref" "$sha")"
}

delete_ref() {
  local ref="$1"
  api -X DELETE "https://api.github.com/repos/$REPO_FULL/git/refs/heads/$ref" >/dev/null || true
}

if [ "$MODE" = "off-grid" ]; then
  # Atomic local pair creation via update-ref transaction. The transaction
  # uses the `--no-deref` flag implicitly (refnames are taken literally)
  # and the `create` verb fails the whole transaction if either ref
  # already exists, so a stale local ref aborts the allocation instead
  # of silently overwriting it. Status output from --stdin goes to
  # stderr so the success JSON on stdout stays clean for downstream
  # consumers parsing the response.
  UPDATE_REFS_OUT=$(printf 'start\ncreate refs/heads/%s %s\ncreate refs/heads/%s %s\nprepare\ncommit\n' \
        "$POOL_REF" "$DEV_SHA" "$SAFETY_REF" "$DEV_SHA" \
      | git update-ref --stdin 2>&1) || {
    echo "allocate-pool-branch: atomic local ref creation failed (pool=$POOL_REF safety=$SAFETY_REF)" >&2
    [ -n "$UPDATE_REFS_OUT" ] && echo "$UPDATE_REFS_OUT" >&2
    # Best-effort cleanup in case one ref slipped through before the abort.
    git update-ref -d "refs/heads/$POOL_REF" 2>/dev/null || true
    git update-ref -d "refs/heads/$SAFETY_REF" 2>/dev/null || true
    exit 1
  }
  [ -n "$UPDATE_REFS_OUT" ] && echo "$UPDATE_REFS_OUT" >&2
else
  POOL_RESP=$(create_ref "$POOL_REF" "$DEV_SHA")
  if ! echo "$POOL_RESP" | grep -q '"ref":[[:space:]]*"refs/heads/'; then
    echo "allocate-pool-branch: pool ref creation failed" >&2
    echo "$POOL_RESP" >&2
    exit 1
  fi

  SAFETY_RESP=$(create_ref "$SAFETY_REF" "$DEV_SHA")
  if ! echo "$SAFETY_RESP" | grep -q '"ref":[[:space:]]*"refs/heads/'; then
    echo "allocate-pool-branch: safety ref creation failed; rolling back pool ref" >&2
    echo "$SAFETY_RESP" >&2
    delete_ref "$POOL_REF"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Optional initial [REQ] active-requirement commit on the pool branch.
#
# When ALLOC_REQUIREMENT (or --requirement / --requirement-file) is set,
# the allocator writes the requirement text to a tracked file at
# .io.v4rian.how-git/active-requirement and creates the initial commit on
# the pool branch with the requirement text as the body. The safety
# anchor stays at the dev tip (the pristine fork point); only the pool
# branch advances by one commit.
#
# This commit is the canonical "active requirement for this branch"
# document: auditors and the smart-commit tool fetch its body via
# .io.v4rian.how-git/scripts/get-active-requirement.sh to give claude
# the branch's intent before it acts.
#
# Mechanics: blob -> tree (overlay of dev-tip tree + new file) -> commit
# (parent = dev tip) -> patch pool ref to the new commit SHA. The
# feedback_no_empty_commits rule is honored because the commit always
# touches a real file (the active-requirement file itself).
# ---------------------------------------------------------------------------
REQUIREMENT_COMMIT_SHA=""
if [ -n "$REQUIREMENT" ]; then
  echo "→ writing active-requirement commit on $POOL_REF" >&2

  REQ_COMMIT_TITLE="[REQ] active-requirement: $POOL_REF"
  REQ_COMMIT_MESSAGE=$(printf '%s\n\n%s' "$REQ_COMMIT_TITLE" "$REQUIREMENT")

  rollback_pair() {
    if [ "$MODE" = "off-grid" ]; then
      git update-ref -d "refs/heads/$POOL_REF" 2>/dev/null || true
      git update-ref -d "refs/heads/$SAFETY_REF" 2>/dev/null || true
    else
      delete_ref "$POOL_REF"
      delete_ref "$SAFETY_REF"
    fi
  }

  if [ "$MODE" = "off-grid" ]; then
    # Local plumbing path: hash-object for the blob, read dev's tree into
    # the index overlay, write-tree for the new tree, commit-tree for the
    # commit, update-ref to advance the pool branch.
    REQ_BLOB_SHA=$(printf '%s' "$REQUIREMENT" | git hash-object -w --stdin 2>/dev/null || true)
    if [ -z "$REQ_BLOB_SHA" ]; then
      echo "allocate-pool-branch: failed to write blob for active-requirement (off-grid); rolling back" >&2
      rollback_pair
      exit 1
    fi

    # Stage the dev-tip tree into a scratch index, overlay the requirement
    # file, then write the new tree. The scratch index keeps the operator's
    # working index untouched.
    SCRATCH_INDEX=$(mktemp -t alloc-pool-idx-XXXXXX)
    trap 'rm -f "$SCRATCH_INDEX"' EXIT
    if ! GIT_INDEX_FILE="$SCRATCH_INDEX" git read-tree "$DEV_SHA" 2>/dev/null; then
      echo "allocate-pool-branch: failed to read dev tree into scratch index (off-grid); rolling back" >&2
      rollback_pair
      exit 1
    fi
    if ! GIT_INDEX_FILE="$SCRATCH_INDEX" git update-index --add --cacheinfo \
          100644 "$REQ_BLOB_SHA" .io.v4rian.how-git/active-requirement 2>/dev/null; then
      echo "allocate-pool-branch: failed to stage active-requirement (off-grid); rolling back" >&2
      rollback_pair
      exit 1
    fi
    REQ_TREE_SHA=$(GIT_INDEX_FILE="$SCRATCH_INDEX" git write-tree 2>/dev/null || true)
    if [ -z "$REQ_TREE_SHA" ]; then
      echo "allocate-pool-branch: failed to write requirement tree (off-grid); rolling back" >&2
      rollback_pair
      exit 1
    fi

    REQUIREMENT_COMMIT_SHA=$(printf '%s' "$REQ_COMMIT_MESSAGE" \
      | git commit-tree "$REQ_TREE_SHA" -p "$DEV_SHA" 2>/dev/null || true)
    if [ -z "$REQUIREMENT_COMMIT_SHA" ]; then
      echo "allocate-pool-branch: failed to create requirement commit (off-grid); rolling back" >&2
      rollback_pair
      exit 1
    fi

    if ! git update-ref "refs/heads/$POOL_REF" "$REQUIREMENT_COMMIT_SHA" "$DEV_SHA" 2>/dev/null; then
      echo "allocate-pool-branch: failed to advance pool ref to requirement commit (off-grid); rolling back" >&2
      rollback_pair
      exit 1
    fi
  else
    py_json_str() {
      python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
    }

    REQ_BLOB_BODY=$(printf '{"content":%s,"encoding":"utf-8"}' \
      "$(printf '%s' "$REQUIREMENT" | py_json_str)")
    REQ_BLOB_RESP=$(api -X POST "https://api.github.com/repos/$REPO_FULL/git/blobs" --data "$REQ_BLOB_BODY")
    REQ_BLOB_SHA=$(printf '%s' "$REQ_BLOB_RESP" \
      | grep -oE '"sha":[[:space:]]*"[^"]+"' | head -1 \
      | sed -E 's|.*"sha":[[:space:]]*"([^"]+)".*|\1|')
    if [ -z "$REQ_BLOB_SHA" ]; then
      echo "allocate-pool-branch: failed to create blob for active-requirement; rolling back" >&2
      echo "$REQ_BLOB_RESP" >&2
      rollback_pair
      exit 1
    fi

    # Tree overlay: base_tree = dev tip commit's tree, add one entry.
    REQ_TREE_BODY=$(printf '{"base_tree":"%s","tree":[{"path":".io.v4rian.how-git/active-requirement","mode":"100644","type":"blob","sha":"%s"}]}' \
      "$DEV_SHA" "$REQ_BLOB_SHA")
    REQ_TREE_RESP=$(api -X POST "https://api.github.com/repos/$REPO_FULL/git/trees" --data "$REQ_TREE_BODY")
    REQ_TREE_SHA=$(printf '%s' "$REQ_TREE_RESP" \
      | grep -oE '"sha":[[:space:]]*"[^"]+"' | head -1 \
      | sed -E 's|.*"sha":[[:space:]]*"([^"]+)".*|\1|')
    if [ -z "$REQ_TREE_SHA" ]; then
      echo "allocate-pool-branch: failed to create tree for active-requirement; rolling back" >&2
      echo "$REQ_TREE_RESP" >&2
      rollback_pair
      exit 1
    fi

    REQ_COMMIT_BODY=$(printf '{"message":%s,"tree":"%s","parents":["%s"]}' \
      "$(printf '%s' "$REQ_COMMIT_MESSAGE" | py_json_str)" "$REQ_TREE_SHA" "$DEV_SHA")
    REQ_COMMIT_RESP=$(api -X POST "https://api.github.com/repos/$REPO_FULL/git/commits" --data "$REQ_COMMIT_BODY")
    REQUIREMENT_COMMIT_SHA=$(printf '%s' "$REQ_COMMIT_RESP" \
      | grep -oE '"sha":[[:space:]]*"[^"]+"' | head -1 \
      | sed -E 's|.*"sha":[[:space:]]*"([^"]+)".*|\1|')
    if [ -z "$REQUIREMENT_COMMIT_SHA" ]; then
      echo "allocate-pool-branch: failed to create commit for active-requirement; rolling back" >&2
      echo "$REQ_COMMIT_RESP" >&2
      rollback_pair
      exit 1
    fi

    # Fast-forward update the pool ref to the requirement commit. Safety
    # stays at the original dev tip.
    REQ_PATCH_BODY=$(printf '{"sha":"%s","force":false}' "$REQUIREMENT_COMMIT_SHA")
    REQ_PATCH_RESP=$(api -X PATCH "https://api.github.com/repos/$REPO_FULL/git/refs/heads/$POOL_REF" --data "$REQ_PATCH_BODY")
    if ! echo "$REQ_PATCH_RESP" | grep -q '"ref":[[:space:]]*"refs/heads/'; then
      echo "allocate-pool-branch: failed to advance pool ref to requirement commit; rolling back" >&2
      echo "$REQ_PATCH_RESP" >&2
      rollback_pair
      exit 1
    fi
  fi
  echo "  ✓ active-requirement committed at $REQUIREMENT_COMMIT_SHA" >&2
else
  echo "  · no requirement supplied; pool branch left at dev tip (legacy mode)" >&2
fi

# ---------------------------------------------------------------------------
# Emit success JSON. URLs point at GitHub in connected mode and at the
# local repo (file:// + ref fragment) in off-grid mode so callers can
# always render a clickable target even when the repo never reaches a
# GitHub remote.
# ---------------------------------------------------------------------------
if [ "$MODE" = "off-grid" ]; then
  BRANCH_URL="file://$(git rev-parse --show-toplevel)#$POOL_REF"
  SAFETY_URL="file://$(git rev-parse --show-toplevel)#$SAFETY_REF"
else
  BRANCH_URL="https://github.com/$REPO_FULL/tree/$POOL_REF"
  SAFETY_URL="https://github.com/$REPO_FULL/tree/$SAFETY_REF"
fi

cat <<JSON
{
  "status": "created",
  "branch_name": "$POOL_REF",
  "safety_name": "$SAFETY_REF",
  "branch_url": "$BRANCH_URL",
  "safety_url": "$SAFETY_URL",
  "sha": "$DEV_SHA",
  "requirement_commit_sha": "$REQUIREMENT_COMMIT_SHA",
  "has_requirement": $([ -n "$REQUIREMENT_COMMIT_SHA" ] && echo "true" || echo "false"),
  "kind": "$KIND",
  "jira_key": "$JIRA",
  "mode": "$MODE",
  "major_prefix": "$MAJOR_PREFIX"
}
JSON
