#!/usr/bin/env bash
# test/test-hooks.sh — exercise the v4rian local hooks and version math.
# Run directly: bash framework-tests/test-hooks.sh
#
# Exit 0 if all cases pass, 1 if any fail.

set -uo pipefail

# Run from anywhere; resolve repo root from this script's location.
# framework-tests/ moved out of .io.v4rian.how-git/test/ in pool/n45, so
# $SCRIPT_DIR/.. is now the actual repo root. Tests in this file use
# relative paths like ./bin/version that only resolve from inside the
# namespace dir, so cd there.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT/.io.v4rian.how-git"

PASS=0
FAIL=0
FAIL_CASES=()

run() {
  local desc="$1"
  local expected="$2"   # pass or fail
  local cmd="$3"

  if bash -c "$cmd" >/dev/null 2>&1; then
    actual=pass
  else
    actual=fail
  fi

  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ %s\n" "$desc"
  else
    FAIL=$((FAIL + 1))
    FAIL_CASES+=("$desc (expected $expected, got $actual)")
    printf "  ✗ %s (expected %s, got %s)\n" "$desc" "$expected" "$actual"
  fi
}

# Branch-name regex test harness — runs the pre-push pattern against a candidate
# without actually invoking git push. The pattern accepts both the legacy flat
# layout (pool/nN.kind.short) and the vYYYY.MAIN/ prefixed layout
# (pool/vYYYY.MAIN/nN.kind.short) introduced when active pool/safety
# allocation gained release-line classification.
check_branch() {
  local b="$1"
  local pattern='^(pool|safety)/(v[0-9]{4}\.[0-9]+/)?n[0-9]+\.(feature|fix|r&d|refactor|reconcile)\.(sprint[0-9]+-)?([A-Z]+-[0-9]+-)?[a-z0-9][a-z0-9-]*$'
  [[ "$b" =~ ^(main|dev)$ ]] && return 0
  [[ "$b" =~ $pattern ]] && return 0
  return 1
}
export -f check_branch

echo "=== Branch name validation ==="
echo "--- Should ACCEPT (legacy flat layout) ---"
run "main"                                                "pass" "check_branch 'main'"
run "dev"                                                 "pass" "check_branch 'dev'"
run "pool/n3.feature.parser-rewrite"                       "pass" "check_branch 'pool/n3.feature.parser-rewrite'"
run "pool/n3.feature.sprint4-parser-rewrite"               "pass" "check_branch 'pool/n3.feature.sprint4-parser-rewrite'"
run "pool/n7.fix.PROJ-123-token-leak"                      "pass" "check_branch 'pool/n7.fix.PROJ-123-token-leak'"
run "pool/n12.r&d.sprint5-PROJ-456-embedding-cache"        "pass" "check_branch 'pool/n12.r&d.sprint5-PROJ-456-embedding-cache'"
run "pool/n4.refactor.config-module"                       "pass" "check_branch 'pool/n4.refactor.config-module'"
run "pool/n5.reconcile.vault-archive-pool-on-merge"        "pass" "check_branch 'pool/n5.reconcile.vault-archive-pool-on-merge'"
run "safety/n3.feature.parser-rewrite"                     "pass" "check_branch 'safety/n3.feature.parser-rewrite'"
run "safety/n5.reconcile.vault-archive-pool-on-merge"      "pass" "check_branch 'safety/n5.reconcile.vault-archive-pool-on-merge'"
run "pool/n99.feature.a"                                   "pass" "check_branch 'pool/n99.feature.a'"
run "pool/n0.feature.x-y-z"                                "pass" "check_branch 'pool/n0.feature.x-y-z'"

echo "--- Should ACCEPT (vYYYY.MAIN/ prefixed layout) ---"
run "pool/v2026.0/n3.feature.parser-rewrite"               "pass" "check_branch 'pool/v2026.0/n3.feature.parser-rewrite'"
run "pool/v2026.0/n3.feature.sprint4-parser-rewrite"       "pass" "check_branch 'pool/v2026.0/n3.feature.sprint4-parser-rewrite'"
run "pool/v2026.0/n7.fix.PROJ-123-token-leak"              "pass" "check_branch 'pool/v2026.0/n7.fix.PROJ-123-token-leak'"
run "pool/v2026.12/n12.r&d.sprint5-PROJ-456-embedding-cache" "pass" "check_branch 'pool/v2026.12/n12.r&d.sprint5-PROJ-456-embedding-cache'"
run "pool/v2026.0/n4.refactor.config-module"               "pass" "check_branch 'pool/v2026.0/n4.refactor.config-module'"
run "pool/v2026.0/n5.reconcile.vault-archive-pool-on-merge" "pass" "check_branch 'pool/v2026.0/n5.reconcile.vault-archive-pool-on-merge'"
run "safety/v2026.0/n3.feature.parser-rewrite"             "pass" "check_branch 'safety/v2026.0/n3.feature.parser-rewrite'"
run "safety/v2026.0/n5.reconcile.vault-archive-pool-on-merge" "pass" "check_branch 'safety/v2026.0/n5.reconcile.vault-archive-pool-on-merge'"
run "pool/v2027.3/n99.feature.a"                           "pass" "check_branch 'pool/v2027.3/n99.feature.a'"
run "pool/v2026.0/n0.feature.x-y-z"                        "pass" "check_branch 'pool/v2026.0/n0.feature.x-y-z'"

