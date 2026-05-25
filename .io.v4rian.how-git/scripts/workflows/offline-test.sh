#!/usr/bin/env bash
# offline-test.sh — body of the offline-test workflow's lifecycle job.
#
# Runs the framework's own internal test suites (lifecycle + hooks) when
# this repo is the framework source (detected via the FRAMEWORK_REPO
# marker file). On a consumer repo that has adopted the framework, the
# marker is absent and the suites SHOULD NOT run — those tests verify
# the framework's own machinery, not the consumer's project.
#
# The marker file gate is the single source of truth for "is this the
# framework's home repo?" Read it here, check it in audit scripts that
# fall through to framework-internal recipes, drop it via bootstrap-ci
# consumer-cleanup, restore it on the framework source. No other source
# of truth, no environment variable, no remote-URL guess.
#
# Exit codes:
#   0  marker absent (consumer mode) → skip is clean
#   0  marker present + both suites green
#   non-zero  marker present + any suite red
#
# Environment:
#   LIFECYCLE_TEST_MODE  set to 1 by the workflow; passed through to the
#                        test suites so claude_skill_run mocks engage.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MARKER="$REPO_ROOT/.io.v4rian.how-git/FRAMEWORK_REPO"

if [ ! -f "$MARKER" ]; then
  echo "=> offline-test: FRAMEWORK_REPO marker not present; this repo consumes the framework but does not host its tests. Skipping."
  exit 0
fi

echo "=> offline-test: FRAMEWORK_REPO marker present; running framework-internal suites"

echo "=> running lifecycle suite"
bash "$REPO_ROOT/.io.v4rian.how-git/framework-tests/test-lifecycle.sh"
lifecycle_rc=$?

echo "=> running hooks suite"
bash "$REPO_ROOT/.io.v4rian.how-git/framework-tests/test-hooks.sh"
hooks_rc=$?

if [ "$lifecycle_rc" -ne 0 ] || [ "$hooks_rc" -ne 0 ]; then
  echo "=> offline-test: lifecycle_rc=$lifecycle_rc hooks_rc=$hooks_rc; one or both suites failed"
  exit 1
fi

echo "=> offline-test: both framework suites green"
exit 0
