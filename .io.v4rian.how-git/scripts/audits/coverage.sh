#!/usr/bin/env bash
# audits/coverage.sh - deterministic test-coverage verification for the
# pushed branch. Invoked by .github/workflows/audit-pushed-branch.yml as
# one of the three required status checks on PRs to dev.
#
# Consumer projects override this script with their actual coverage
# recipe (jest --coverage, vitest run --coverage, the project's own
# fenrir-style harness, etc.). The template ships a placeholder that
# defers to the consumer when build artifacts are detected and otherwise
# treats the run as a no-op.
#
# Contract:
#   - Exit 0 when coverage meets the project's threshold (or when no
#     testable code is present in this repo shape).
#   - Exit non-zero when the configured threshold is not met, with the
#     failing report surfaced in the workflow log.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
echo ">> coverage audit running in $REPO_ROOT"

if [ -f "$REPO_ROOT/package.json" ]; then
  # Honor a project's own coverage script if one is wired up.
  if grep -q '"test:coverage"' "$REPO_ROOT/package.json" 2>/dev/null; then
    echo ">> detected npm test:coverage script; delegating"
    cd "$REPO_ROOT"
    npm install --silent --no-audit --no-fund
    npm run test:coverage
    echo "PASS coverage (project script reported success)"
    exit 0
  fi
  echo ">> Node project without test:coverage script; consumer must override audits/coverage.sh"
  exit 2
fi

if [ -f "$REPO_ROOT/CMakeLists.txt" ]; then
  echo ">> detected Qt or CMake project; consumer must override audits/coverage.sh"
  exit 2
fi

# Framework-source-only fallback: the how-git framework's own test suites
# live at .io.v4rian.how-git/framework-tests/ on the framework source repo and serve as the
# self-coverage proxy when no consumer project type is detected. Gated on
# the FRAMEWORK_REPO marker so a consumer with an empty repo (just past
# install, no project markers yet) does NOT silently run the framework's
# internal tests as their own coverage signal — that would leak
# framework-internal behavior into consumer CI.
MARKER="$REPO_ROOT/.io.v4rian.how-git/FRAMEWORK_REPO"
if [ -f "$MARKER" ] && [ -f "$REPO_ROOT/.io.v4rian.how-git/framework-tests/test-lifecycle.sh" ]; then
  echo ">> framework source repo detected; running .io.v4rian.how-git/framework-tests/test-lifecycle.sh as self-coverage proxy"
  LIFECYCLE_TEST_MODE=1 bash "$REPO_ROOT/.io.v4rian.how-git/framework-tests/test-lifecycle.sh"
  if [ -f "$REPO_ROOT/.io.v4rian.how-git/framework-tests/test-hooks.sh" ]; then
    echo ">> framework source repo: running .io.v4rian.how-git/framework-tests/test-hooks.sh"
    bash "$REPO_ROOT/.io.v4rian.how-git/framework-tests/test-hooks.sh"
  fi
  echo "PASS coverage (framework self-tests green)"
  exit 0
fi

# Consumer with no project type detected: do not invent coverage; exit 2
# with a clear message so the operator overrides audits/coverage.sh with
# their project's actual recipe.
echo ">> no project type detected (no package.json, no CMakeLists.txt)"
echo "   and this repo is not the framework source (FRAMEWORK_REPO marker absent)."
echo "   Consumers must provide an audits/coverage.sh override that runs their"
echo "   project's coverage recipe."
exit 2