echo "--- Should REJECT ---"
run "feature/foo (missing scope)"                         "fail" "check_branch 'feature/foo'"
run "pool/foo (no nN)"                                     "fail" "check_branch 'pool/foo'"
run "pool/n3.feature (no short_name)"                      "fail" "check_branch 'pool/n3.feature'"
run "pool/n3.unknown.foo (bad kind)"                       "fail" "check_branch 'pool/n3.unknown.foo'"
run "pool/N3.feature.foo (uppercase N)"                    "fail" "check_branch 'pool/N3.feature.foo'"
run "pool/n3.feature.Foo (uppercase in short_name)"        "fail" "check_branch 'pool/n3.feature.Foo'"
run "pool/n.feature.foo (no digit)"                        "fail" "check_branch 'pool/n.feature.foo'"
run "pool/3.feature.foo (no n prefix)"                     "fail" "check_branch 'pool/3.feature.foo'"
run "random/n3.feature.foo (bad scope)"                   "fail" "check_branch 'random/n3.feature.foo'"
run "pool/n3.feature.-leading_dash"                        "fail" "check_branch 'pool/n3.feature.-leading_dash'"
run "pool/n3.feature.parser_rewrite (underscore)"          "fail" "check_branch 'pool/n3.feature.parser_rewrite'"
run "pool/n3.feature.sprint4-parser_rewrite (underscore in short_name)" "fail" "check_branch 'pool/n3.feature.sprint4-parser_rewrite'"
run "pool/n7.fix.PROJ-123-token_leak (underscore)"         "fail" "check_branch 'pool/n7.fix.PROJ-123-token_leak'"
run "pool/n12.r&d.sprint5-PROJ-456-embedding_cache (underscore)" "fail" "check_branch 'pool/n12.r&d.sprint5-PROJ-456-embedding_cache'"
run "pool/n4.refactor.config_module (underscore)"          "fail" "check_branch 'pool/n4.refactor.config_module'"
run "pool/n5.reconcile.vault_archive_pool_on_merge (underscores)" "fail" "check_branch 'pool/n5.reconcile.vault_archive_pool_on_merge'"
run "safety/n3.feature.parser_rewrite (underscore)"        "fail" "check_branch 'safety/n3.feature.parser_rewrite'"
run "safety/n5.reconcile.vault_archive_pool_on_merge (underscores)" "fail" "check_branch 'safety/n5.reconcile.vault_archive_pool_on_merge'"
run "pool/v2026/n3.feature.foo (single-segment prefix)"    "fail" "check_branch 'pool/v2026/n3.feature.foo'"
run "pool/v2026.0.0/n3.feature.foo (3-segment prefix)"     "fail" "check_branch 'pool/v2026.0.0/n3.feature.foo'"
run "pool/v2026.0/N3.feature.foo (uppercase N under prefix)" "fail" "check_branch 'pool/v2026.0/N3.feature.foo'"
run "pool/v2026.0/n3.unknown.foo (bad kind under prefix)"  "fail" "check_branch 'pool/v2026.0/n3.unknown.foo'"
run "safety/v2026/n3.feature.foo (single-segment prefix)"  "fail" "check_branch 'safety/v2026/n3.feature.foo'"

echo ""
echo "=== Version bin (bump.sh + init-version.sh deleted; bin/version is canonical) ==="

# The 2 dead scripts MUST be gone (replaced by bin/version)
run "bump.sh deleted (dead code under tags-as-seal model)" \
    "fail" \
    "test -e ./scripts/bump.sh"

run "init-version.sh deleted (dead code under tags-as-seal model)" \
    "fail" \
    "test -e ./scripts/init-version.sh"

# bin/version produces a 3-segment vYEAR.SERIES.DEV output
run "bin/version --seal produces vYEAR.SERIES.DEV" \
    "pass" \
    "./bin/version --seal | grep -qE '^v[0-9]{4}\.[0-9]+\.[0-9]+$'"

run "bin/version (default identifier) produces vYEAR.SERIES.DEV-sha.build" \
    "pass" \
    "./bin/version | grep -qE '^v[0-9]{4}\.[0-9]+\.[0-9]+-[0-9a-f]+\.[0-9]+$'"

run "bin/version --release-tag produces vYEAR.SERIES.DEV" \
    "pass" \
    "./bin/version --release-tag | grep -qE '^v[0-9]{4}\.[0-9]+\.[0-9]+$'"

echo ""
echo "=== Summary ==="
echo "  $PASS passed, $FAIL failed"

if (( FAIL > 0 )); then
  echo ""
  echo "Failures:"
  for c in "${FAIL_CASES[@]}"; do
    echo "  - $c"
  done
  exit 1
fi

exit 0
