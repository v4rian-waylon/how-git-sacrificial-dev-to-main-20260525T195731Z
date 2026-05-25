#!/usr/bin/env bash
# archive-pool-branch.sh — rename a pool/* branch into vault/vYYYY.MAIN/<suffix>
# on origin (with a flat vault/<suffix> fallback for legacy/test repos).
#
# Idempotent. Used by claim-dev-merge.sh after a successful merge so the
# pool branch never gets DELETED — its content is preserved under
# vault/vYYYY.MAIN/<suffix>, out of sight but recoverable forever. Pool
# branches represent historical work-in-progress snapshots and per the
# v4rian discipline must never be lost.
#
# The vYYYY.MAIN/ prefix groups all vaults that belong to the same major
# release cycle (year + main-counter), so a glance at refs/heads/vault/
# reveals "which nN branches landed in this release cycle." The prefix is
# derived from bin/version --seal at archive time by trimming the trailing
# .DEV segment: v2026.0.39 → v2026.0. If bin/version is unreachable or
# returns an unparseable value, the script falls back to a flat
# vault/<suffix> path (legacy + offline-test scenarios).
#
# Behavior:
#   - If a prefixed vault/<MAJOR>/<suffix> OR a legacy flat vault/<suffix>
#     already exists on origin, ensure pool/<suffix> is removed and exit
#     successfully (re-runs are no-ops; the legacy match prevents this
#     script from duplicating a vault that an older claim already made).
#   - If pool/<suffix> does not exist on origin, nothing to archive; exit 0.
#   - Otherwise: push the pool's SHA to the prefixed vault path, then
#     delete the pool/<suffix> ref on origin.
#
# This script NEVER touches branches that don't start with `pool/`.
#
# Usage:
#   archive-pool-branch.sh pool/nN.kind.short_name
#   archive-pool-branch.sh --dry-run pool/nN.kind.short_name
#   archive-pool-branch.sh -h | --help

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  echo "✗ archive-pool-branch.sh: not inside a git repo" >&2
  exit 2
fi
cd "$REPO_ROOT"

DRY_RUN=false
POOL_BRANCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)
      if [ -z "$POOL_BRANCH" ]; then
        POOL_BRANCH="$1"; shift
      else
        echo "✗ extra argument: $1" >&2; exit 2
      fi
      ;;
  esac
done

if [ -z "$POOL_BRANCH" ]; then
  echo "usage: archive-pool-branch.sh [--dry-run] <pool/nN.kind.short_name>" >&2
  exit 2
