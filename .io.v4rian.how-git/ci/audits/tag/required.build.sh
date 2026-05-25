#!/usr/bin/env bash
# required.build.sh - tag sys-layer audit
#
# Fires on every v* tag push and produces artifact(s) under
# build/artifacts/. Distribution (GitHub Release create, prerelease
# flag, public promotion) is the next bundle's responsibility; this
# audit STOPS once build.sh has placed its output at the contract
# path. Same code = same version = same artifact, built once at the
# dev tag and reused at main promotion without rebuild. This is the
# sys layer hook that replaces the prior
# .github/workflows/build-on-tag.yml.
#
# Delegates to the existing retry-wrapped recipe:
#   .io.v4rian.how-git/scripts/workflows/build-retry.sh
#
# The build-retry wrapper invokes scripts/build.sh inside the same
# eight-attempt exponential-backoff retry envelope the legacy workflow
# used and writes the final outcome to GITHUB_STEP_SUMMARY.
#
# Environment expectations (set by ci-dispatch.yml's matrix runner):
#   CI_TRIGGER=tag
#   CI_LAYER=sys
#   CI_KIND=audits
#   CI_CHECK_NAME=required.build
#   GITHUB_TOKEN with contents:read (read-only build; distribution is separate)
#
# Idempotency: build.sh's $BUILD_IDEMPOTENCY_CHECK=1 mode runs before
# the build body so a re-run against an already-built tag short-circuits.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
RETRY="$REPO_ROOT/.io.v4rian.how-git/scripts/workflows/build-retry.sh"

if [ ! -x "$RETRY" ]; then
  echo "X required.build: build-retry.sh missing or not executable at $RETRY" >&2
  exit 1
fi

exec bash "$RETRY"
