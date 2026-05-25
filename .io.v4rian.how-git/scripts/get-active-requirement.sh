#!/usr/bin/env bash
# get-active-requirement.sh — fetch the active-requirement document for a
# pool/* branch.
#
# Auditors and the smart-commit tool call this script when they invoke
# claude on behalf of work happening on a pool branch. The output is the
# verbatim requirement text the allocator stamped on the branch at
# creation time. Claude reads that text and treats it as the canonical
# intent for the branch.
#
# Two equivalent sources for the same text — the script prefers the
# tracked file (cheap, no git plumbing) and falls back to the initial
# [REQ] commit body when the file is absent (e.g. older pool branches
# that predate this lifecycle step):
#
#   1. .io.v4rian.how-git/active-requirement file at the branch tip
#      (the tracked overlay written by the allocator).
#
#   2. Body of the first commit on the pool branch reachable from the
#      branch tip but not from origin/dev. The allocator's initial
#      [REQ] commit IS that first commit by construction.
#
# Behaviour:
#
#   - Prints the requirement text on stdout, no trailing decoration,
#     no banners. Suitable for piping straight into a claude prompt
#     template.
#   - Exits 0 when a requirement was found.
#   - Exits 0 with empty stdout when the branch has no requirement
#     attached (legacy branches that predate this step, or branches
#     allocated without --requirement). The caller decides whether
#     to proceed without context or to surface the absence.
#   - Exits 2 only on a usage error (missing/invalid branch arg).
#
# Usage:
#   .io.v4rian.how-git/scripts/get-active-requirement.sh <pool-branch>
#
# Examples:
#   .io.v4rian.how-git/scripts/get-active-requirement.sh pool/n51.feature.PROJ-7-parser
#   .io.v4rian.how-git/scripts/get-active-requirement.sh HEAD
#   REQ=$(.io.v4rian.how-git/scripts/get-active-requirement.sh "$BRANCH")
#   claude -p "Active requirement: $REQ"$'\n\n'"...rest of prompt..."

set -uo pipefail

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
  echo "get-active-requirement: missing branch argument" >&2
  echo "usage: $(basename "$0") <pool-branch|HEAD|sha>" >&2
  exit 2
fi

BRANCH="$1"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  echo "get-active-requirement: not inside a git repo" >&2
  exit 2
fi

cd "$REPO_ROOT"

REQ_PATH=".io.v4rian.how-git/active-requirement"

# ---------------------------------------------------------------------------
# Source 1: tracked file on the branch (cheap path)
# ---------------------------------------------------------------------------
# `git show <branch>:<path>` is the most portable way to read a tracked
# file at a ref without checking the branch out. Silently swallow stderr;
# absence of the file is a normal outcome, not an error.
FILE_CONTENT=$(git show "${BRANCH}:${REQ_PATH}" 2>/dev/null || true)
if [ -n "$FILE_CONTENT" ]; then
  printf '%s' "$FILE_CONTENT"
  exit 0
fi

# ---------------------------------------------------------------------------
# Source 2: initial [REQ] commit body (fallback)
# ---------------------------------------------------------------------------
# Walk the branch's history back to the first commit reachable from the
# branch tip but not reachable from origin/dev (or local dev). That
# commit is the allocator's initial [REQ] commit by construction. Skip
# any [MERGE] commits that may appear if the branch has been merged
# back-and-forth.
BASE_REF=""
for candidate in origin/dev dev; do
  if git rev-parse --verify "$candidate" >/dev/null 2>&1; then
    BASE_REF="$candidate"
    break
  fi
done

if [ -n "$BASE_REF" ]; then
  FIRST_REQ_SHA=""
  while read -r sha; do
    [ -z "$sha" ] && continue
    subj=$(git log -1 --format=%s "$sha" 2>/dev/null || true)
    if [ "${subj#\[REQ\] active-requirement:}" != "$subj" ]; then
      FIRST_REQ_SHA="$sha"
      break
    fi
  done < <(git rev-list --reverse "$BRANCH" "^$BASE_REF" 2>/dev/null || true)

  if [ -n "$FIRST_REQ_SHA" ]; then
    # Print the commit BODY only (skip subject + blank separator). The
    # body is the requirement text verbatim per the allocator's
    # composition rule.
    git log -1 --format='%b' "$FIRST_REQ_SHA"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# No requirement available — exit 0 with empty stdout. The caller is
# expected to handle the empty case (proceed without context OR refuse).
# ---------------------------------------------------------------------------
exit 0
