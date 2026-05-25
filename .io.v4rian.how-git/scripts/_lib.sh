#!/usr/bin/env bash
# _lib.sh — shared helpers for in-repo scripts AND for the shipped githooks.
#
# Sourced (not executed). Provides:
#
#   ensure_hooks_path     — Idempotently sets `core.hooksPath` to
#                           .io.v4rian.how-git/githooks so the shipped
#                           hooks become active. Also installs the
#                           local `git v4r openPR` alias.
#                           Called by every in-repo script at startup.
#
#   ensure_repo_alias     — Idempotently installs `git v4r` as a local
#                           alias that dispatches to in-repo scripts:
#                             git v4r openPR  → scripts/open-pr.sh
#                             git v4r heal    → scripts/heal.sh
#                             git v4r verify  → scripts/verify-template.sh
#                           (renamed from the legacy `git repo` alias which
#                           collides with modern git's `repo` builtin)
#
#   claude_skill_run      — Runs a Claude skill via the `claude` CLI if
#                           installed, otherwise gracefully skips (logs
#                           a note but does not block). Returns 0 if
#                           audit passes or Claude unavailable; non-zero
#                           only on explicit AUDIT_FAIL from the skill.
#
# Source via:
#   SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
#   . "$SCRIPT_DIR/_lib.sh"

# Idempotent core.hooksPath self-install. Silent unless a change is made.
ensure_hooks_path() {
  local expected="${HOOKS_PATH_OVERRIDE:-.io.v4rian.how-git/githooks}"
  local current
  current=$(git config core.hooksPath 2>/dev/null || true)
  if [ "$current" != "$expected" ]; then
    git config core.hooksPath "$expected"
    echo "→ activated git hooks (core.hooksPath = $expected)"
  fi
  ensure_repo_alias
}

# Idempotent local git alias install. `git v4r <subcmd> [args...]`
# dispatches to in-repo scripts so users never have to type the long
# bash invocation. Subcommands: openPR, heal, verify, claim-dev, claim-main.
#
# The alias is named v4r (not repo) because modern git ships a builtin
# `git repo` subcommand that preempts user aliases of the same name.
# Also removes any stale alias.repo from a prior template revision so
# upgrades cleanly migrate.
ensure_repo_alias() {
  # Body is POSIX sh: git executes "!" aliases via /bin/sh which is dash on
  # Linux (bash 3.2+ on macOS). The previous ${@:2} bash-only slice was a
  # source of dash incompatibility. shift + "$@" works in dash, bash,
  # zsh, ksh, ash.
  local expected_alias='!f() { subcmd="$1"; shift; case "$subcmd" in openPR) bash "$(git rev-parse --show-toplevel)/.io.v4rian.how-git/scripts/open-pr.sh" "$@";; heal) bash "$(git rev-parse --show-toplevel)/.io.v4rian.how-git/scripts/heal.sh" "$@";; verify|verify-template) bash "$(git rev-parse --show-toplevel)/.io.v4rian.how-git/scripts/verify-template.sh" "$@";; claim-dev|claim-dev-merge) bash "$(git rev-parse --show-toplevel)/.io.v4rian.how-git/scripts/claim-dev-merge.sh" "$@";; claim-main|claim-main-release) bash "$(git rev-parse --show-toplevel)/.io.v4rian.how-git/scripts/claim-main-release.sh" "$@";; *) echo "git v4r <openPR|heal|verify|claim-dev|claim-main> [args]" >&2; exit 2;; esac; }; f'
  local current
  current=$(git config alias.v4r 2>/dev/null || true)
  if [ "$current" != "$expected_alias" ]; then
    git config alias.v4r "$expected_alias"
    echo "→ installed git alias: 'git v4r <openPR|heal|verify|claim-dev|claim-main>'"
  fi
  # Migration: clear any stale alias.repo from a prior template revision.
  if git config alias.repo >/dev/null 2>&1; then
    git config --unset alias.repo
  fi
}

# Run an in-repo Claude skill via the `claude` CLI. Skills live at
# .io.v4rian.how-git/skills/<skill>/SKILL.md so they ride with the repo
# and can be updated per-project without a global Claude reinstall.
#
# Auditing is OPTIONAL — if `claude` is not installed (i.e. the consumer
# isn't using Claude Code), this function logs a note and returns 0 so
# the hook doesn't block on a missing-dependency basis. When `claude`
# IS installed, the skill output is expected to contain `AUDIT_PASS`
# (success) or `AUDIT_FAIL: <reason>` (failure); failure returns
# non-zero which the calling hook should propagate to block the git op.
#
# Usage: claude_skill_run <skill-name> <one-line context for the audit>
claude_skill_run() {
  local skill="$1"
  local context="$2"
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  local skill_path="$repo_root/.io.v4rian.how-git/skills/$skill/SKILL.md"

  # Test-mode escape hatch: tests set LIFECYCLE_TEST_MODE=1 to bypass
  # the real (slow + network-bound) claude invocation and just log the
  # would-be call. Hook wiring is verified separately by static
  # inspection in test-lifecycle.sh.
  if [ "${LIFECYCLE_TEST_MODE:-}" = "1" ]; then
    echo "  · [test-mode] would invoke claude $skill audit (skill_path=$skill_path)" >&2
    return 0
  fi

  if ! command -v claude >/dev/null 2>&1; then
    echo "  · claude CLI not installed; skipping $skill audit (install Claude Code to enable)" >&2
    return 0
  fi
  if [ ! -f "$skill_path" ]; then
    echo "  · skill file $skill_path not found; skipping $skill audit" >&2
    return 0
  fi

  local prompt
  prompt="Audit the current git state against the rules in $skill_path. Context: $context. After auditing, output exactly 'AUDIT_PASS' on a line by itself if the audit passes, or 'AUDIT_FAIL: <reason>' if it fails. Be terse."
  echo "  → running $skill audit via claude (this may take a few seconds)" >&2
  local output
  output=$(claude -p "$prompt" </dev/null 2>&1 || true)
  if echo "$output" | grep -q '^AUDIT_FAIL'; then
    echo "✗ $skill: $(echo "$output" | grep '^AUDIT_FAIL' | head -1)" >&2
    return 1
  fi
  echo "  ✓ $skill passed" >&2
  return 0
}

# v4rian mode accessors. The mode lives in .io.v4rian.how-git/MODE
# and is one of: connected, off-grid. See bin/set-mode for details.

get_mode() {
  local repo_root mode_file
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  mode_file="$repo_root/.io.v4rian.how-git/MODE"
  if [ ! -f "$mode_file" ]; then
    echo "connected"
    return 0
  fi
  tr -d '\n' < "$mode_file"
}

assert_mode() {
  local expected actual
  expected="$1"
  actual=$(get_mode)
  if [ "$actual" != "$expected" ]; then
    echo "X this tool requires ${expected} mode; current mode is ${actual}" >&2
    case "$expected" in
      connected) echo "  switch with: bin/set-mode connected" >&2 ;;
      off-grid)  echo "  switch with: bin/set-mode off-grid"  >&2 ;;
    esac
    return 1
  fi
  return 0
}