fi
if [[ "$POOL_BRANCH" != pool/* ]]; then
  echo "✗ branch '$POOL_BRANCH' does not start with pool/" >&2
  exit 2
fi

SUFFIX="${POOL_BRANCH#pool/}"

# Pool inputs come in two shapes since allocator allocation gained the major
# prefix: a flat suffix (nN.kind.short_name) for legacy branches and a
# prefixed suffix (vYYYY.MAIN/nN.kind.short_name) for branches allocated
# after the prefix landed. Detect which shape we have, then derive the
# canonical and legacy vault paths consistently for both cases.
INPUT_MAJOR_PREFIX=""
BARE_SUFFIX="$SUFFIX"
if [[ "$SUFFIX" =~ ^(v[0-9]+\.[0-9]+)/(.+)$ ]]; then
  INPUT_MAJOR_PREFIX="${BASH_REMATCH[1]}"
  BARE_SUFFIX="${BASH_REMATCH[2]}"
fi

LEGACY_VAULT_BRANCH="vault/$BARE_SUFFIX"

# Compute the vYYYY.MAIN major prefix. A prefixed input wins (the pool ref
# already carries its release-line classification verbatim); otherwise we
# fall back to bin/version --seal (trim the trailing .DEV segment via
# parameter expansion). Empty seal or anything that doesn't match vN.N.N
# falls back to the legacy flat vault layout so offline tests + repos
# pre-prefix-era still archive cleanly.
VERSION_BIN="$REPO_ROOT/.io.v4rian.how-git/bin/version"
MAJOR_PREFIX=""
if [ -n "$INPUT_MAJOR_PREFIX" ]; then
  MAJOR_PREFIX="$INPUT_MAJOR_PREFIX"
elif [ -x "$VERSION_BIN" ]; then
  SEAL=$("$VERSION_BIN" --seal 2>/dev/null | tr -d '\r\n')
  if [[ "$SEAL" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    MAJOR_PREFIX="${SEAL%.*}"
  fi
fi

if [ -n "$MAJOR_PREFIX" ]; then
  VAULT_BRANCH="vault/$MAJOR_PREFIX/$BARE_SUFFIX"
else
  VAULT_BRANCH="$LEGACY_VAULT_BRANCH"
fi

# Fetch latest refs so the existence checks below match origin truth.
# Fetch both the new-prefix path (in case re-running on a partially-vaulted
# branch) and the legacy flat path (so the legacy-match guard fires when an
# older claim already vaulted this suffix under the old scheme).
git fetch -q origin "+refs/heads/$POOL_BRANCH:refs/remotes/origin/$POOL_BRANCH" \
                    "+refs/heads/$VAULT_BRANCH:refs/remotes/origin/$VAULT_BRANCH" \
                    "+refs/heads/$LEGACY_VAULT_BRANCH:refs/remotes/origin/$LEGACY_VAULT_BRANCH" \
                    2>/dev/null || true

vault_exists=false
legacy_vault_exists=false
pool_exists=false
git ls-remote --heads origin "$VAULT_BRANCH"        2>/dev/null | grep -q "$VAULT_BRANCH"        && vault_exists=true
git ls-remote --heads origin "$LEGACY_VAULT_BRANCH" 2>/dev/null | grep -q "$LEGACY_VAULT_BRANCH" && legacy_vault_exists=true
git ls-remote --heads origin "$POOL_BRANCH"         2>/dev/null | grep -q "$POOL_BRANCH"         && pool_exists=true

# Legacy-match guard: if a legacy flat vault already exists for this suffix
# (and we computed a different prefixed path above), treat the legacy as
# the canonical vault for this suffix so re-runs do not double-vault.
EFFECTIVE_VAULT="$VAULT_BRANCH"
if [ "$legacy_vault_exists" = "true" ] && [ "$LEGACY_VAULT_BRANCH" != "$VAULT_BRANCH" ]; then
  echo "  · legacy flat $LEGACY_VAULT_BRANCH already in place; treating as the canonical vault for this suffix"
  EFFECTIVE_VAULT="$LEGACY_VAULT_BRANCH"
  vault_exists=true
fi

if $vault_exists && ! $pool_exists; then
  echo "  · $EFFECTIVE_VAULT already in place; $POOL_BRANCH already removed (idempotent no-op)"
  exit 0
fi

if $vault_exists && $pool_exists; then
  echo "  · $EFFECTIVE_VAULT already in place; pruning stale $POOL_BRANCH"
  if $DRY_RUN; then
    echo "  [dry-run] would delete $POOL_BRANCH on origin"
  else
    git push origin --delete "$POOL_BRANCH"
    echo "  ✓ deleted $POOL_BRANCH"
  fi
  exit 0
fi

if ! $pool_exists; then
  echo "  · $POOL_BRANCH not on origin and $EFFECTIVE_VAULT not on origin; nothing to archive"
  exit 0
fi

POOL_SHA=$(git ls-remote --heads origin "$POOL_BRANCH" | awk '{print $1}')
echo "→ archiving $POOL_BRANCH ($POOL_SHA) → $VAULT_BRANCH"

if $DRY_RUN; then
  echo "  [dry-run] would push $POOL_SHA to refs/heads/$VAULT_BRANCH on origin"
  echo "  [dry-run] would then delete $POOL_BRANCH on origin"
  exit 0
fi

git push origin "$POOL_SHA:refs/heads/$VAULT_BRANCH"
git push origin --delete "$POOL_BRANCH"
echo "  ✓ archived: $POOL_BRANCH → $VAULT_BRANCH (content preserved at $POOL_SHA)"
