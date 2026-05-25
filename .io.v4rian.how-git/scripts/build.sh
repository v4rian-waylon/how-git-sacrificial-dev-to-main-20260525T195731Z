#!/usr/bin/env bash
# build.sh - canonical single-source build script.
#
# Called by .github/workflows/build-on-tag.yml on every v* tag push and
# on workflow_dispatch admin re-build. Consumer projects override this
# file in their fork with their actual build commands (npm run build,
# cmake --build, xcodebuild, cargo, etc.). The template ships a
# detector-based placeholder that DTRT for the common cases and prints
# a clear "consumer must override" banner for everything else.
#
# Output contract:
#   Place every artifact under ./build/artifacts/ at the repo root.
#   Files there are picked up by the build-on-tag workflow's upload step
#   and consumed unchanged by the (later) distribution bundle, which
#   attaches them as GitHub Release assets. The directory IS the API
#   between build and distribution. Do not write outside it; do not
#   nest a per-tag subdirectory (the tag is already the workflow run
#   label).
#
# Environment from the workflow:
#   $TAG                       tag name (e.g. v2026.0.7)
#   $BUILD_IDEMPOTENCY_CHECK   when set to 1, exit 0 if output for $TAG
#                              is already present at the contract path,
#                              non-zero otherwise. NO BUILDING happens in
#                              this mode (a pure presence probe).
#
# Exit codes:
#   0  success (built, or in idempotency-check mode found existing output)
#   non-zero  build failed, or idempotency-check found no existing output

set -euo pipefail

ARTIFACT_DIR="build/artifacts"
TAG="${TAG:-untagged}"

# -----------------------------------------------------------------------
# Idempotency probe: workflow asks first whether output is already there.
# Decision rule: artifact dir exists, contains at least one file, and at
# least one filename mentions $TAG. Consumers overriding this script can
# tighten the rule (checksum manifest, etc.); the workflow only cares
# about the exit code.
# -----------------------------------------------------------------------
if [ "${BUILD_IDEMPOTENCY_CHECK:-0}" = "1" ]; then
  if [ -d "$ARTIFACT_DIR" ] && [ -n "$(ls -A "$ARTIFACT_DIR" 2>/dev/null || true)" ]; then
    if ls "$ARTIFACT_DIR" 2>/dev/null | grep -q -- "$TAG"; then
      echo "-> idempotency: artifact(s) for $TAG already present under $ARTIFACT_DIR/"
      exit 0
    fi
  fi
  echo "-> idempotency: no artifact(s) for $TAG under $ARTIFACT_DIR/ yet"
  exit 1
fi

mkdir -p "$ARTIFACT_DIR"

# -----------------------------------------------------------------------
# Project-type detection. Consumer projects fork the script and replace
# this body with their real build commands; the dispatchers below cover
# the canonical cases the template knows about.
# -----------------------------------------------------------------------
build_node_project() {
  echo "-> build.sh: Node project detected (package.json present)"
  if ! command -v npm >/dev/null 2>&1; then
    echo "::error::npm not on PATH; cannot build Node project"
    return 1
  fi
  npm install --no-audit --no-fund
  if node -e "process.exit(require('./package.json').scripts && require('./package.json').scripts.build ? 0 : 1)" 2>/dev/null; then
    echo "-> running: npm run build"
    npm run build
    # Best-effort: copy a tarball of common output dirs into the artifact dir.
    local out_tarball="$ARTIFACT_DIR/node-${TAG}.tar.gz"
    local copied=0
    for d in dist build out lib; do
      if [ -d "$d" ] && [ "$d" != "$ARTIFACT_DIR" ] && [ "$(dirname "$d")" != "build" -o "$d" = "dist" -o "$d" = "out" -o "$d" = "lib" ]; then
        if [ "$copied" = "0" ]; then
          tar czf "$out_tarball" "$d"
          copied=1
        fi
      fi
    done
    if [ "$copied" = "0" ]; then
      # No standard output dir; emit a marker so the workflow has something
      # to upload and the consumer notices the contract gap.
      printf 'Node build for %s completed but produced no recognized output dir (dist/build/out/lib). Consumer must override build.sh to populate %s/.\n' \
        "$TAG" "$ARTIFACT_DIR" > "$ARTIFACT_DIR/node-${TAG}.NO-OUTPUT.txt"
    fi
    return 0
  fi
  echo "-> package.json has no 'build' script; nothing to do"
  printf 'Node project %s has no npm build script. Consumer must override build.sh to populate %s/.\n' \
    "$TAG" "$ARTIFACT_DIR" > "$ARTIFACT_DIR/node-${TAG}.NO-BUILD-SCRIPT.txt"
  return 0
}

build_qt_cmake_project() {
  echo "-> build.sh: Qt/C++ project detected (CMakeLists.txt present)"
  cat >&2 <<EOF
=========================================================================
build.sh has detected a CMakeLists.txt but the template ships no
generic Qt/C++ build recipe. Module set, generator, toolchain, and
artifact layout vary too much across consumers.

OVERRIDE build.sh with your project's build steps. Examples:

  cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
  cmake --build build --parallel
  cp build/MyApp $ARTIFACT_DIR/MyApp-${TAG}

Output must land under ./$ARTIFACT_DIR/ for the distribution bundle to
find it. Filenames should embed \$TAG so the workflow idempotency check
can recognize a prior successful build.
=========================================================================
EOF
  return 1
}

build_template_self() {
  echo "-> build.sh: no consumer project markers (no package.json, no CMakeLists.txt)"
  echo "-> emitting a tag summary artifact for the template's own tag pushes"
  local summary="$ARTIFACT_DIR/how-git-${TAG}.txt"
  {
    echo "how-git template tag: $TAG"
    echo "built at:             $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "sha:                  $(git rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "branch reachability:"
    if git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
      echo "  reachable from origin/main: yes (release tag)"
    else
      echo "  reachable from origin/main: no (dev tag, not yet promoted)"
    fi
    echo ""
    echo "This is the template's self-build placeholder. Consumer projects"
    echo "replace build.sh with their real build commands; the template itself"
    echo "has nothing to compile, so the artifact is a text summary."
  } > "$summary"
  echo "-> wrote $summary"
  return 0
}

# Dispatcher
if [ -f package.json ]; then
  build_node_project
elif [ -f CMakeLists.txt ]; then
  build_qt_cmake_project
else
  build_template_self
fi

# Final sanity: at least one file landed in the artifact dir.
if [ -z "$(ls -A "$ARTIFACT_DIR" 2>/dev/null || true)" ]; then
  echo "::error::build.sh exited without populating $ARTIFACT_DIR/ for $TAG"
  exit 1
fi

echo "-> build.sh: success for $TAG"
ls -la "$ARTIFACT_DIR"
