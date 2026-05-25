#!/usr/bin/env bash
# test-lifecycle.sh — unitary e2e test of the full v4rian template lifecycle.
#
# Runs LOCALLY in a temp dir; simulates external systems (PR merges via
# GitHub UI, CI workflow dispatches, allocator endpoint, GitHub API
# Release creation) so the entire pipeline can be validated offline.
# Each test is an independent function with explicit setup / action /
# assert; the runner reports PASS/FAIL per test and a summary at the
# end. Designed to run in seconds, not minutes — no network, no
# claude API calls, no external repo creation.
#
# Coverage:
#
#   Bootstrap + auto-activation
#     · clone state (no VERSION, no core.hooksPath, no alias)
#     · auto-activate on first script call
#     · heal restores after drift (hooksPath, exec bits, VERSION)
#
#   Hooks (Step 2 commit stage: deterministic local auto-fix + async CI)
#     · pre-push branch-name regex accept/reject
#     · commit-msg subject length guardrail (no claude audit anymore)
#     · pre-push is regex-only (four claude audits moved to CI)
#     · prepare-commit-msg sources + runs the shared auto-fix library
#     · pre-commit scrubs em/en-dashes from staged files
#     · auto-fix lib derives tag from diff + scrubs dashes from messages
#     · audit-pushed-branch.yml ships compile / coverage / runtime jobs
#     · dev ruleset binds those three as required status checks
#     · post-checkout warns on bad branch name + invokes preflight skill
#     · post-merge auto-runs claim-dev-merge on dev / claim-main-release on main
#     · post-merge skips chore(version) bumps and squash merges
#
#   Scripts
#     · bump.sh math (tag dev/main, next dev/main, error paths)
#     · init-version.sh produces a calendar-stamped version
#     · open-pr.sh in --dry-run + --doctor modes (no API)
#     · claim-dev-merge.sh tags + bumps + would-push
#     · claim-main-release.sh tags + GCs safety + bumps + would-push (with --no-release)
#     · heal.sh restores expected state
#
#   In-repo assets
#     · 12 skill files present
#     · git repo alias dispatches correctly
#     · CI workflows present and dispatch to local scripts
#
#   Composite lifecycle
#     · bootstrap → pool/n3 allocation → commit on pool/n3 → push (simulated) →
#       PR open (simulated) → PR merge into dev (simulated) → claim-dev-merge →
#       dev → main merge (simulated) → claim-main-release → final state assertions
#
# Usage:
#   bash .io.v4rian.how-git/framework-tests/test-lifecycle.sh
#   bash .io.v4rian.how-git/framework-tests/test-lifecycle.sh --verbose      (show all output)
#   bash .io.v4rian.how-git/framework-tests/test-lifecycle.sh --filter NAME  (run only matching)

set -uo pipefail

# ============================================================================
# Test infrastructure
# ============================================================================

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# framework-tests/ lives inside .io.v4rian.how-git/framework-tests/ per the
# "framework files cannot leave outside .io folder" principle (pool/n49
# restored this after pool/n45's brief stint at the repo root). Two levels
# up from SCRIPT_DIR is the actual repo root.
TEMPLATE_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
SCRATCH_BASE=$(mktemp -d -t "v4rian-lifecycle-XXXXXX")
trap 'rm -rf "$SCRATCH_BASE"' EXIT

PASS=0
FAIL=0
FAILURES=()
VERBOSE=false
FILTER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --verbose) VERBOSE=true; shift ;;
    --filter)  FILTER="$2"; shift 2 ;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Capture each test's stdout+stderr to a per-test log; show on FAIL or --verbose.
run_test() {
  local name="$1"
  local fn="$2"
  if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then
    return 0
  fi
  printf '  %-70s' "$name ..."
  local log="$SCRATCH_BASE/$fn.log"
  if "$fn" >"$log" 2>&1; then
    echo "PASS"
    PASS=$((PASS+1))
    $VERBOSE && sed 's/^/      /' "$log"
  else
    echo "FAIL"
    FAIL=$((FAIL+1))
    FAILURES+=("$name")
    echo "    --- log ($log) ---"
    sed 's/^/      /' "$log" | head -30
    echo "    ---"
  fi
}

# Make a fresh consumer repo seeded from the current template tree, on a
# fresh main branch. Each test that needs a repo calls this with its own
# dir. Also creates a bare "fake origin" so the in-repo scripts (which
# push to origin during claims) can complete without network.
setup_scratch_repo() {
  local dir="$1"
  rm -rf "$dir" "$dir.origin"
  # Bare origin
  git init -q --bare "$dir.origin"
  # Working repo
  mkdir -p "$dir"
  ( cd "$dir"
    git init -q -b main
    cp -RpP "$TEMPLATE_ROOT/.gitignore" .
    cp -RpP "$TEMPLATE_ROOT/.io.v4rian.how-git" .
    if [ -d "$TEMPLATE_ROOT/.github" ]; then
      cp -RpP "$TEMPLATE_ROOT/.github" .
    fi
    git -c user.email=test@test -c user.name=test add .
    git -c user.email=test@test -c user.name=test commit -q --no-verify -m "chore: bootstrap (test scaffold)"
    git remote add origin "$dir.origin"
    git push -q origin main
  )
}

# Assert helpers
assert_eq() { [ "$1" = "$2" ] || { echo "ASSERT_EQ FAIL: expected '$2', got '$1' ($3)"; return 1; }; return 0; }
assert_ne() { [ "$1" != "$2" ] || { echo "ASSERT_NE FAIL: expected ≠ '$2', got equal ($3)"; return 1; }; return 0; }
assert_file_exists() { [ -e "$1" ] || { echo "ASSERT_FILE_EXISTS FAIL: $1 ($2)"; return 1; }; return 0; }
assert_executable() { [ -x "$1" ] || { echo "ASSERT_EXECUTABLE FAIL: $1 ($2)"; return 1; }; return 0; }
assert_grep() { grep -q -- "$1" "$2" || { echo "ASSERT_GREP FAIL: pattern '$1' not in $2 ($3)"; return 1; }; return 0; }

# All hook-and-script invocations under test run with this env so the
# heavy claude_skill_run call is bypassed.
export LIFECYCLE_TEST_MODE=1

# ============================================================================
# Test functions
# ============================================================================

test_clone_state_no_setup_artifacts() {
  local d="$SCRATCH_BASE/01-clone"
  setup_scratch_repo "$d"
  cd "$d"
  # Fresh repo should NOT have core.hooksPath set, no VERSION file, no alias
  [ -z "$(git config core.hooksPath || true)" ] || { echo "core.hooksPath was set in fresh repo"; return 1; }
  [ ! -f VERSION ] || { echo "VERSION exists in fresh repo (should not)"; return 1; }
  [ -z "$(git config alias.v4r || true)" ] || { echo "alias.v4r set in fresh repo"; return 1; }
  echo "  ✓ fresh repo has no setup artifacts"
}

test_auto_activate_on_first_script_call() {
  local d="$SCRATCH_BASE/02-auto"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/open-pr.sh --doctor >/dev/null 2>&1 || true
  assert_eq "$(git config core.hooksPath)" ".io.v4rian.how-git/githooks" "hooks path set" || return 1
  assert_ne "$(git config alias.v4r || echo unset)" "unset" "alias.v4r installed" || return 1
}

test_heal_restores_hooks_path_after_drift() {
  local d="$SCRATCH_BASE/03-heal-hooks"
  setup_scratch_repo "$d"
  cd "$d"
  git config core.hooksPath /tmp/nonexistent
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  assert_eq "$(git config core.hooksPath)" ".io.v4rian.how-git/githooks" "hooksPath restored" || return 1
}

test_heal_does_not_create_version_file() {
  local d="$SCRATCH_BASE/04-heal-no-ver"
  setup_scratch_repo "$d"
  cd "$d"
  [ ! -f VERSION ] || rm VERSION
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  [ ! -f VERSION ] || { echo "heal created a VERSION file (must not in tags-as-seal model)"; return 1; }
}

test_heal_restores_executable_bits() {
  local d="$SCRATCH_BASE/05-heal-chmod"
  setup_scratch_repo "$d"
  cd "$d"
  chmod -x .io.v4rian.how-git/githooks/pre-push
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  assert_executable .io.v4rian.how-git/githooks/pre-push "pre-push re-chmodded" || return 1
}

test_pre_push_regex_accepts_pool() {
  # The pre-push regex accepts both the legacy flat layout and the
  # vYYYY.MAIN/ prefixed layout that active allocation now produces.
  local pattern='^(pool|safety)/(v[0-9]{4}\.[0-9]+/)?n[0-9]+\.(feature|fix|r&d|refactor|reconcile|doc)\.(sprint[0-9]+-)?([A-Z]+-[0-9]+-)?[a-z0-9][a-z0-9_-]*$'
  for good in \
    "pool/n3.feature.parser_rewrite" \
    "pool/v2026.0/n3.feature.parser_rewrite" \
    "safety/v2026.0/n3.feature.parser_rewrite" \
    "pool/v2026.12/n44.fix.PROJ-1-token-leak" \
    "pool/v2026.0/n65.doc.runbook-rewrite" \
    "safety/v2026.0/n65.doc.runbook-rewrite"; do
    [[ "$good" =~ $pattern ]] || { echo "regex rejected valid name: $good"; return 1; }
  done
}

test_pre_push_regex_rejects_invalid() {
  # Beyond the legacy invalid cases, the regex must also reject malformed
  # major-prefix segments (3-segment versions, missing major, etc).
  local pattern='^(pool|safety)/(v[0-9]{4}\.[0-9]+/)?n[0-9]+\.(feature|fix|r&d|refactor|reconcile|doc)\.(sprint[0-9]+-)?([A-Z]+-[0-9]+-)?[a-z0-9][a-z0-9_-]*$'
  for bad in \
    "dev/n3.feature.foo" \
    "feature/foo" \
    "pool/n3.unknown.foo" \
    "pool/N3.feature.foo" \
    "pool/v2026/n3.feature.foo" \
    "pool/v2026.0.0/n3.feature.foo" \
    "pool/v2026.0/N3.feature.foo"; do
    if [[ "$bad" =~ $pattern ]]; then
      echo "regex accepted invalid name: $bad"
      return 1
    fi
  done
}

test_commit_audit_push_gate_wires_through_audit_retry() {
  # Pool n69 adds a push-trigger commit-audit gate that applies the
  # git-commit-audit lens to every commit in the push range. The gate
  # is wired through audit-retry.sh's existing exponential-backoff
  # loop and the worker lives at scripts/audits/commit-audit.sh per
  # the established push-audit layout. Pin all four surfaces so
  # future drift in any of them breaks the suite rather than the
  # next PR-into-dev gate slip.
  local root="$TEMPLATE_ROOT/.io.v4rian.how-git"

  # 1. Thin wrapper at the sys-layer push-audit path exec-delegates
  # to audit-retry with --audit commit-audit.
  assert_file_exists "$root/ci/audits/push/required.commit-audit.sh" \
    "required.commit-audit wrapper present" || return 1
  assert_executable "$root/ci/audits/push/required.commit-audit.sh" \
    "required.commit-audit wrapper executable" || return 1
  assert_grep 'audit-retry.sh --audit commit-audit' "$root/ci/audits/push/required.commit-audit.sh" \
    "wrapper exec-delegates to audit-retry" || return 1

  # 2. Worker present + executable.
  assert_file_exists "$root/scripts/audits/commit-audit.sh" \
    "commit-audit worker present" || return 1
  assert_executable "$root/scripts/audits/commit-audit.sh" \
    "commit-audit worker executable" || return 1

  # 3. audit-retry allowlist extended to accept commit-audit.
  assert_grep 'compile|coverage|runtime|commit-audit' "$root/scripts/workflows/audit-retry.sh" \
    "audit-retry allowlist includes commit-audit" || return 1

  # 4. Worker functional under LIFECYCLE_TEST_MODE: empty range
  # exits 0 cleanly, and a non-empty range fires the canned banner.
  local d="$SCRATCH_BASE/commit-audit-canned"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  local out rc
  out=$(LIFECYCLE_TEST_MODE=1 bash .io.v4rian.how-git/scripts/audits/commit-audit.sh 2>&1); rc=$?
  assert_eq "$rc" "0" "canned-mode exits 0 on empty range" || { echo "$out"; return 1; }
  git checkout -q -b pool/v2026.0/n1.feature.commit-audit-probe
  printf 'probe\n' > probe.txt
  git -c user.email=t@t -c user.name=t add probe.txt
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] Probe commit for commit-audit canned mode"
  out=$(LIFECYCLE_TEST_MODE=1 bash .io.v4rian.how-git/scripts/audits/commit-audit.sh 2>&1); rc=$?
  assert_eq "$rc" "0" "canned-mode exits 0 with commits in range" || { echo "$out"; return 1; }
  echo "$out" | grep -q "commit-audit \[canned\]" \
    || { echo "canned-mode banner missing; got: $out"; return 1; }
}

test_claim_flow_carries_pr_body_recap_and_pr_reference() {
  # When the claim flow amends a merge commit it must do three things to
  # keep the dev log auditable: (a) source the body from the PR via gh
  # when possible; (b) detect the empty-response case loudly and fall
  # back to the existing merge body so the recap section is not silently
  # dropped (n58-n64 all landed empty before this fix); (c) append a
  # "Merged via #N" trailer so the merge commit always carries a pointer
  # back to the PR thread that justified the merge. Wire-side: the
  # ci-dispatch matrix run step must bind GH_TOKEN or every gh call in
  # any required script runs unauthenticated.
  local repo_root="$TEMPLATE_ROOT"
  local dev_script="$repo_root/.io.v4rian.how-git/scripts/claim-dev-merge.sh"
  local main_script="$repo_root/.io.v4rian.how-git/scripts/claim-main-release.sh"
  local dispatcher="$repo_root/.github/workflows/ci-dispatch.yml"

  # 1. ci-dispatch matrix step binds GH_TOKEN + GITHUB_TOKEN so the gh
  # CLI authenticates inside every required script.
  assert_grep 'GH_TOKEN:.*secrets.GITHUB_TOKEN' "$dispatcher" \
    "ci-dispatch matrix step binds GH_TOKEN" || return 1
  assert_grep 'GITHUB_TOKEN:.*secrets.GITHUB_TOKEN' "$dispatcher" \
    "ci-dispatch matrix step binds GITHUB_TOKEN" || return 1

  # 2. Both claim scripts loud-fallback when gh pr view returns empty
  # so a missing token / rate limit / empty body cannot silently drop
  # the recap section.
  assert_grep 'PR #\$PR_NUM body fetch returned empty' "$dev_script" \
    "claim-dev-merge logs empty-body fallback" || return 1
  assert_grep 'PR #\$PR_NUM body fetch returned empty' "$main_script" \
    "claim-main-release logs empty-body fallback" || return 1

  # 3. Both claim scripts prepend the "PR #N" body reference as the
  # first paragraph (right after the subject) so the merge commit's
  # PR pointer is the first thing a reader sees under the subject.
  assert_grep 'PR_LINE="PR #\${PR_NUM}' "$dev_script" \
    "claim-dev-merge prepends PR #N reference after the subject" || return 1
  assert_grep 'PR_LINE="PR #\${PR_NUM}' "$main_script" \
    "claim-main-release prepends PR #N reference after the subject" || return 1

  # 4. Both claim scripts append the full GitHub PR URL after the
  # number so the reference is click-to-open from any terminal that
  # auto-links URLs.
  assert_grep 'https://github.com/\${OWNER_REPO}/pull/\${PR_NUM}' "$dev_script" \
    "claim-dev-merge appends the GitHub PR URL after the number" || return 1
  assert_grep 'https://github.com/\${OWNER_REPO}/pull/\${PR_NUM}' "$main_script" \
    "claim-main-release appends the GitHub PR URL after the number" || return 1
}

test_doc_kind_wired_across_every_validation_surface() {
  # When a new branch kind ships, every gate that classifies pool branches
  # must learn the new token or the lifecycle silently rejects it somewhere
  # downstream (as the pool/n63 docs-only branch did before this fix). Pin
  # the doc kind into the four surfaces that touch the kind set so a future
  # drift breaks the suite rather than the next docs-only contributor.
  local root="$TEMPLATE_ROOT/.io.v4rian.how-git"

  # 1. pre-push hook regex accepts doc.
  assert_grep 'feature|fix|r&d|refactor|reconcile|doc' "$root/githooks/pre-push" \
    "pre-push regex includes doc" || return 1

  # 2. post-checkout warning regex accepts doc.
  assert_grep 'feature|fix|r&d|refactor|reconcile|doc' "$root/githooks/post-checkout" \
    "post-checkout regex includes doc" || return 1

  # 3. validate-pr-open.sh source-branch regex accepts doc and kind_to_tag
  # maps doc to [DOCS].
  assert_grep 'feature|fix|r\\&d|refactor|reconcile|doc' "$root/scripts/validate-pr-open.sh" \
    "validate-pr-open regex includes doc" || return 1
  assert_grep 'doc).*\[DOCS\]' "$root/scripts/validate-pr-open.sh" \
    "validate-pr-open kind_to_tag maps doc to [DOCS]" || return 1

  # 4. allocate-pool-branch.sh accepts doc in the kind allowlist + classifier.
  assert_grep 'feature|fix|r\\&d|refactor|reconcile|doc' "$root/scripts/allocate-pool-branch.sh" \
    "allocate-pool-branch kind allowlist includes doc" || return 1

  # 5. create-pool-branch CLI accepts --kind doc.
  assert_grep 'feature|fix|r\\&d|refactor|reconcile|doc' "$root/bin/create-pool-branch" \
    "create-pool-branch --kind allowlist includes doc" || return 1

  # 6. Functional: pre-push hook actually accepts a doc-shape branch name.
  local d="$SCRATCH_BASE/doc-kind-hook"
  setup_scratch_repo "$d"
  cd "$d"
  git checkout -q -b pool/v2026.0/n1.doc.runbook-rewrite
  bash .io.v4rian.how-git/githooks/pre-push >/dev/null 2>&1 || {
    echo "pre-push rejected pool/v2026.0/n1.doc.runbook-rewrite"; return 1; }
}

test_commit_msg_subject_length() {
  local d="$SCRATCH_BASE/08-commit-len"
  setup_scratch_repo "$d"
  cd "$d"
  echo "tiny" > /tmp/.short-msg
  if bash .io.v4rian.how-git/githooks/commit-msg /tmp/.short-msg 2>/dev/null; then
    echo "commit-msg accepted too-short subject"; return 1
  fi
  echo "[NEW] A good length subject for the audit" > /tmp/.good-msg
  bash .io.v4rian.how-git/githooks/commit-msg /tmp/.good-msg >/dev/null 2>&1 || { echo "commit-msg rejected good subject"; return 1; }
}

test_commit_msg_is_subject_length_guardrail_only() {
  # Step 2 lifecycle: commit-msg drops the synchronous claude audit. It
  # keeps only the cheap deterministic subject-length check; heavy
  # audits ran async in CI via audit-pushed-branch.yml. The cap is
  # prefix-aware (see test_commit_msg_exempts_merge_and_req_subjects)
  # but the guardrail-only contract still holds.
  local hook="$TEMPLATE_ROOT/.io.v4rian.how-git/githooks/commit-msg"
  if grep -q "claude_skill_run" "$hook"; then
    echo "commit-msg still wires a claude_skill_run (should be removed in Step 2)"; return 1
  fi
  # The length guardrail must still fire on inputs at the bounds.
  echo "tiny" > /tmp/.short-msg
  if bash "$hook" /tmp/.short-msg 2>/dev/null; then
    echo "commit-msg accepted too-short subject"; return 1
  fi
  echo "[NEW] A good length subject line for the deterministic guardrail" > /tmp/.good-msg
  bash "$hook" /tmp/.good-msg >/dev/null 2>&1 || { echo "commit-msg rejected good subject"; return 1; }
}

test_commit_msg_exempts_merge_and_req_subjects() {
  # The pool/vYYYY.MAIN/ prefix layout shipped in n51 grows the spec
  # MERGE subject that claim-dev-merge.sh writes past 100 chars even
  # on reasonably-sized slugs. The same shape risk applies to the
  # allocator's [REQ] subject. Both auto-generated prefixes are
  # exempted up to 140; hand-written subjects still cap at 100 so
  # kernel-style discipline survives on contributor commits.
  local hook="$TEMPLATE_ROOT/.io.v4rian.how-git/githooks/commit-msg"

  # 112-char MERGE subject reproducing the n60 claim failure case.
  echo "[MERGE] pool/v2026.0/n60.refactor.ci-dispatch-drops-pull-request-trigger-to-end-duplication into dev: v2026.0.56" > /tmp/.merge-long
  bash "$hook" /tmp/.merge-long >/dev/null 2>&1 || { echo "commit-msg rejected the 112-char [MERGE] subject"; return 1; }

  # 126-char REQ subject approximating the allocator's worst-case output.
  echo "[REQ] active-requirement: pool/v2026.0/n99.feature.some-long-slug-that-pushes-the-allocator-subject-length-to-near-the-cap-end" > /tmp/.req-long
  bash "$hook" /tmp/.req-long >/dev/null 2>&1 || { echo "commit-msg rejected the 126-char [REQ] subject"; return 1; }

  # MERGE subject above 140 still rejected so the exemption is bounded.
  local pad
  pad=$(printf 'x%.0s' {1..120})
  echo "[MERGE] pool/v2026.0/n99.feature.${pad} into dev: v2026.0.99" > /tmp/.merge-over
  if bash "$hook" /tmp/.merge-over >/dev/null 2>&1; then
    echo "commit-msg accepted a [MERGE] subject above the 140 ceiling"; return 1
  fi

  # Hand-written subject above 100 still rejected so the exemption
  # cannot leak into contributor commits via a missing prefix check.
  local long_pad
  long_pad=$(printf 'a%.0s' {1..120})
  echo "[NEW] ${long_pad}" > /tmp/.new-over
  if bash "$hook" /tmp/.new-over >/dev/null 2>&1; then
    echo "commit-msg accepted a hand-written subject above 100 chars"; return 1
  fi
}

test_pre_push_is_branch_regex_only() {
  # Step 2 lifecycle: pre-push drops the four claude audits (strategy,
  # compile, coverage, runtime) and keeps only the branch-name regex
  # guardrail. The dropped audits ran in CI via audit-pushed-branch.yml.
  local hook="$TEMPLATE_ROOT/.io.v4rian.how-git/githooks/pre-push"
  if grep -q "claude_skill_run" "$hook"; then
    echo "pre-push still wires a claude_skill_run (should be removed in Step 2)"; return 1
  fi
  # The branch-name regex guardrail must still be there. The (v[0-9]{4}\.
  # [0-9]+/)? group is the optional major-prefix segment introduced when
  # active allocation gained vYYYY.MAIN/ release-line classification; the
  # regex accepts both layouts.
  assert_grep '\^(pool|safety)/(v\[0-9\]{4}\\\.\[0-9\]+/)?n\[0-9\]+\\\.' "$hook" "branch-name regex present" || return 1
}

test_prepare_commit_msg_runs_auto_fix_layer() {
  # Step 2 lifecycle: prepare-commit-msg sources the shared auto-fix lib
  # and runs the deterministic local rewrites (em-dash scrub, banned
  # words, tag derivation, sentence cap, third-person bullets).
  local hook="$TEMPLATE_ROOT/.io.v4rian.how-git/githooks/prepare-commit-msg"
  [ -f "$hook" ] || { echo "prepare-commit-msg hook missing"; return 1; }
  assert_grep "auto-fix-commit-message.sh" "$hook" "shared auto-fix lib sourced" || return 1
  assert_grep "auto_fix_message" "$hook" "auto_fix_message invoked" || return 1
  assert_grep "AUTO_FIX_DERIVED_TAG" "$hook" "tag derivation exported" || return 1
}

test_pre_commit_scrubs_dashes_from_staged_files() {
  # Step 2 lifecycle: pre-commit hook scrubs em-dashes and en-dashes
  # from staged files before the commit lands. Verify the hook exists,
  # is executable, and actually rewrites a staged file containing an
  # em-dash to an ascii equivalent.
  local hook="$TEMPLATE_ROOT/.io.v4rian.how-git/githooks/pre-commit"
  [ -x "$hook" ] || { echo "pre-commit hook missing or not executable"; return 1; }
  local d="$SCRATCH_BASE/08b-pre-commit-scrub"
  setup_scratch_repo "$d"
  cd "$d"
  printf 'first line\nbody with an em-dash word here\nthird line\n' > sample.txt
  git -c user.email=test@test -c user.name=test add sample.txt
  bash "$hook" >/dev/null 2>&1 || true
  if grep -q $'\xe2\x80\x94' sample.txt; then
    echo "pre-commit did not scrub em-dash from staged file"; return 1
  fi
  if grep -q $'\xe2\x80\x93' sample.txt; then
    echo "pre-commit did not scrub en-dash from staged file"; return 1
  fi
}

test_auto_fix_lib_derives_tag_and_scrubs_dashes() {
  # The shared auto-fix library is the substrate for both the
  # prepare-commit-msg hook and the upcoming PR-body validator. Verify
  # the two public entry points actually work in isolation.
  local lib="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/lib/auto-fix-commit-message.sh"
  [ -f "$lib" ] || { echo "auto-fix library missing"; return 1; }
  local d="$SCRATCH_BASE/08c-auto-fix"
  setup_scratch_repo "$d"
  cd "$d"
  # Stage a brand-new file so derive_tag_from_diff returns [NEW].
  echo "new content" > .new-file
  git -c user.email=test@test -c user.name=test add .new-file
  # shellcheck disable=SC1090
  . "$lib"
  local tag
  tag=$(derive_tag_from_diff)
  [ "$tag" = "[NEW]" ] || { echo "derive_tag_from_diff returned '$tag', expected '[NEW]'"; return 1; }
  # Exercise auto_fix_message: em-dash scrub + tag prepend on a tag-less title.
  printf 'a subject with an em-dash phrase here\n\nA short description paragraph.\n' > /tmp/.auto-fix-msg
  AUTO_FIX_DERIVED_TAG="[NEW]" auto_fix_message /tmp/.auto-fix-msg
  if grep -q $'\xe2\x80\x94' /tmp/.auto-fix-msg; then
    echo "auto_fix_message did not scrub em-dash"; return 1
  fi
  if ! head -n1 /tmp/.auto-fix-msg | grep -q "^\[NEW\]"; then
    echo "auto_fix_message did not prepend derived tag"; return 1
  fi
}

test_async_ci_audit_workflow_present() {
  # Step 2 lifecycle: the four dropped claude audits (strategy,
  # compile, coverage, runtime) move to async CI and surface as
  # required status checks on PRs to dev.
  #
  # Pool/n55 + pool/n58: the standalone audit-pushed-branch.yml is
  # replaced by sys-layer required.*.sh entries fronted by ci-dispatch.yml.
  # The audits run on the push event that lands the head SHA (pool/n58
  # correction); the PR reuses the result on pr-open by context name.
  # The entries delegate to .io.v4rian.how-git/scripts/workflows/audit-retry.sh
  # which preserves the original retry semantics.
  local audits_dir="$TEMPLATE_ROOT/.io.v4rian.how-git/ci/audits/push"
  [ -d "$audits_dir" ] || { echo "ci/audits/push sys-layer dir missing"; return 1; }
  local entry
  for check in compile coverage runtime; do
    entry="$audits_dir/required.${check}.sh"
    [ -f "$entry" ] || { echo "sys-layer entry $entry missing"; return 1; }
    [ -x "$entry" ] || { echo "sys-layer entry $entry not executable"; return 1; }
    grep -q -- "--audit $check" "$entry" \
      || { echo "$entry does not dispatch audit-retry.sh --audit $check"; return 1; }
  done
  # The legacy yaml must be gone so two engines do not coexist.
  local legacy="$TEMPLATE_ROOT/.github/workflows/audit-pushed-branch.yml"
  if [ -f "$legacy" ]; then
    echo "ASSERT FAIL: legacy audit-pushed-branch.yml still present; pool/n55 should have removed it"
    return 1
  fi
}

test_retry_loops_capture_exit_code_correctly() {
  # pool/n42 regression guard: the pattern
  #   if bash cmd; then exit 0; fi
  #   rc=$?
  # is broken because after the if construct $? is the if-statement's
  # own exit (0 when the then-branch did not run), not the inner
  # command's exit. The fix is to run the command separately and
  # capture rc immediately:
  #   bash cmd
  #   rc=$?
  #   if [ "$rc" -eq 0 ]; then exit 0; fi
  # Before this fix every retry loop in audit-pushed-branch, claim-on-
  # merge-dev, claim-on-merge-main, and build-on-tag observed rc=0 on
  # every iteration and ran all MAX_ATTEMPTS attempts as silent NOPs
  # (~14 minutes per audit-pushed-branch run, with conclusion=success
  # even when the inner audits had failed). Forbid the pattern across
  # every workflow so it cannot regress.
  # pool/n45: retry loops moved out of workflow yamls into
  # .io.v4rian.how-git/scripts/workflows/*.sh. Scan BOTH locations so
  # the bug can't sneak back in either place.
  local wf bad
  local scan_paths=()
  for wf in "$TEMPLATE_ROOT"/.github/workflows/*.yml "$TEMPLATE_ROOT"/.io.v4rian.how-git/scripts/workflows/*.sh; do
    [ -f "$wf" ] || continue
    scan_paths+=("$wf")
  done
  for wf in "${scan_paths[@]}"; do
    bad=$(awk '
      /^[[:space:]]*if bash .*\.sh.*; then[[:space:]]*$/ { in_if=1; if_line=NR; next }
      in_if && /^[[:space:]]*fi[[:space:]]*$/ { fi_line=NR; checking=1; in_if=0; next }
      checking && /^[[:space:]]*rc=\$\?[[:space:]]*$/ {
        printf "%s:%d: bare rc=$? after `if bash cmd; then ... fi`\n", FILENAME, NR
        checking=0
      }
      checking && /[^[:space:]]/ { checking=0 }
    ' "$wf")
    if [ -n "$bad" ]; then
      echo "broken retry pattern in workflow or workflow script:"
      echo "$bad"
      return 1
    fi
  done
}

test_dev_required_status_checks_ruleset_present() {
  # Step 2 lifecycle: the dev branch ruleset binds compile, coverage,
  # and runtime as required status checks on PR merge to dev.
  #
  # Pool/n55 + pool/n58: the context names are now prefixed with
  # 'required.' because the sys-layer dispatcher posts each script's
  # basename (minus .sh) as the status check name, and the required.*
  # filename prefix marks them as merge-blocking. Branch protection
  # looks up checks by these context names regardless of which event
  # (push vs pr-open) published the status.
  local rs="$TEMPLATE_ROOT/.io.v4rian.how-git/rulesets/dev-required-checks.json"
  [ -f "$rs" ] || { echo "dev-required-checks.json ruleset missing"; return 1; }
  for check in required.compile required.coverage required.runtime; do
    grep -q "\"$check\"" "$rs" || { echo "dev-required-checks.json missing '$check' as required check"; return 1; }
  done
}

test_post_checkout_invokes_preflight() {
  assert_grep "claude_skill_run git-snapshot-preflight" "$TEMPLATE_ROOT/.io.v4rian.how-git/githooks/post-checkout" "wiring" || return 1
}

test_post_merge_auto_claims_on_dev() {
  local d="$SCRATCH_BASE/12-post-merge-dev"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  # Bring dev into being from main
  git checkout -q -b dev
  # Pretend a PR-style merge by creating a feature branch + merging --no-ff back
  git checkout -q -b pool/n9.feature.probe
  echo probe > .probe-file
  git -c user.email=test@test -c user.name=test add .probe-file
  git -c user.email=test@test -c user.name=test commit -q --no-verify -m "[REFACTOR] Probe commit for post-merge test"
  git checkout -q dev
  local pre_tags; pre_tags=$(git tag -l | wc -l | tr -d ' ')
  git -c user.email=test@test -c user.name=test merge --no-ff pool/n9.feature.probe \
    -m "[MERGE] pool/n9.feature.probe into dev: aspirational"
  local post_tags; post_tags=$(git tag -l | wc -l | tr -d ' ')
  [ "$post_tags" -gt "$pre_tags" ] || { echo "no new tag after dev merge (post-merge hook didn't claim)"; return 1; }
  local year; year=$(date -u +%Y)
  local expected="v${year}.0.1"
  git tag -l | grep -q "^${expected}$" || { echo "expected tag ${expected} not found (got: $(git tag -l))"; return 1; }
  [ ! -f VERSION ] || { echo "VERSION file appeared (should never in tags-as-seal model)"; return 1; }
}

test_post_merge_skips_chore_version() {
  local d="$SCRATCH_BASE/13-post-merge-skip"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev
  # Legacy chore commits don't happen in the new model; the skip-rule must
  # still match them for repos with such commits in their ancestry.
  echo "legacy chore marker" > .legacy-chore-marker
  git -c user.email=test@test -c user.name=test add .legacy-chore-marker
  git -c user.email=test@test -c user.name=test commit -q --no-verify -m "chore(version): legacy-style commit for skip-rule check"
  local pre_tags; pre_tags=$(git tag -l | wc -l | tr -d ' ')
  # Run the hook by hand simulating the post-merge $1 = 0 (non-squash)
  bash .io.v4rian.how-git/githooks/post-merge 0 >/dev/null 2>&1 || true
  local post_tags; post_tags=$(git tag -l | wc -l | tr -d ' ')
  assert_eq "$post_tags" "$pre_tags" "no tag created on chore(version) head" || return 1
}

test_post_merge_skips_squash() {
  local d="$SCRATCH_BASE/14-post-merge-squash"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev
  local pre_tags; pre_tags=$(git tag -l | wc -l | tr -d ' ')
  bash .io.v4rian.how-git/githooks/post-merge 1 >/dev/null 2>&1 || true
  local post_tags; post_tags=$(git tag -l | wc -l | tr -d ' ')
  assert_eq "$post_tags" "$pre_tags" "squash merge does not trigger claim" || return 1
}

test_post_merge_skips_pool_branches() {
  local d="$SCRATCH_BASE/15-post-merge-pool"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b pool/n8.feature.probe
  local pre_tags; pre_tags=$(git tag -l | wc -l | tr -d ' ')
  bash .io.v4rian.how-git/githooks/post-merge 0 >/dev/null 2>&1 || true
  local post_tags; post_tags=$(git tag -l | wc -l | tr -d ' ')
  assert_eq "$post_tags" "$pre_tags" "pool/ branch does not trigger claim" || return 1
}

test_dead_scripts_removed() {
  # bump.sh and init-version.sh are dead code under the tags-as-seal +
  # merge-count-based version model. Their math was moved into bin/version.
  local b="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/bump.sh"
  local i="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/init-version.sh"
  [ ! -e "$b" ] || { echo "bump.sh still exists - should be deleted (dead code)"; return 1; }
  [ ! -e "$i" ] || { echo "init-version.sh still exists - should be deleted (dead code)"; return 1; }
}

test_open_pr_doctor_mode() {
  local d="$SCRATCH_BASE/18-open-pr-doctor"
  setup_scratch_repo "$d"
  cd "$d"
  # --doctor exits cleanly even without a token (uses stdout reporting)
  bash .io.v4rian.how-git/scripts/open-pr.sh --doctor >/dev/null 2>&1 || true
  echo "  · open-pr.sh --doctor completed"
}

test_skills_present_in_repo() {
  local missing=0
  for s in git-commit-audit git-strategy-audit git-compile-audit git-coverage-audit git-runtime-audit git-snapshot-preflight git-merge-audit git-history-preservation git-history-rewrite git-token-discovery git-snapshots git-shuttle; do
    if [ ! -f "$TEMPLATE_ROOT/.io.v4rian.how-git/skills/$s/SKILL.md" ]; then
      echo "missing skill: $s"
      missing=$((missing+1))
    fi
  done
  [ $missing -eq 0 ] || return 1
}

test_consolidated_skills_present_in_repo() {
  # pool/n50: skills that previously lived only at the user's ~/.claude/skills/
  # level are now consolidated inside the namespace so consumer claude
  # instances resolve them through the in-repo-first order in the how-git
  # loader skill. git-reconcile-intent is what the auto-rebase L1-L5 ladder
  # drives during pool→dev reconciliation; how-dev is the binding post-push
  # CI monitoring discipline every dev on a v4rian repo follows.
  local missing=0
  for s in git-reconcile-intent how-dev; do
    if [ ! -f "$TEMPLATE_ROOT/.io.v4rian.how-git/skills/$s/SKILL.md" ]; then
      echo "missing consolidated skill: $s"
      missing=$((missing+1))
    fi
  done
  [ $missing -eq 0 ] || return 1
}

test_consolidated_skills_are_repo_agnostic() {
  # pool/n50: in-repo skills must not contain workspace-specific identifiers
  # that would confuse consumers cloning from the template. The in-repo
  # source-of-truth is generic; the global home-dir fallback may keep
  # workspace-specific values.
  # pool/n72: the owner/repo check derives the value to forbid from this
  # repo's origin URL at test time. Pinning the test to a specific literal
  # like the previous canonical org name turns the guard itself into a
  # hardlink that ages out the moment the framework moves orgs.
  local origin_owner_repo
  origin_owner_repo=$(cd "$TEMPLATE_ROOT" && git config --get remote.origin.url 2>/dev/null \
    | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
  local f
  for s in git-reconcile-intent how-dev; do
    f="$TEMPLATE_ROOT/.io.v4rian.how-git/skills/$s/SKILL.md"
    if [ -n "$origin_owner_repo" ] && grep -Fq "$origin_owner_repo" "$f"; then
      echo "$s embeds current origin owner/repo ($origin_owner_repo); skills must derive from origin at runtime"; return 1; fi
    if grep -q "v4rian-waylon" "$f"; then
      echo "$s embeds workspace-specific account: v4rian-waylon"; return 1; fi
    if grep -q "~/.gcm/store/" "$f"; then
      echo "$s embeds workspace-specific GCM path: ~/.gcm/store/"; return 1; fi
  done
}

test_git_repo_alias_dispatches_openPR() {
  local d="$SCRATCH_BASE/20-alias"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/open-pr.sh --doctor >/dev/null 2>&1 || true
  # Alias is installed; invoke it and check it dispatches to open-pr.sh
  # (using --dry-run which exits before any API call)
  out=$(git v4r openPR --doctor 2>&1) || true
  echo "$out" | grep -q 'dependency probe\|token' || { echo "alias didn't dispatch to open-pr.sh"; echo "$out"; return 1; }
}

test_ci_workflow_dev_dispatches() {
  # Pool/n55: post-migration, the claim-on-merge-dev workflow is replaced
  # by the sys-layer ci/audits/pr-merge-dev/required.claim.sh entry that
  # ci-dispatch.yml runs on push to dev. Assert the entry exists, is
  # executable, dispatches to claim-retry.sh with --target dev, and the
  # legacy yaml is absent so duplicated engines do not coexist.
  local entry="$TEMPLATE_ROOT/.io.v4rian.how-git/ci/audits/pr-merge-dev/required.claim.sh"
  local retry="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/workflows/claim-retry.sh"
  local legacy="$TEMPLATE_ROOT/.github/workflows/claim-on-merge-dev.yml"
  assert_file_exists "$entry" "pr-merge-dev sys entry" || return 1
  assert_executable "$entry" "pr-merge-dev sys entry executable" || return 1
  assert_file_exists "$retry" "claim-retry.sh" || return 1
  assert_grep "claim-retry.sh" "$entry" "pr-merge-dev entry dispatches to claim-retry" || return 1
  grep -q -- "--target dev" "$entry" || { echo "ASSERT_GREP FAIL: '--target dev' not in $entry (pr-merge-dev entry targets dev)"; return 1; }
  assert_grep "claim-dev-merge.sh" "$retry" "claim-retry references claim-dev-merge.sh" || return 1
  if [ -f "$legacy" ]; then
    echo "ASSERT FAIL: legacy claim-on-merge-dev.yml still present; pool/n55 should have removed it"
    return 1
  fi
}

test_ci_workflow_main_dispatches() {
  # Pool/n55 mirror of the dev case.
  local entry="$TEMPLATE_ROOT/.io.v4rian.how-git/ci/audits/pr-merge-main/required.claim.sh"
  local retry="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/workflows/claim-retry.sh"
  local legacy="$TEMPLATE_ROOT/.github/workflows/claim-on-merge-main.yml"
  assert_file_exists "$entry" "pr-merge-main sys entry" || return 1
  assert_executable "$entry" "pr-merge-main sys entry executable" || return 1
  assert_file_exists "$retry" "claim-retry.sh" || return 1
  assert_grep "claim-retry.sh" "$entry" "pr-merge-main entry dispatches to claim-retry" || return 1
  grep -q -- "--target main" "$entry" || { echo "ASSERT_GREP FAIL: '--target main' not in $entry (pr-merge-main entry targets main)"; return 1; }
  assert_grep "claim-main-release.sh" "$retry" "claim-retry references claim-main-release.sh" || return 1
  if [ -f "$legacy" ]; then
    echo "ASSERT FAIL: legacy claim-on-merge-main.yml still present; pool/n55 should have removed it"
    return 1
  fi
}

test_ci_build_on_tag_migrated_to_sys_layer() {
  # Pool/n55: the build-on-tag workflow is replaced by the sys-layer
  # ci/audits/tag/required.build.sh entry that ci-dispatch.yml runs on
  # v* tag push.
  local entry="$TEMPLATE_ROOT/.io.v4rian.how-git/ci/audits/tag/required.build.sh"
  local retry="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/workflows/build-retry.sh"
  local legacy="$TEMPLATE_ROOT/.github/workflows/build-on-tag.yml"
  assert_file_exists "$entry" "tag sys entry" || return 1
  assert_executable "$entry" "tag sys entry executable" || return 1
  assert_file_exists "$retry" "build-retry.sh" || return 1
  assert_grep "build-retry.sh" "$entry" "tag entry dispatches to build-retry" || return 1
  if [ -f "$legacy" ]; then
    echo "ASSERT FAIL: legacy build-on-tag.yml still present; pool/n55 should have removed it"
    return 1
  fi
}

test_ci_dispatch_resolves_dev_push_as_pr_merge_dev() {
  # Pool/n55: ci-dispatch.yml's resolve maps refs/heads/dev push to
  # pr-merge-dev so the migrated claim entry fires.
  local wf="$TEMPLATE_ROOT/.github/workflows/ci-dispatch.yml"
  assert_file_exists "$wf" "ci-dispatch.yml" || return 1
  assert_grep "refs/heads/dev)" "$wf" "dev branch case in resolve" || return 1
  assert_grep 'trigger="pr-merge-dev"' "$wf" "dev push resolves to pr-merge-dev" || return 1
  assert_grep "refs/heads/main)" "$wf" "main branch case in resolve" || return 1
  assert_grep 'trigger="pr-merge-main"' "$wf" "main push resolves to pr-merge-main" || return 1
}

test_ci_dispatch_skips_chore_version_self_push() {
  # Pool/n55: chore(version) head_commit guard from the legacy claim
  # workflows is preserved at the dispatcher layer so bump commits do
  # not loop the dispatcher on push-to-dev or push-to-main.
  local wf="$TEMPLATE_ROOT/.github/workflows/ci-dispatch.yml"
  assert_grep "chore(version)" "$wf" "chore(version) guard present" || return 1
  assert_grep "skipping chore(version)" "$wf" "skip log line present" || return 1
}

test_ci_dispatch_has_contents_write_permission() {
  # Pool/n55: contents:write is required so migrated claim scripts can
  # force-push dev or main, push tags, and archive merged pool branches.
  local wf="$TEMPLATE_ROOT/.github/workflows/ci-dispatch.yml"
  assert_grep "contents: write" "$wf" "contents:write permission" || return 1
}

test_ci_harness_has_usr_layer_smoke_scripts() {
  # Pool/n55 + n59: the usr-layer ci/tests/<trigger>/ harness ships ONE
  # smoke script at ci/tests/push/harness-smoke.sh. The pr-open variant
  # was dropped in pool/n59 once ci-dispatch's pull_request trigger was
  # removed: with audits living on push and validate-pr-open owning the
  # pr-open work, an additional pr-open smoke would fire the same SHA
  # twice. The push smoke is sufficient to prove the dispatcher resolves
  # usr-layer scripts and runs them.
  local push="$TEMPLATE_ROOT/ci/tests/push/harness-smoke.sh"
  local pr_open="$TEMPLATE_ROOT/ci/tests/pr-open/harness-smoke.sh"
  assert_file_exists "$push" "usr-layer push smoke" || return 1
  assert_executable "$push" "usr-layer push smoke executable" || return 1
  if [ -f "$pr_open" ]; then
    echo "ASSERT FAIL: usr-layer pr-open smoke should be absent in pool/n59+; ci-dispatch no longer fires on pull_request"
    return 1
  fi
}

test_ci_dispatch_list_enumerates_sys_and_usr_layers_e2e() {
  # Pool/n55: ci-dispatch.sh --list emits tab-separated tuples for every
  # discovered script under both sys-layer (.io.v4rian.how-git/ci) and
  # usr-layer (repo-root ci) directories. End-to-end: run --list against
  # the push trigger (which is where the sys-layer required.* audits
  # live post-pool/n58) and assert both layers appear in the output.
  local script="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/workflows/ci-dispatch.sh"
  assert_file_exists "$script" "ci-dispatch.sh" || return 1
  local out
  out=$(cd "$TEMPLATE_ROOT" && bash "$script" --trigger push --list 2>&1)
  echo "$out" | grep -q "^sys" \
    || { echo "no sys-layer line in --list output for push; got: $out"; return 1; }
  echo "$out" | grep -q "^usr" \
    || { echo "no usr-layer line in --list output for push; got: $out"; return 1; }
  echo "$out" | grep -q "required.compile" \
    || { echo "sys-layer required.compile missing from output; got: $out"; return 1; }
  echo "$out" | grep -q "harness-smoke" \
    || { echo "usr-layer harness-smoke missing from output; got: $out"; return 1; }
}

# claim-dev-merge.sh must never reimplement the version math the bin/version
# binary already owns. The single-authority rule is the whole point of the
# claim flow refactor in pool/n36; reintroducing `git describe` or inline
# awk -F. fan-out on the latest tag silently puts the script back on a
# divergent code path from open-pr / build-on-tag / status that all read
# from bin/version. The test is static (greps the script) so the regression
# is loud at PR-review time, not at the next bumped-too-far tag.
test_claim_dev_merge_delegates_to_version_bin() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/claim-dev-merge.sh"
  assert_file_exists "$f" "claim-dev-merge script" || return 1
  # Positive: the script must call bin/version.
  assert_grep "bin/version" "$f" "claim-dev-merge invokes bin/version" || return 1
  # Negative: the legacy inline derivation block must be gone. `git describe`
  # in this script means the version math is duplicated; we reject the diff.
  if grep -q "git describe" "$f"; then
    echo "ASSERT FAIL: claim-dev-merge.sh still calls 'git describe' for version math; must delegate to bin/version"
    return 1
  fi
  # awk -F. on a v* tag was the parser shape of the old block. Reject that too.
  if grep -E -q "awk -F\\\\." "$f"; then
    echo "ASSERT FAIL: claim-dev-merge.sh still parses tag segments with awk -F.; must delegate to bin/version"
    return 1
  fi
}

# Both claim workflows must accept a manual admin dispatch alongside the
# automatic push trigger. The manual path is the operator escape when the
# push-triggered run fails past its retry ceiling; without it the only
# recovery is a fresh commit-and-push cycle just to retrigger the workflow.
#
# Pool/n55 + pool/n58: the standalone claim-on-merge-{dev,main}.yml
# workflows are deleted. The claim recipe now runs via the layered
# ci-dispatch harness — sys-layer required.claim.sh entries under
# ci/audits/pr-merge-{dev,main}/ delegate to claim-retry.sh. The manual
# operator escape is provided by re-running the sys-layer entry locally
# (bash .io.v4rian.how-git/scripts/workflows/claim-retry.sh --target dev)
# or by re-triggering the ci-dispatch workflow from the GitHub UI via the
# "Re-run jobs" button on a previous run. The dedicated workflow_dispatch
# trigger from the legacy yamls is no longer part of the surface.
#
# This test now asserts the new surface: the sys-layer entries exist and
# delegate to claim-retry.sh; the legacy yamls are absent.
test_claim_workflows_accept_workflow_dispatch() {
  local dev_entry="$TEMPLATE_ROOT/.io.v4rian.how-git/ci/audits/pr-merge-dev/required.claim.sh"
  local main_entry="$TEMPLATE_ROOT/.io.v4rian.how-git/ci/audits/pr-merge-main/required.claim.sh"
  assert_file_exists "$dev_entry" "pr-merge-dev sys entry" || return 1
  assert_file_exists "$main_entry" "pr-merge-main sys entry" || return 1
  assert_grep "claim-retry.sh" "$dev_entry" "dev entry dispatches to claim-retry.sh" || return 1
  assert_grep "claim-retry.sh" "$main_entry" "main entry dispatches to claim-retry.sh" || return 1
  for legacy in "$TEMPLATE_ROOT/.github/workflows/claim-on-merge-dev.yml" \
                "$TEMPLATE_ROOT/.github/workflows/claim-on-merge-main.yml"; do
    if [ -f "$legacy" ]; then
      echo "ASSERT FAIL: legacy $(basename $legacy) still present; pool/n55 should have removed it"
      return 1
    fi
  done
}

# Manual dispatches must be gated on the actor being a repo admin. The
# gate uses the same GitHub permission API the allocator workflow uses
# (collaborators/{actor}/permission with .permission == admin). The check
# only fires on manual dispatches; push events skip it because branch
# protection on dev/main already restricted who could land the merge.
#
# Pool/n55 + pool/n58: the standalone claim-on-merge yamls are deleted
# and the workflow_dispatch surface they exposed is no longer wired (the
# manual operator escape is now "re-run" the ci-dispatch run from the
# UI, or invoke claim-retry.sh locally). The verify-actor-admin.sh
# helper is retained for the allocator workflow (which still has
# workflow_dispatch) and for future re-introduction of an admin-gated
# claim dispatch if needed.
test_claim_workflows_gate_manual_dispatch_on_admin() {
  # Verify-actor-admin.sh still ships (used by allocator workflow_dispatch).
  local helper="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/workflows/verify-actor-admin.sh"
  assert_file_exists "$helper" "verify-actor-admin.sh" || return 1
  assert_grep "collaborators/" "$helper" "permission API call in verify-actor-admin.sh" || return 1
  assert_grep "admin required" "$helper" "admin-only gate text in verify-actor-admin.sh" || return 1
  # The legacy yamls (and their per-workflow admin-gate steps) are gone.
  # The sys-layer claim entries do not currently expose a manual dispatch.
  for legacy in "$TEMPLATE_ROOT/.github/workflows/claim-on-merge-dev.yml" \
                "$TEMPLATE_ROOT/.github/workflows/claim-on-merge-main.yml"; do
    if [ -f "$legacy" ]; then
      echo "ASSERT FAIL: legacy $(basename $legacy) still present; pool/n55 should have removed it"
      return 1
    fi
  done
}

# Both claim workflows must wrap the canonical script in an in-workflow
# retry loop so transient API or network failures during tag push,
# Release create, or safety GC ride out without surfacing as a workflow
# failure. The job also needs a long timeout-minutes so the inner backoff
# is not capped by the default 6-hour job wall.
test_claim_workflows_carry_in_workflow_retry() {
  # Pool/n45: the retry loop body moved to scripts/workflows/claim-retry.sh.
  # Pool/n55: the per-workflow yamls migrated to sys-layer required.claim.sh
  # entries that dispatch to claim-retry.sh; the retry shape (MAX_ATTEMPTS,
  # backoff, give-up log) lives in the script.
  local retry="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/workflows/claim-retry.sh"
  assert_file_exists "$retry" "claim-retry.sh" || return 1
  assert_grep 'MAX_ATTEMPTS=' "$retry" "MAX_ATTEMPTS knob in claim-retry.sh" || return 1
  assert_grep 'BASE_DELAY=' "$retry" "BASE_DELAY knob in claim-retry.sh" || return 1
  assert_grep 'MAX_DELAY=' "$retry" "MAX_DELAY knob in claim-retry.sh" || return 1
  grep -q 'delay \* 2' "$retry" \
    || { echo "ASSERT FAIL: backoff doubles per attempt pattern missing in claim-retry.sh"; return 1; }
  assert_grep 'giving up' "$retry" "final-attempt give-up log in claim-retry.sh" || return 1
  # Sys-layer entries dispatch to claim-retry.sh with the expected target.
  local dev_entry="$TEMPLATE_ROOT/.io.v4rian.how-git/ci/audits/pr-merge-dev/required.claim.sh"
  local main_entry="$TEMPLATE_ROOT/.io.v4rian.how-git/ci/audits/pr-merge-main/required.claim.sh"
  assert_file_exists "$dev_entry" "pr-merge-dev sys entry" || return 1
  assert_file_exists "$main_entry" "pr-merge-main sys entry" || return 1
  assert_grep "claim-retry.sh" "$dev_entry" "pr-merge-dev entry dispatches to claim-retry.sh" || return 1
  grep -q -- "--target dev" "$dev_entry" || { echo "ASSERT_GREP FAIL: '--target dev' not in $dev_entry (pr-merge-dev entry targets dev)"; return 1; }
  assert_grep "claim-retry.sh" "$main_entry" "pr-merge-main entry dispatches to claim-retry.sh" || return 1
  grep -q -- "--target main" "$main_entry" || { echo "ASSERT_GREP FAIL: '--target main' not in $main_entry (pr-merge-main entry targets main)"; return 1; }
}

# Regression for the PR #31 → 8899fa7 incident: the Tag drift sanity step in
# both claim-on-merge workflows originally computed COUNT via
# `echo "$DUPS" | grep -c .`, which under the workflow's `shell:
# /usr/bin/bash -e {0}` invocation exits 1 when DUPS is empty (grep finds
# zero matches → exit 1 → the entire step aborts before the canonical claim
# script ever runs). Every dev merge hits the empty path because HEAD does
# not yet carry a tag at preflight time, so the broken step intercepted
# every claim instead of the rare drift case it was meant to catch.
test_tag_drift_step_handles_empty_dups_under_bash_e() {
  # Pool/n45: the tag-drift step's body moved to
  # scripts/workflows/claim-tag-drift-sanity.sh. The workflow yamls now
  # dispatch to it; the empty-input regression guard applies to the
  # script body where the bug would live.
  local script="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/workflows/claim-tag-drift-sanity.sh"
  assert_file_exists "$script" "claim-tag-drift-sanity.sh" || return 1
  if grep -q 'COUNT=\$(echo "\$DUPS" | grep -c \.)' "$script"; then
    echo "ASSERT FAIL: $script still uses brittle COUNT=\$(echo... | grep -c .) — re-introduces empty-input bug"
    return 1
  fi
  assert_grep "COUNT=0" "$script" "empty-safe COUNT=0 default in claim-tag-drift-sanity.sh" || return 1
  assert_grep 'wc -l' "$script" "wc -l counter in claim-tag-drift-sanity.sh" || return 1
  # Pool/n55: the per-workflow yamls migrated to sys-layer claim entries
  # that dispatch through claim-retry.sh → claim-{dev-merge,main-release}.sh.
  # The drift-sanity script is preserved as a standalone helper that
  # operators can invoke directly before re-running a stuck claim, and
  # the regression guard against the empty-DUPS bash -e bug still lives
  # in the script body (asserted above). The legacy yamls that wired it
  # inline are gone.
  if [ -f "$TEMPLATE_ROOT/.github/workflows/claim-on-merge-dev.yml" ]; then
    echo "ASSERT FAIL: legacy claim-on-merge-dev.yml still present; pool/n55 should have removed it"
    return 1
  fi
  # Behavioral: run the fixed step under bash -e on an empty repo (no tags
  # on HEAD) and verify it exits 0 with the no-drift confirmation line.
  local d="$SCRATCH_BASE/tag-drift-empty"
  setup_scratch_repo "$d"
  cd "$d"
  local out rc
  out=$(bash -e -c '
DUPS=$(git tag --points-at HEAD --list "v*" 2>/dev/null | sort -V)
COUNT=0
[ -n "$DUPS" ] && COUNT=$(printf "%s\n" "$DUPS" | wc -l | tr -d " ")
if [ "$COUNT" -gt 1 ]; then
  echo "would self-correct"
else
  echo "→ HEAD has $COUNT v* tag(s); nothing to self-correct"
fi
' 2>&1)
  rc=$?
  assert_eq "$rc" "0" "empty-DUPS case exits 0 under bash -e" || { echo "step output: $out"; return 1; }
  echo "$out" | grep -q "nothing to self-correct" || {
    echo "ASSERT FAIL: empty case did not log no-drift confirmation; got: $out"
    return 1
  }
}

# Pair test for the duplicate-tag arm of the same step: when HEAD carries
# two or more v* tags (the multi-actor race that pool/n28 was created to
# defend against), the step keeps the lowest version and drops the rest
# locally. The whole step must still exit 0 under bash -e.
test_tag_drift_step_self_corrects_duplicate_tags() {
  local d="$SCRATCH_BASE/tag-drift-dupes"
  setup_scratch_repo "$d"
  cd "$d"
  git tag -a v2026.0.23 -m "first claim" HEAD >/dev/null
  git tag -a v2026.0.24 -m "duplicate race claim" HEAD >/dev/null
  local out rc
  out=$(bash -e -c '
DUPS=$(git tag --points-at HEAD --list "v*" 2>/dev/null | sort -V)
COUNT=0
[ -n "$DUPS" ] && COUNT=$(printf "%s\n" "$DUPS" | wc -l | tr -d " ")
if [ "$COUNT" -gt 1 ]; then
  KEEP=$(printf "%s\n" "$DUPS" | head -1)
  echo "→ keeping $KEEP, dropping the rest"
  printf "%s\n" "$DUPS" | tail -n +2 | while read -r t; do
    [ -z "$t" ] && continue
    git tag -d "$t" >/dev/null
  done
fi
' 2>&1)
  rc=$?
  assert_eq "$rc" "0" "duplicate-tag case exits 0 under bash -e" || { echo "step output: $out"; return 1; }
  echo "$out" | grep -q "keeping v2026.0.23" || {
    echo "ASSERT FAIL: did not log keeping lowest tag; got: $out"
    return 1
  }
  local remaining
  remaining=$(git tag --points-at HEAD --list 'v*' | sort -V | tr '\n' ' ')
  assert_eq "$remaining" "v2026.0.23 " "only lowest tag survives self-correct" || return 1
}

test_pair_safety_workflow_removed() {
  # The pair-safety-on-pool-create workflow has been retired. The
  # allocator workflow now creates both the pool/* and safety/*
  # refs atomically in one run, so the post-hoc pair workflow is
  # no longer needed and is gone from .github/workflows/.
  local f="$TEMPLATE_ROOT/.github/workflows/pair-safety-on-pool-create.yml"
  [ ! -e "$f" ] || { echo "pair-safety workflow still present (should be deleted)"; return 1; }
}

# ----------------------------------------------------------------------------
# Allocator: workflow + script + CLI wrapper + rulesets
# ----------------------------------------------------------------------------

test_allocate_workflow_present_and_wired() {
  local f="$TEMPLATE_ROOT/.github/workflows/allocate-pool-branch.yml"
  assert_file_exists "$f" "allocator workflow" || return 1
  # Both trigger shapes wired
  assert_grep "repository_dispatch" "$f" "repository_dispatch trigger" || return 1
  assert_grep "workflow_dispatch" "$f" "workflow_dispatch trigger" || return 1
  # 72h timeout (4320 minutes) wired
  assert_grep "timeout-minutes: 4320" "$f" "72h timeout" || return 1
  # Admin permission check via collaborators API
  assert_grep "collaborators/" "$f" "permission API call" || return 1
  assert_grep "admin required" "$f" "admin-only gate text" || return 1
  # Dispatches to the canonical script
  assert_grep "bash .io.v4rian.how-git/scripts/allocate-pool-branch.sh" "$f" "dispatches to allocator script" || return 1
}

test_allocate_script_present_and_executable() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/allocate-pool-branch.sh"
  assert_file_exists "$f" "allocator script" || return 1
  assert_executable "$f" "allocator script executable" || return 1
  # Idempotency + classification + composition + atomicity all present
  assert_grep "existing_with_jira" "$f" "idempotency function" || return 1
  assert_grep "classify_kind_via_claude" "$f" "classification function" || return 1
  assert_grep "next_n" "$f" "n allocator function" || return 1
  assert_grep "delete_ref" "$f" "rollback delete helper" || return 1
  # Aggressive retry, no give-up
  assert_grep "exponential backoff" "$f" "backoff doc string" || return 1
}

test_allocate_script_rejects_missing_required_inputs() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/allocate-pool-branch.sh"
  local out rc
  # No GITHUB_REPOSITORY → exit 2 with explanatory message
  out=$(env -i bash "$f" --short-name foo --jira PROJ-1 2>&1); rc=$?
  assert_eq "$rc" "2" "exits 2 when repo missing" || { echo "$out"; return 1; }
  echo "$out" | grep -q "GITHUB_REPOSITORY" || { echo "expected GITHUB_REPOSITORY error; got: $out"; return 1; }
  # With repo but no token → exit 2 with token error
  out=$(env -i GITHUB_REPOSITORY=foo/bar bash "$f" --short-name foo --jira PROJ-1 2>&1); rc=$?
  assert_eq "$rc" "2" "exits 2 when token missing" || { echo "$out"; return 1; }
  echo "$out" | grep -q "GH_TOKEN" || { echo "expected GH_TOKEN error; got: $out"; return 1; }
  # With repo + token but bad jira_key → exit 2
  out=$(env -i GITHUB_REPOSITORY=foo/bar GH_TOKEN=t bash "$f" --short-name foo --jira not-a-key 2>&1); rc=$?
  assert_eq "$rc" "2" "exits 2 on invalid jira" || { echo "$out"; return 1; }
  echo "$out" | grep -q "PROJ-NNN" || { echo "expected PROJ-NNN error; got: $out"; return 1; }
}

test_allocate_script_help_flag_works() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/allocate-pool-branch.sh"
  local out rc
  out=$(bash "$f" --help 2>&1); rc=$?
  assert_eq "$rc" "0" "--help exits 0" || return 1
  echo "$out" | grep -q "allocate-pool-branch" || { echo "expected name in help; got: $out"; return 1; }
}

test_create_pool_branch_cli_present_and_executable() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/create-pool-branch"
  assert_file_exists "$f" "create-pool-branch CLI" || return 1
  assert_executable "$f" "create-pool-branch CLI executable" || return 1
  # Calls gh workflow run with the allocator workflow
  assert_grep "gh workflow run allocate-pool-branch.yml" "$f" "dispatches via gh workflow run" || return 1
  # Honors the renamed env var
  assert_grep "CREATE_POOL_BRANCH_TOKEN" "$f" "honors the renamed token env" || return 1
  # Advisory admin check exists
  assert_grep "admin_check" "$f" "advisory admin guard" || return 1
}

test_old_repo_create_branch_binary_removed() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/repo-create-branch"
  [ ! -e "$f" ] || { echo "legacy repo-create-branch binary still present (should be deleted)"; return 1; }
}

test_create_pool_branch_cli_dry_run_no_dispatch() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/create-pool-branch"
  local out rc
  # --dry-run does no API call beyond an advisory probe; it should exit 0
  # even with a bogus token. We use --repo to skip the origin discovery.
  out=$(env GH_TOKEN=bogus PATH="/usr/bin:/bin" bash "$f" parser-rewrite --jira PROJ-1 --repo foo/bar --dry-run 2>&1); rc=$?
  # rc may be 3 when gh is not installed on the test box, otherwise 0.
  case "$rc" in
    0)
      echo "$out" | grep -q "dry-run" || { echo "expected dry-run banner; got: $out"; return 1; }
      ;;
    3)
      echo "$out" | grep -q "gh CLI is required" || { echo "expected gh-missing error; got: $out"; return 1; }
      ;;
    *)
      echo "unexpected rc=$rc; got: $out"
      return 1
      ;;
  esac
}

test_create_pool_branch_cli_rejects_invalid_inputs() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/create-pool-branch"
  local out rc
  # Missing --jira → exit 2
  out=$(bash "$f" foo 2>&1); rc=$?
  assert_eq "$rc" "2" "exits 2 when --jira missing" || { echo "$out"; return 1; }
  # Invalid --kind → exit 2
  out=$(bash "$f" foo --jira PROJ-1 --kind nope 2>&1); rc=$?
  assert_eq "$rc" "2" "exits 2 on invalid --kind" || { echo "$out"; return 1; }
  # Invalid --sprint → exit 2
  out=$(bash "$f" foo --jira PROJ-1 --sprint not-a-number 2>&1); rc=$?
  assert_eq "$rc" "2" "exits 2 on non-integer --sprint" || { echo "$out"; return 1; }
}

test_allocator_off_grid_creates_local_refs() {
  # In off-grid mode the allocator must create the pool+safety pair as
  # local refs via git update-ref --stdin (no Git Data API). The pair
  # must point at the dev tip atomically; either both land or neither.
  local d="$SCRATCH_BASE/alloc-off-grid-creates"; setup_scratch_repo "$d"
  ( cd "$d"
    .io.v4rian.how-git/bin/set-mode off-grid >/dev/null
    git checkout -q -b dev
    local dev_sha; dev_sha=$(git rev-parse HEAD)
    local out; out=$(ALLOC_MODE=off-grid bash .io.v4rian.how-git/scripts/allocate-pool-branch.sh \
      --short-name "probe" --jira "PROJ-1" --kind feature 2>&1)
    echo "$out" | grep -q '"status": "created"' || { echo "expected status=created; got: $out"; return 1; }
    echo "$out" | grep -q '"mode": "off-grid"' || { echo "expected mode=off-grid in json; got: $out"; return 1; }
    # Both refs must exist at the dev tip
    local pool_sha; pool_sha=$(git rev-parse refs/heads/pool/v2026.0/n1.feature.PROJ-1-probe 2>/dev/null || true)
    local safety_sha; safety_sha=$(git rev-parse refs/heads/safety/v2026.0/n1.feature.PROJ-1-probe 2>/dev/null || true)
    [ -n "$pool_sha" ] || { echo "pool ref missing"; return 1; }
    [ "$safety_sha" = "$dev_sha" ] || { echo "safety ref not at dev tip"; return 1; }
    [ "$pool_sha" = "$dev_sha" ] || { echo "pool ref not at dev tip"; return 1; }
  )
}

test_allocator_off_grid_no_jira_omits_segment() {
  # The --no-jira escape hatch is off-grid-only. The branch name must
  # drop the JIRA segment and the pre-push regex must still accept the
  # resulting shape (verified by the pattern in the pre-push hook).
  local d="$SCRATCH_BASE/alloc-off-grid-no-jira"; setup_scratch_repo "$d"
  ( cd "$d"
    .io.v4rian.how-git/bin/set-mode off-grid >/dev/null
    git checkout -q -b dev
    local out; out=$(ALLOC_MODE=off-grid bash .io.v4rian.how-git/scripts/allocate-pool-branch.sh \
      --short-name "local-only" --kind feature --no-jira 2>&1)
    echo "$out" | grep -q '"branch_name": "pool/v2026.0/n1.feature.local-only"' \
      || { echo "expected no-jira branch name; got: $out"; return 1; }
    # Connected mode must reject --no-jira
    .io.v4rian.how-git/bin/set-mode connected >/dev/null
    local out2; out2=$(ALLOC_MODE=connected bash .io.v4rian.how-git/scripts/allocate-pool-branch.sh \
      --short-name "x" --kind feature --no-jira 2>&1); local rc=$?
    [ "$rc" -eq 2 ] || { echo "connected --no-jira must exit 2; got rc=$rc out=$out2"; return 1; }
    echo "$out2" | grep -q "off-grid-only" || { echo "missing off-grid-only message; got: $out2"; return 1; }
  )
}

test_create_pool_branch_cli_off_grid_invokes_allocator_locally() {
  # The CLI wrapper must dispatch to the local allocator script (NOT gh
  # workflow run) when MODE is off-grid. --dry-run announces the planned
  # invocation; the actual run produces the pair as local refs.
  local d="$SCRATCH_BASE/cpb-off-grid"; setup_scratch_repo "$d"
  ( cd "$d"
    .io.v4rian.how-git/bin/set-mode off-grid >/dev/null
    git checkout -q -b dev
    # Dry-run path
    local out; out=$(bash .io.v4rian.how-git/bin/create-pool-branch parser-rewrite \
      --no-jira --kind feature --dry-run 2>&1)
    echo "$out" | grep -q "mode: off-grid" || { echo "missing mode banner in dry-run; got: $out"; return 1; }
    echo "$out" | grep -q "would call: bash .*/allocate-pool-branch.sh --mode off-grid" \
      || { echo "dry-run did not advertise local allocator invocation; got: $out"; return 1; }
    if echo "$out" | grep -q "gh workflow run"; then
      echo "dry-run advertised gh workflow run in off-grid mode; got: $out"; return 1
    fi
    # Live path
    local out2; out2=$(bash .io.v4rian.how-git/bin/create-pool-branch parser-rewrite \
      --no-jira --kind feature 2>&1)
    echo "$out2" | grep -q "allocated locally" \
      || { echo "live off-grid run did not announce local allocation; got: $out2"; return 1; }
    git rev-parse refs/heads/pool/v2026.0/n1.feature.parser-rewrite >/dev/null 2>&1 \
      || { echo "live off-grid run did not create the pool ref"; return 1; }
    git rev-parse refs/heads/safety/v2026.0/n1.feature.parser-rewrite >/dev/null 2>&1 \
      || { echo "live off-grid run did not create the safety ref"; return 1; }
  )
}

test_rulesets_present_and_pin_to_allocator_identity() {
  local pool="$TEMPLATE_ROOT/.io.v4rian.how-git/rulesets/pool-creations.json"
  local safety="$TEMPLATE_ROOT/.io.v4rian.how-git/rulesets/safety-lockdown.json"
  assert_file_exists "$pool" "pool-creations ruleset" || return 1
  assert_file_exists "$safety" "safety-lockdown ruleset" || return 1
  # pool ruleset gates creation only
  assert_grep "refs/heads/pool/\\*" "$pool" "pool target prefix" || return 1
  assert_grep '"type": "creation"' "$pool" "pool creation rule" || return 1
  # safety ruleset gates creation + update + deletion
  assert_grep "refs/heads/safety/\\*" "$safety" "safety target prefix" || return 1
  assert_grep '"type": "creation"' "$safety" "safety creation rule" || return 1
  assert_grep '"type": "update"' "$safety" "safety update rule" || return 1
  assert_grep '"type": "deletion"' "$safety" "safety deletion rule" || return 1
  # Both files are valid JSON (sans comment field tolerance via python json)
  python3 -c "import json,sys; [json.load(open(p)) for p in sys.argv[1:]]" "$pool" "$safety" \
    || { echo "ruleset JSON failed to parse"; return 1; }
}

# ----------------------------------------------------------------------------
# Active requirement (pool/n51 step): every pool branch carries a canonical
# "active requirement" document so auditors that invoke claude can fetch
# the branch's intent. The allocator writes it to the tracked file at
# .io.v4rian.how-git/active-requirement AND as the body of the initial
# [REQ] commit on the pool branch. The helper script get-active-requirement.sh
# fetches the text from either source. Auditors prepend the text to every
# claude prompt.
# ----------------------------------------------------------------------------

test_allocator_accepts_requirement_flags() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/allocate-pool-branch.sh"
  # CLI flag and env var both wired
  assert_grep "[-][-]requirement)" "$f" "--requirement flag parsed" || return 1
  assert_grep "[-][-]requirement-file)" "$f" "--requirement-file flag parsed" || return 1
  assert_grep "ALLOC_REQUIREMENT" "$f" "ALLOC_REQUIREMENT env honored" || return 1
  assert_grep "ALLOC_REQUIREMENT_FILE" "$f" "ALLOC_REQUIREMENT_FILE env honored" || return 1
  # File-missing path errors out (exit 2)
  local out rc
  out=$(env -i GITHUB_REPOSITORY=foo/bar GH_TOKEN=t bash "$f" --short-name foo --jira PROJ-1 --requirement-file /nonexistent/path 2>&1); rc=$?
  assert_eq "$rc" "2" "exits 2 when requirement-file does not exist" || { echo "$out"; return 1; }
  echo "$out" | grep -q "requirement file" || { echo "expected requirement file error; got: $out"; return 1; }
}

test_allocator_writes_requirement_commit_when_supplied() {
  # Static inspection — the allocator script must contain the Git Data API
  # plumbing that turns the supplied requirement into a blob + tree + commit
  # on the pool branch (NOT on safety, which stays at the dev tip).
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/allocate-pool-branch.sh"
  assert_grep "git/blobs" "$f" "creates blob via Git Data API" || return 1
  assert_grep "git/trees" "$f" "creates tree via Git Data API" || return 1
  assert_grep "git/commits" "$f" "creates commit via Git Data API" || return 1
  assert_grep "\\[REQ\\] active-requirement:" "$f" "commit title is [REQ] active-requirement" || return 1
  assert_grep ".io.v4rian.how-git/active-requirement" "$f" "writes requirement file at canonical path" || return 1
  # Output JSON exposes the requirement commit SHA and a boolean.
  assert_grep "requirement_commit_sha" "$f" "output JSON exposes requirement_commit_sha" || return 1
  assert_grep "has_requirement" "$f" "output JSON exposes has_requirement boolean" || return 1
}

test_get_active_requirement_helper_present_and_executable() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/get-active-requirement.sh"
  assert_file_exists "$f" "get-active-requirement helper" || return 1
  assert_executable "$f" "get-active-requirement helper executable" || return 1
  # Reads BOTH sources — tracked file first, then [REQ] commit body fallback.
  assert_grep "active-requirement" "$f" "knows the canonical file path" || return 1
  assert_grep "git show" "$f" "reads tracked file via git show" || return 1
  # The helper's subject test uses POSIX-style prefix-strip "${subj#\[REQ\] active-requirement:}"
  # which contains backslash-escaped brackets in the source. Match the
  # invariant subject prefix without bracket characters to stay portable.
  assert_grep "REQ.. active-requirement:" "$f" "fallback scans for [REQ] commit subject" || return 1
  # Empty-output / exit-0 semantics for legacy branches.
  assert_grep "exit 0" "$f" "exits 0 when no requirement" || return 1
  # Syntax clean.
  bash -n "$f" 2>&1 || { echo "get-active-requirement.sh has syntax errors"; return 1; }
}

test_get_active_requirement_helper_extracts_file_content_from_branch() {
  # End-to-end behaviour test: build a scratch repo, simulate a pool branch
  # that has the active-requirement file committed, then call the helper
  # and confirm it returns the file content verbatim.
  local d="$SCRATCH_BASE/req-file"
  setup_scratch_repo "$d"
  ( cd "$d"
    git checkout -q -b dev
    git push -q origin dev
    git checkout -q -b "pool/n99.feature.PROJ-7-helper-test"
    mkdir -p .io.v4rian.how-git
    printf 'Rewrite the parser to handle nested blocks.' > .io.v4rian.how-git/active-requirement
    git -c user.email=test@test -c user.name=test add .io.v4rian.how-git/active-requirement
    git -c user.email=test@test -c user.name=test commit -q --no-verify \
      -m "[REQ] active-requirement: pool/n99.feature.PROJ-7-helper-test" \
      -m "Rewrite the parser to handle nested blocks."
    out=$(bash "$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/get-active-requirement.sh" HEAD)
    [ "$out" = "Rewrite the parser to handle nested blocks." ] \
      || { echo "expected requirement content; got: [$out]"; exit 1; }
  ) || return 1
}

test_get_active_requirement_helper_falls_back_to_commit_body() {
  # When the tracked file is absent at the branch tip but the initial [REQ]
  # commit exists, the helper extracts the body. Simulate by committing the
  # file in a [REQ] commit then deleting it in a follow-up commit so the
  # tracked-file lookup at tip returns empty.
  local d="$SCRATCH_BASE/req-body"
  setup_scratch_repo "$d"
  ( cd "$d"
    git checkout -q -b dev
    git push -q origin dev
    git checkout -q -b "pool/n100.feature.PROJ-8-body-test"
    mkdir -p .io.v4rian.how-git
    printf 'Initial body content' > .io.v4rian.how-git/active-requirement
    git -c user.email=test@test -c user.name=test add .io.v4rian.how-git/active-requirement
    git -c user.email=test@test -c user.name=test commit -q --no-verify \
      -m "[REQ] active-requirement: pool/n100.feature.PROJ-8-body-test" \
      -m "The branch must add a JSON exporter to the parser."
    git rm -q .io.v4rian.how-git/active-requirement
    git -c user.email=test@test -c user.name=test commit -q --no-verify \
      -m "[REFACTOR] Drop the active-requirement file for the fallback test"
    out=$(bash "$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/get-active-requirement.sh" HEAD)
    out_trim=$(printf '%s' "$out" | sed -E 's/[[:space:]]+$//')
    [ "$out_trim" = "The branch must add a JSON exporter to the parser." ] \
      || { echo "expected commit body fallback; got: [$out_trim]"; exit 1; }
  ) || return 1
}

test_get_active_requirement_helper_empty_for_legacy_branch() {
  # Legacy branches that predate this lifecycle step have neither the file
  # nor a [REQ] commit. The helper must exit 0 with empty stdout so callers
  # can proceed without context.
  local d="$SCRATCH_BASE/req-empty"
  setup_scratch_repo "$d"
  ( cd "$d"
    git checkout -q -b dev
    git push -q origin dev
    git checkout -q -b "pool/n101.feature.PROJ-9-legacy"
    printf 'console.log("hello");\n' > feature.js
    git -c user.email=test@test -c user.name=test add feature.js
    git -c user.email=test@test -c user.name=test commit -q --no-verify -m "[NEW] Hello feature"
    out=$(bash "$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/get-active-requirement.sh" HEAD); rc=$?
    [ "$rc" = "0" ] || { echo "expected exit 0; got rc=$rc, out=[$out]"; exit 1; }
    [ -z "$out" ]   || { echo "expected empty stdout; got: [$out]"; exit 1; }
  ) || return 1
}

test_get_active_requirement_helper_rejects_missing_arg() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/get-active-requirement.sh"
  local out rc
  out=$(bash "$f" 2>&1); rc=$?
  assert_eq "$rc" "2" "exits 2 when branch argument missing" || { echo "$out"; return 1; }
  echo "$out" | grep -q "missing branch argument" || { echo "expected usage error; got: $out"; return 1; }
}

test_auto_rebase_includes_active_requirement_in_claude_prompts() {
  # The L1-L5 ladder must call get-active-requirement.sh for the head
  # branch and prepend the result to every claude prompt (the REQ_HEADER
  # variable). Static inspection confirms the wiring.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/auto-rebase-pools-after-dev-merge.sh"
  assert_grep "get-active-requirement.sh" "$f" "calls get-active-requirement.sh" || return 1
  assert_grep "ACTIVE_REQUIREMENT=" "$f" "captures requirement into variable" || return 1
  assert_grep "REQ_HEADER=" "$f" "composes REQ_HEADER for claude prompt" || return 1
  # Every level (1..5) in attempt_resolve must include REQ_HEADER.
  for level in 1 2 3 4 5; do
    grep -E "^[[:space:]]*${level}\\) ctx=\"\\\$\\{REQ_HEADER\\}" "$f" >/dev/null \
      || { echo "L${level} prompt does not prepend REQ_HEADER in attempt_resolve"; return 1; }
  done
}

test_post_checkout_includes_active_requirement_in_claude_prompt() {
  # post-checkout invokes claude_skill_run for git-snapshot-preflight; the
  # active-requirement should be prepended so claude treats the branch's
  # canonical intent as context.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/githooks/post-checkout"
  assert_grep "get-active-requirement.sh" "$f" "post-checkout calls get-active-requirement.sh" || return 1
  assert_grep "REQ_HEADER" "$f" "post-checkout composes REQ_HEADER" || return 1
  grep -E 'claude_skill_run git-snapshot-preflight "\$\{REQ_HEADER\}' "$f" >/dev/null \
    || { echo "claude_skill_run call does not prepend REQ_HEADER"; return 1; }
}

test_allocator_workflow_forwards_requirement_input() {
  local f="$TEMPLATE_ROOT/.github/workflows/allocate-pool-branch.yml"
  # workflow_dispatch input + repository_dispatch client_payload + env wiring.
  assert_grep "requirement:" "$f" "requirement workflow input declared" || return 1
  assert_grep "client_payload.requirement" "$f" "client_payload.requirement read" || return 1
  assert_grep "ALLOC_REQUIREMENT:" "$f" "ALLOC_REQUIREMENT env wired to script" || return 1
}

test_create_pool_branch_cli_forwards_requirement_flags() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/create-pool-branch"
  assert_grep "[-][-]requirement)" "$f" "--requirement flag parsed" || return 1
  assert_grep "[-][-]requirement-file)" "$f" "--requirement-file flag parsed" || return 1
  assert_grep 'requirement=' "$f" "forwards requirement to gh workflow run" || return 1
  # File-missing → exit 2.
  local out rc
  out=$(bash "$f" foo --jira PROJ-1 --requirement-file /nonexistent/path 2>&1); rc=$?
  assert_eq "$rc" "2" "CLI exits 2 when requirement-file does not exist" || { echo "$out"; return 1; }
}

# ----------------------------------------------------------------------------
# PR open (Step 3): PULL_REQUEST_TEMPLATE + validate-pr-open workflow +
# canonical script + init-pool-merge + init-release CLIs
# ----------------------------------------------------------------------------

test_pull_request_template_present_and_carries_sections() {
  local f="$TEMPLATE_ROOT/.github/PULL_REQUEST_TEMPLATE.md"
  assert_file_exists "$f" "PR template" || return 1
  # Macro sections per the v4rian model.
  assert_grep "## Summary" "$f" "Summary section" || return 1
  assert_grep "## Cause" "$f" "Cause section (conditional on FIX tag)" || return 1
  assert_grep "## Changes" "$f" "Changes section" || return 1
  # The signature marker the validate-pr-open workflow keys off.
  assert_grep "opened-via-correct-flow" "$f" "workflow signature marker" || return 1
}

test_validate_pr_open_workflow_present_and_wired() {
  local f="$TEMPLATE_ROOT/.github/workflows/validate-pr-open.yml"
  assert_file_exists "$f" "validate-pr-open workflow" || return 1
  # Triggers on pull_request opened, edited, synchronize against dev + main.
  assert_grep "pull_request" "$f" "pull_request trigger" || return 1
  assert_grep "opened" "$f" "opened type" || return 1
  assert_grep "edited" "$f" "edited type" || return 1
  assert_grep "synchronize" "$f" "synchronize type" || return 1
  assert_grep "- dev" "$f" "dev branch filter" || return 1
  assert_grep "- main" "$f" "main branch filter" || return 1
  # Required scopes: PR amendment + status posting.
  assert_grep "pull-requests: write" "$f" "pull-requests scope" || return 1
  assert_grep "statuses: write" "$f" "statuses scope" || return 1
  # Dispatches the canonical script.
  assert_grep "bash .io.v4rian.how-git/scripts/validate-pr-open.sh" "$f" "dispatches to validate-pr-open.sh" || return 1
  # Forwards the PR metadata the script needs.
  for var in PR_NUMBER PR_HEAD_REF PR_BASE_REF PR_HEAD_SHA PR_ACTOR; do
    assert_grep "$var:" "$f" "$var env wired" || return 1
  done
}

test_validate_pr_open_script_present_and_executable() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/validate-pr-open.sh"
  assert_file_exists "$f" "validate-pr-open script" || return 1
  assert_executable "$f" "validate-pr-open script executable" || return 1
  # Sources the shared auto-fix library.
  assert_grep "auto-fix-commit-message.sh" "$f" "sources shared auto-fix library" || return 1
  # Posts the canonical status check context.
  assert_grep "opened-via-correct-flow" "$f" "posts opened-via-correct-flow status context" || return 1
  # Checks actor permission via collaborators API (same shape as the allocator).
  assert_grep "collaborators/" "$f" "actor permission API call" || return 1
  assert_grep "admin" "$f" "admin-required gate" || return 1
  # Embeds the workflow run_id in the signature.
  assert_grep "run=" "$f" "signature carries run id" || return 1
  # gh pr edit, gh pr close still wired (title derivation moved to claim
  # scripts in pool/n39; body amendment via gh pr edit remains).
  assert_grep "gh pr edit" "$f" "amends PR body via gh pr edit" || return 1
  assert_grep "gh pr close" "$f" "closes PR via gh pr close on rule violation" || return 1
}

test_validate_pr_open_script_syntax_clean() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/validate-pr-open.sh"
  bash -n "$f" 2>&1 || { echo "validate-pr-open.sh has syntax errors"; return 1; }
}

test_validate_pr_open_script_test_mode_short_circuit() {
  # In LIFECYCLE_TEST_MODE without PR_NUMBER set, the script should exit
  # cleanly so it can be sourced or invoked without a live gh API.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/validate-pr-open.sh"
  local out rc
  out=$(env -i LIFECYCLE_TEST_MODE=1 PATH="$PATH" bash "$f" 2>&1); rc=$?
  assert_eq "$rc" "0" "exits 0 under test mode without PR_NUMBER" || { echo "got: $out"; return 1; }
  echo "$out" | grep -q "test-mode" || { echo "expected test-mode banner; got: $out"; return 1; }
}

test_validate_pr_open_script_env_contract_validation() {
  # When NOT in test mode and required env vars are missing, the script
  # must exit 3 with a clear message naming the missing var.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/validate-pr-open.sh"
  local out rc
  out=$(env -i PATH="$PATH" PR_NUMBER=1 bash "$f" 2>&1); rc=$?
  assert_eq "$rc" "3" "exits 3 on missing env var" || { echo "got: $out"; return 1; }
  echo "$out" | grep -q "required env var" || { echo "expected env-contract error; got: $out"; return 1; }
}

test_init_pool_merge_cli_present_and_executable() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/init-pool-merge"
  assert_file_exists "$f" "init-pool-merge CLI" || return 1
  assert_executable "$f" "init-pool-merge CLI executable" || return 1
  # Dispatches gh pr create with the right base.
  assert_grep "gh pr create" "$f" "calls gh pr create" || return 1
  grep -q -- "--base dev" "$f" || { echo "ASSERT_GREP FAIL: --base dev not in $f"; return 1; }
  # Loads the template skeleton when available.
  assert_grep "PULL_REQUEST_TEMPLATE.md" "$f" "loads PR template skeleton" || return 1
  # Advisory admin guard.
  assert_grep "admin" "$f" "advisory admin guard" || return 1
  # Honors the same token chain as create-pool-branch.
  assert_grep "CREATE_POOL_BRANCH_TOKEN" "$f" "honors the standard token env" || return 1
}

test_init_pool_merge_help_flag_works() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/init-pool-merge"
  local out rc
  out=$(bash "$f" --help 2>&1); rc=$?
  assert_eq "$rc" "0" "--help exits 0" || return 1
  echo "$out" | grep -q "init-pool-merge" || { echo "expected name in help; got: $out"; return 1; }
}

test_init_pool_merge_rejects_non_pool_branch() {
  local d="$SCRATCH_BASE/n35-ipm-branch"
  setup_scratch_repo "$d"
  cd "$d"
  # main is the default branch in the scratch repo; init-pool-merge should reject.
  local out rc
  out=$(bash .io.v4rian.how-git/bin/init-pool-merge --dry-run 2>&1); rc=$?
  [ "$rc" -ne 0 ] || { echo "init-pool-merge accepted main as source (expected rejection); got: $out"; return 1; }
  echo "$out" | grep -q "pool/nN.kind" || { echo "expected branch-shape error; got: $out"; return 1; }
}

test_init_pool_merge_dry_run_on_clean_pool_branch() {
  local d="$SCRATCH_BASE/n35-ipm-dryrun"
  setup_scratch_repo "$d"
  cd "$d"
  git checkout -q -b dev
  git push -q origin dev
  git checkout -q -b pool/n1.feature.probe
  echo probe > p.txt
  git -c user.email=t@t -c user.name=t add p.txt
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] probe"
  git push -q origin pool/n1.feature.probe
  # Dry-run should reach the dispatch-banner before any gh call.
  local out rc
  out=$(bash .io.v4rian.how-git/bin/init-pool-merge --dry-run --repo j/m 2>&1); rc=$?
  # rc may be 3 when gh CLI is unavailable on the test box (no advisory check).
  case "$rc" in
    0)
      echo "$out" | grep -q "dry-run" || { echo "expected dry-run banner; got: $out"; return 1; }
      echo "$out" | grep -q "base:        dev" || { echo "expected base=dev in dry-run; got: $out"; return 1; }
      ;;
    3|4)
      echo "$out" | grep -qE "gh CLI is required|admin required|no GitHub token" || { echo "unexpected rc=$rc error; got: $out"; return 1; }
      ;;
    *)
      echo "unexpected rc=$rc; got: $out"
      return 1
      ;;
  esac
}

test_init_release_cli_present_and_executable() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/init-release"
  assert_file_exists "$f" "init-release CLI" || return 1
  assert_executable "$f" "init-release CLI executable" || return 1
  # Dispatches gh pr create with main as base, dev as head.
  assert_grep "gh pr create" "$f" "calls gh pr create" || return 1
  grep -q -- "--base main" "$f" || { echo "ASSERT_GREP FAIL: --base main not in $f"; return 1; }
  grep -q -- "--head dev" "$f" || { echo "ASSERT_GREP FAIL: --head dev not in $f"; return 1; }
  # Pre-fills body from CHANGELOG Unreleased section.
  assert_grep "CHANGELOG.md" "$f" "references CHANGELOG.md" || return 1
  assert_grep "Unreleased" "$f" "extracts Unreleased section" || return 1
  # Same advisory admin guard.
  assert_grep "admin" "$f" "advisory admin guard" || return 1
}

test_init_release_help_flag_works() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/init-release"
  local out rc
  out=$(bash "$f" --help 2>&1); rc=$?
  assert_eq "$rc" "0" "--help exits 0" || return 1
  echo "$out" | grep -q "init-release" || { echo "expected name in help; got: $out"; return 1; }
}

test_init_release_rejects_non_dev_branch() {
  local d="$SCRATCH_BASE/n35-ir-branch"
  setup_scratch_repo "$d"
  cd "$d"
  # main is the default branch; init-release should reject (only dev opens release PRs).
  local out rc
  out=$(bash .io.v4rian.how-git/bin/init-release --dry-run 2>&1); rc=$?
  [ "$rc" -ne 0 ] || { echo "init-release accepted main as source (expected rejection); got: $out"; return 1; }
  echo "$out" | grep -q "is not dev" || { echo "expected dev-only error; got: $out"; return 1; }
}

test_init_release_dry_run_on_clean_dev_branch() {
  local d="$SCRATCH_BASE/n35-ir-dryrun"
  setup_scratch_repo "$d"
  cd "$d"
  git checkout -q -b dev
  git push -q origin dev
  local out rc
  out=$(bash .io.v4rian.how-git/bin/init-release --dry-run --repo j/m 2>&1); rc=$?
  case "$rc" in
    0)
      echo "$out" | grep -q "dry-run" || { echo "expected dry-run banner; got: $out"; return 1; }
      echo "$out" | grep -q "base:        main" || { echo "expected base=main in dry-run; got: $out"; return 1; }
      echo "$out" | grep -q "head:        dev" || { echo "expected head=dev in dry-run; got: $out"; return 1; }
      ;;
    3|4)
      echo "$out" | grep -qE "gh CLI is required|admin required|no GitHub token" || { echo "unexpected rc=$rc error; got: $out"; return 1; }
      ;;
    *)
      echo "unexpected rc=$rc; got: $out"
      return 1
      ;;
  esac
}

test_validate_pr_open_signature_format_is_html_comment() {
  # The signature embedded in the PR body must be a comment that
  # renders to nothing in the markdown view but is recoverable by the
  # workflow on re-runs. Verify the script's signature template uses
  # the HTML-comment shape with the run id substitution.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/validate-pr-open.sh"
  assert_grep "<!-- opened-via-correct-flow run=" "$f" "signature is HTML comment" || return 1
  grep -q -- "-->" "$f" || { echo "ASSERT_GREP FAIL: --> not in $f"; return 1; }
}

test_auto_rebase_script_present_and_wired() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/auto-rebase-pools-after-dev-merge.sh"
  assert_file_exists "$f" "auto-rebase script" || return 1
  assert_executable "$f" "auto-rebase script executable" || return 1
  local claim="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/claim-dev-merge.sh"
  assert_grep "auto-rebase-pools-after-dev-merge.sh" "$claim" "claim-dev-merge invokes auto-rebase" || return 1
}

test_auto_rebase_short_circuits_in_test_mode() {
  local d="$SCRATCH_BASE/22h-autorebase-testmode"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  local out
  out=$(LIFECYCLE_TEST_MODE=1 bash .io.v4rian.how-git/scripts/auto-rebase-pools-after-dev-merge.sh 2>&1)
  echo "$out" | grep -q "test-mode" || {
    echo "expected test-mode short-circuit log; got:"; echo "$out"; return 1; }
}

test_auto_rebase_never_force_pushes_developer_branches() {
  # Pool/n43 invariant: the auto-rebase pass NEVER rewrites a dev's
  # pool/* branch. No git push --force-* lines should reference any
  # developer ref. The only acceptable force is `git worktree remove
  # --force` for cleanup.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/auto-rebase-pools-after-dev-merge.sh"
  if grep -nE 'git push[^|]*--force' "$f" | grep -v 'worktree'; then
    echo "auto-rebase script has a git push --force line; the principle is no-rewrite of developer branches"
    return 1
  fi
  if grep -nE '--force-with-lease' "$f"; then
    echo "auto-rebase script has a --force-with-lease line; the reconcile-branch path uses CREATE, not lease-protected updates"
    return 1
  fi
}

test_auto_rebase_never_closes_or_opens_prs() {
  # Pool/n43 invariant: the auto-rebase pass leaves the original PR
  # untouched. No `gh pr close` (would close the dev's PR on their
  # behalf), no `gh pr create` (would open a separate [RECONCILE] PR
  # that bypasses the dev's record).
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/auto-rebase-pools-after-dev-merge.sh"
  if grep -nE 'gh pr close' "$f"; then
    echo "auto-rebase script has a gh pr close line; admin is the sole merge decider, not the auto-rebase pass"
    return 1
  fi
  if grep -nE 'gh pr create' "$f"; then
    echo "auto-rebase script has a gh pr create line; the reconcile flow comments on the existing PR rather than opening a new one"
    return 1
  fi
}

test_auto_rebase_comments_on_existing_pr_in_both_paths() {
  # Pool/n43: both the ALL_CLEAN (cherry-pick succeeded) and partial
  # (L1-L5 exhausted) paths must comment on the EXISTING PR with the
  # recap. Without the comment, the dev/admin would have no visibility
  # into what the auto-rebase produced.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/auto-rebase-pools-after-dev-merge.sh"
  # At least three gh pr comment invocations: two for the safety-net
  # paths (OLD_BASE empty, worktree fail) + two for the result paths
  # (ALL_CLEAN, partial). Total >= 4.
  local n
  n=$(grep -cE '^\s*gh pr comment\b' "$f")
  if [ "$n" -lt 4 ]; then
    echo "expected >= 4 gh pr comment sites; found $n"; return 1
  fi
  # Both result paths must reference the reconcile branch name in the comment body
  grep -qE 'RECON_BRANCH.*via' "$f" \
    || grep -qE 'tree/.*RECON_BRANCH' "$f" \
    || { echo "comment body does not link to or name the reconcile branch"; return 1; }
}

test_auto_rebase_docstring_states_no_rewrite_principle() {
  # The script's docstring must explicitly call out the no-rewrite
  # principle so any future maintainer reading the top of the file
  # sees the contract before touching the logic.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/auto-rebase-pools-after-dev-merge.sh"
  grep -qE 'NEVER mutates a developer' "$f" \
    || { echo "docstring missing the 'NEVER mutates a developer' principle"; return 1; }
  grep -qE 'NEVER closes or opens' "$f" \
    || { echo "docstring missing the 'NEVER closes or opens' principle"; return 1; }
  grep -qE 'sole merge decider|admin decides' "$f" \
    || { echo "docstring missing the admin-is-decider phrasing"; return 1; }
  grep -qE 'feedback_how_git_never_rewrites_history' "$f" \
    || { echo "docstring missing the cross-reference to feedback_how_git_never_rewrites_history"; return 1; }
}

test_auto_rebase_no_pool_pattern_skip() {
  # The auto-rebase regex must reject malformed heads and accept both the
  # legacy flat layout (pool/nN.kind.short) and the vYYYY.MAIN/-prefixed
  # layout introduced when active pool/safety allocation gained release-line
  # classification.
  local POOL_PATTERN='^pool/(v[0-9]{4}\.[0-9]+/)?n[0-9]+\.(feature|fix|r&d|refactor|reconcile|doc)\.(sprint[0-9]+-)?([A-Z]+-[0-9]+-)?[a-z0-9][a-z0-9-]*$'
  for bad in "feature/foo" "pool/foo" "pool/n3.feature.with_underscore" "pool/v2026/n3.feature.x" "pool/v2026.0.0/n3.feature.x"; do
    if [[ "$bad" =~ $POOL_PATTERN ]]; then
      echo "auto-rebase regex incorrectly matched $bad"; return 1
    fi
  done
  for good in \
    "pool/n1.feature.parser-rewrite" \
    "pool/n12.r&d.sprint5-PROJ-456-embedding-cache" \
    "pool/v2026.0/n1.feature.parser-rewrite" \
    "pool/v2026.0/n12.r&d.sprint5-PROJ-456-embedding-cache"; do
    [[ "$good" =~ $POOL_PATTERN ]] || { echo "auto-rebase regex incorrectly rejected $good"; return 1; }
  done
}

test_version_bin_present_and_executable() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/version"
  assert_file_exists "$f" "version bin" || return 1
  assert_executable "$f" "version bin executable" || return 1
}

test_version_bin_initial_state_is_year_zero_zero() {
  local d="$SCRATCH_BASE/22s-ver-init"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  local out; out=$(.io.v4rian.how-git/bin/version --seal)
  local year; year=$(date -u +%Y)
  assert_eq "$out" "v${year}.0.0" "initial seal is vYEAR.0.0" || return 1
}

test_version_bin_counts_dev_merges_from_git_log() {
  local d="$SCRATCH_BASE/22t-ver-devmerges"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev
  for i in 1 2 3; do
    git checkout -q -b "pool/n${i}.feature.probe"
    echo "$i" > "probe$i"
    git -c user.email=t@t -c user.name=t add "probe$i"
    git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] probe $i"
    git checkout -q dev
    git -c user.email=t@t -c user.name=t merge --no-ff "pool/n${i}.feature.probe" -m "[MERGE] pool/n${i} into dev"
  done
  local year; year=$(date -u +%Y)
  assert_eq "$(.io.v4rian.how-git/bin/version --seal)" "v${year}.0.3" "3 dev merges -> seal v${year}.0.3" || return 1
  assert_eq "$(.io.v4rian.how-git/bin/version --next-dev)" "v${year}.0.4" "next-dev advances by 1" || return 1
}

test_version_bin_release_bumps_series_and_resets_dev() {
  # Updated for the locked formula: cycle DOES bump on main merge.
  # SERIES = count(main merges), DEV resets to 0-indexed in cycle 1+.
  # The release tag value (--release-tag) is the latest dev tag from
  # the prior cycle (same code = same version), but post-release on
  # dev the SERIES has incremented and DEV slot resets, so the next
  # dev merge tags v.{SERIES+1}.0 (not v.{SERIES}.{count+1}).
  local d="$SCRATCH_BASE/22u-ver-cycle"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev
  git checkout -q -b pool/n1.feature.probe
  echo a > probe
  git -c user.email=t@t -c user.name=t add probe
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] probe"
  git checkout -q dev
  git -c user.email=t@t -c user.name=t merge --no-ff pool/n1.feature.probe -m "[MERGE] pool/n1 into dev"
  # dev->main no-ff merge (release)
  git checkout -q main
  git -c user.email=t@t -c user.name=t merge --no-ff dev -m "[MERGE] dev into main: release"
  local year; year=$(date -u +%Y)
  # Same code = same version: --release-tag returns the latest dev tag from the just-closed cycle.
  assert_eq "$(.io.v4rian.how-git/bin/version --release-tag)" "v${year}.0.1" "release-tag = prior-cycle dev tag (v${year}.0.1, same code = same version)" || return 1
  # Back on dev, SERIES has bumped to 1; --seal falls back to the latest reachable tag (cycle 0's last dev tag).
  git checkout -q dev
  assert_eq "$(.io.v4rian.how-git/bin/version --seal)" "v${year}.0.1" "post-release seal falls back to prior cycle's last tag until new cycle has a dev merge" || return 1
  # --next-dev now predicts the FIRST dev integration of cycle 1: v.YEAR.1.0 (no +1 in cycle 1+).
  assert_eq "$(.io.v4rian.how-git/bin/version --next-dev)" "v${year}.1.0" "post-release next-dev = v${year}.1.0 (cycle 1 starts at 0-indexed)" || return 1
  # First dev merge of cycle 1: --seal becomes v.YEAR.1.0 (the cycle's anchor).
  git checkout -q -b pool/n2.feature.next
  echo b > probe2
  git -c user.email=t@t -c user.name=t add probe2
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] next"
  git checkout -q dev
  git -c user.email=t@t -c user.name=t merge --no-ff pool/n2.feature.next -m "[MERGE] pool/n2 into dev"
  assert_eq "$(.io.v4rian.how-git/bin/version --seal)" "v${year}.1.0" "first dev merge of cycle 1 -> seal v${year}.1.0 (cycle bumped, dev 0-indexed)" || return 1
  assert_eq "$(.io.v4rian.how-git/bin/version --next-dev)" "v${year}.1.1" "next-dev after first cycle-1 merge = v${year}.1.1" || return 1
}

# Comprehensive walk-through that exercises EVERY transition: cycle 0
# starting at 1-indexed, post-main reset to 0-indexed in cycle 1, dev
# merges within cycle 1, second main merge into cycle 2, dev merges in
# cycle 2. At each step both --seal and --next-dev are asserted. This
# is the behavioral counterpart of the 10-event sequence in
# reference_v4rian_version_derivation_logic.
test_version_bin_full_lifecycle_sequence() {
  local d="$SCRATCH_BASE/22u-ver-full-lifecycle"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev
  local year; year=$(date -u +%Y)
  local v
  local i
  # ---- Cycle 0: 4 dev merges, each one bumps DEV by 1 (1-indexed) ----
  for i in 1 2 3 4; do
    git checkout -q -b "pool/n${i}.feature.cyc0" dev
    echo "c0-$i" > "f-c0-$i"
    git -c user.email=t@t -c user.name=t add "f-c0-$i"
    git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] cyc0 merge $i"
    git checkout -q dev
    git -c user.email=t@t -c user.name=t merge --no-ff "pool/n${i}.feature.cyc0" -m "[MERGE] pool/n${i} into dev"
    v=$(.io.v4rian.how-git/bin/version --seal)
    assert_eq "$v" "v${year}.0.${i}" "cycle 0 seq ${i}: seal = v${year}.0.${i}" || return 1
    v=$(.io.v4rian.how-git/bin/version --next-dev)
    local expected=$((i + 1))
    assert_eq "$v" "v${year}.0.${expected}" "cycle 0 seq ${i}: next-dev = v${year}.0.${expected}" || return 1
  done
  # ---- First main merge (releases cycle 0 at v.YEAR.0.4) ----
  git checkout -q main
  git -c user.email=t@t -c user.name=t merge --no-ff dev -m "[MERGE] dev into main: release cycle 0"
  assert_eq "$(.io.v4rian.how-git/bin/version --release-tag)" "v${year}.0.4" "main merge: release-tag = prior cycle's last seal (v${year}.0.4)" || return 1
  git checkout -q dev
  # Post-main on dev: SERIES bumped to 1, DEV_IN_CYCLE = 0 (no dev in cycle 1 yet).
  assert_eq "$(.io.v4rian.how-git/bin/version --seal)" "v${year}.0.4" "post-main seal falls back to last cycle 0 tag (v${year}.0.4) before any cycle-1 dev merge" || return 1
  assert_eq "$(.io.v4rian.how-git/bin/version --next-dev)" "v${year}.1.0" "post-main next-dev = v${year}.1.0 (first cycle-1 integration, 0-indexed)" || return 1
  # ---- Cycle 1: 3 dev merges, DEV 0-indexed (0, 1, 2) ----
  for i in 1 2 3; do
    git checkout -q -b "pool/n${i}.feature.cyc1" dev
    echo "c1-$i" > "f-c1-$i"
    git -c user.email=t@t -c user.name=t add "f-c1-$i"
    git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] cyc1 merge $i"
    git checkout -q dev
    git -c user.email=t@t -c user.name=t merge --no-ff "pool/n${i}.feature.cyc1" -m "[MERGE] pool/n${i} cyc1 into dev"
    local dev_slot=$((i - 1))
    v=$(.io.v4rian.how-git/bin/version --seal)
    assert_eq "$v" "v${year}.1.${dev_slot}" "cycle 1 seq ${i}: seal = v${year}.1.${dev_slot}" || return 1
    v=$(.io.v4rian.how-git/bin/version --next-dev)
    assert_eq "$v" "v${year}.1.${i}" "cycle 1 seq ${i}: next-dev = v${year}.1.${i}" || return 1
  done
  # ---- Second main merge (releases cycle 1 at v.YEAR.1.2) ----
  git checkout -q main
  git -c user.email=t@t -c user.name=t merge --no-ff dev -m "[MERGE] dev into main: release cycle 1"
  assert_eq "$(.io.v4rian.how-git/bin/version --release-tag)" "v${year}.1.2" "second main merge: release-tag = prior cycle's last seal (v${year}.1.2)" || return 1
  git checkout -q dev
  assert_eq "$(.io.v4rian.how-git/bin/version --seal)" "v${year}.1.2" "post-second-main seal falls back to last cycle-1 tag" || return 1
  assert_eq "$(.io.v4rian.how-git/bin/version --next-dev)" "v${year}.2.0" "post-second-main next-dev = v${year}.2.0" || return 1
  # ---- Cycle 2: 1 dev merge ----
  git checkout -q -b "pool/n1.feature.cyc2" dev
  echo "c2-1" > "f-c2-1"
  git -c user.email=t@t -c user.name=t add "f-c2-1"
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] cyc2 merge 1"
  git checkout -q dev
  git -c user.email=t@t -c user.name=t merge --no-ff "pool/n1.feature.cyc2" -m "[MERGE] pool/n1 cyc2 into dev"
  assert_eq "$(.io.v4rian.how-git/bin/version --seal)" "v${year}.2.0" "cycle 2 first dev merge: seal = v${year}.2.0" || return 1
  assert_eq "$(.io.v4rian.how-git/bin/version --next-dev)" "v${year}.2.1" "cycle 2 first dev merge: next-dev = v${year}.2.1" || return 1
}

# Orphan resilience: when a dev merge happens but its tag claim
# silently never lands (the 8899fa7 incident class), the merge still
# counts in --next-dev so the next claim assigns the next sequential
# slot (leaving a visible gap in the tag chain rather than
# compressing). This is the whole point of counting merges instead
# of "git describe + 1" tag-based math.
test_version_bin_orphan_merge_counts_in_next_dev() {
  local d="$SCRATCH_BASE/22u-ver-orphan"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev
  local year; year=$(date -u +%Y)
  # Two dev merges: let the post-merge hook auto-tag them as v.YEAR.0.1 and v.YEAR.0.2.
  local i
  for i in 1 2; do
    git checkout -q -b "pool/n${i}.feature.t" dev
    echo "$i" > "f$i"
    git -c user.email=t@t -c user.name=t add "f$i"
    git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] m$i"
    git checkout -q dev
    git -c user.email=t@t -c user.name=t merge --no-ff "pool/n${i}.feature.t" -m "[MERGE] m$i"
  done
  # Third merge: orphan — skip the post-merge hook so no tag is created.
  git checkout -q -b pool/n3.feature.orphan dev
  echo 3 > f3
  git -c user.email=t@t -c user.name=t add f3
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] m3"
  git checkout -q dev
  git -c core.hooksPath=/dev/null -c user.email=t@t -c user.name=t merge --no-ff pool/n3.feature.orphan -m "[MERGE] m3"
  # Defensive: if any tag landed on the orphan merge (e.g., a race),
  # delete it to truly simulate the orphan state.
  local orphan_tag
  orphan_tag=$(git tag --points-at HEAD --list 'v*' 2>/dev/null | head -1)
  if [ -n "$orphan_tag" ]; then
    git tag -d "$orphan_tag" >/dev/null
  fi
  # Verify state: latest tag is still v.YEAR.0.2 but 3 first-parent dev merges exist.
  assert_eq "$(git tag --list 'v*' | sort -V | tail -1)" "v${year}.0.2" "latest tag still v${year}.0.2 (orphan never tagged)" || return 1
  local merge_count
  merge_count=$(git log dev --first-parent --merges --since="${year}-01-01T00:00:00Z" --pretty=oneline | wc -l | tr -d ' ')
  assert_eq "$merge_count" "3" "first-parent dev merge count = 3 (includes orphan)" || return 1
  # --next-dev MUST return v.YEAR.0.4 (the 4th merge slot), NOT
  # v.YEAR.0.3 (which is what 'git describe + 1' would compress to).
  assert_eq "$(.io.v4rian.how-git/bin/version --next-dev)" "v${year}.0.4" "next-dev counts orphan (3 merges + 1 = slot 4); gap at v${year}.0.3 stays" || return 1
  # --seal returns the merge-count-based value: v.YEAR.0.3 (semantic latest, even though no tag exists at that slot).
  assert_eq "$(.io.v4rian.how-git/bin/version --seal)" "v${year}.0.3" "seal = count = v${year}.0.3 (semantic latest; tag absent due to orphan)" || return 1
}

# Initial-state edge: empty dev branch, no merges yet.
# --next-dev must return v.YEAR.0.1 (1-indexed cycle 0 start).
# --seal must return v.YEAR.0.0 (the conceptual "zero state" with no tag).
test_version_bin_initial_empty_dev() {
  local d="$SCRATCH_BASE/22u-ver-empty"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev
  local year; year=$(date -u +%Y)
  assert_eq "$(.io.v4rian.how-git/bin/version --next-dev)" "v${year}.0.1" "empty dev: next-dev = v${year}.0.1 (1-indexed start)" || return 1
  assert_eq "$(.io.v4rian.how-git/bin/version --seal)" "v${year}.0.0" "empty dev: seal = v${year}.0.0 (no merges yet)" || return 1
}

# SERIES file (the legacy manual override mechanism) must be IGNORED
# under the new auto-derive model. SERIES comes only from counting
# main merges.
test_version_bin_ignores_legacy_series_file() {
  local d="$SCRATCH_BASE/22u-ver-no-manual-series"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev
  # Stage a legacy SERIES file with a bogus value to prove it's ignored.
  echo 99 > SERIES
  local year; year=$(date -u +%Y)
  # With no main merges, SERIES should be 0 regardless of the file.
  assert_eq "$(.io.v4rian.how-git/bin/version --next-dev)" "v${year}.0.1" "SERIES file is ignored; auto-derived from main merge count" || return 1
}

test_apply_repo_rules_includes_vault_readonly() {
  # pool/n41 externalized the vault-readonly inline block into
  # rulesets/vault-readonly.json and now applies it via the same
  # apply_ruleset_from_file helper as the other rulesets. Assert both
  # sides hold: the apply call exists in the script AND the JSON file
  # carries the canonical ruleset definition.
  local sh="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/apply-repo-rules.sh"
  local rs="$TEMPLATE_ROOT/.io.v4rian.how-git/rulesets/vault-readonly.json"
  assert_grep "vault-readonly.json" "$sh" "apply-repo-rules calls vault-readonly ruleset" || return 1
  assert_file_exists "$rs" "vault-readonly.json present" || return 1
  assert_grep "v4rian-vault-readonly" "$rs" "ruleset name in JSON" || return 1
  assert_grep "refs/heads/vault" "$rs" "vault ref pattern in JSON" || return 1
}

test_safety_gc_three_gate_logic() {
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/claim-main-release.sh"
  assert_grep "vault + release + main-reachable" "$f" "3-gate GC documented" || return 1
  assert_grep "merge-base --is-ancestor" "$f" "main-reachable gate uses ancestor check" || return 1
}

test_safety_gc_archives_under_major_prefix_instead_of_deleting() {
  # Pool/n48: when all 3 gates pass, safety branches are no longer
  # deleted from origin. They're archived under safety/<major>/<suffix>
  # mirroring the vault prefix scheme — branches are cheap pointers
  # and the archived safety serves as a receipt of where the n-counter
  # work was sanctioned for that release cycle. Original flat
  # safety/<suffix> ref is removed so the namespace stays free for new
  # allocations.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/claim-main-release.sh"
  grep -q 'archived_safety="safety/\$major/\$suffix"' "$f" \
    || { echo "archived safety path composition missing"; return 1; }
  grep -q "all 3 gates passed" "$f" \
    || { echo "3-gate pass log line missing"; return 1; }
  grep -q "archiving \$safety -> \$archived_safety" "$f" \
    || { echo "archive log line missing"; return 1; }
  # Major prefix is derived from the vault path OR RELEASE_TAG
  grep -q 'vault/v\*/\*' "$f" \
    || { echo "vault-prefix-pattern major derivation missing"; return 1; }
  grep -q 'RELEASE_TAG%\.\*' "$f" \
    || { echo "RELEASE_TAG fallback for major derivation missing"; return 1; }
  # Final flat-safety delete happens AFTER successful archive push
  grep -q 'git push -q origin --delete "\$safety"' "$f" \
    || { echo "flat-safety delete missing"; return 1; }
}

test_safety_lockdown_ruleset_covers_both_layouts() {
  # Pool/n48 extends safety-lockdown.json + the inline copy in bin/lockdown
  # to include both refs/heads/safety/* (active) and refs/heads/safety/*/*
  # (archived) so neither layout is left unprotected.
  local rs="$TEMPLATE_ROOT/.io.v4rian.how-git/rulesets/safety-lockdown.json"
  local lock="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/lockdown"
  grep -q 'refs/heads/safety/\*"' "$rs" \
    || { echo "active-anchor pattern missing in safety-lockdown.json"; return 1; }
  grep -q 'refs/heads/safety/\*/\*' "$rs" \
    || { echo "archived-anchor pattern missing in safety-lockdown.json"; return 1; }
  grep -q 'refs/heads/safety/\*/\*' "$lock" \
    || { echo "archived-anchor pattern missing in bin/lockdown inline JSON"; return 1; }
}

test_pool_creations_ruleset_covers_both_layouts() {
  # Active pool allocation now produces vYYYY.MAIN/-prefixed branches alongside
  # the legacy flat layout, so the pool-creations ruleset (and the inline copy
  # in bin/lockdown) must gate refs/heads/pool/* AND refs/heads/pool/*/* so
  # neither layout slips past the creation lock.
  local rs="$TEMPLATE_ROOT/.io.v4rian.how-git/rulesets/pool-creations.json"
  local lock="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/lockdown"
  grep -q 'refs/heads/pool/\*"' "$rs" \
    || { echo "flat-layout pattern missing in pool-creations.json"; return 1; }
  grep -q 'refs/heads/pool/\*/\*' "$rs" \
    || { echo "prefixed-layout pattern missing in pool-creations.json"; return 1; }
  grep -q 'refs/heads/pool/\*/\*' "$lock" \
    || { echo "prefixed-layout pattern missing in bin/lockdown inline JSON"; return 1; }
}

test_pre_push_regex_accepts_prefixed_layout() {
  # The pre-push hook regex must accept both the legacy flat layout and the
  # vYYYY.MAIN/ prefixed layout introduced when active allocation gained
  # release-line classification. The regex literal lives in the hook source
  # so a sed-edit regression is the prime risk; assert the prefixed-segment
  # group is present.
  local hook="$TEMPLATE_ROOT/.io.v4rian.how-git/githooks/pre-push"
  grep -q '(v\[0-9\]{4}\\\.\[0-9\]+/)?n\[0-9\]+' "$hook" \
    || { echo "pre-push regex missing optional vYYYY.MAIN/ prefix group"; return 1; }
  # Behavioral check: the actual regex must accept both shapes and reject a
  # malformed prefix.
  local pattern='^(pool|safety)/(v[0-9]{4}\.[0-9]+/)?n[0-9]+\.(feature|fix|r&d|refactor|reconcile|doc)\.(sprint[0-9]+-)?([A-Z]+-[0-9]+-)?[a-z0-9][a-z0-9-]*$'
  for good in "pool/n3.feature.x" "pool/v2026.0/n3.feature.x" "safety/v2026.12/n44.fix.PROJ-1-leak"; do
    [[ "$good" =~ $pattern ]] || { echo "regex rejected valid name: $good"; return 1; }
  done
  for bad in "pool/v2026/n3.feature.x" "pool/v2026.0.0/n3.feature.x"; do
    [[ "$bad" =~ $pattern ]] && { echo "regex accepted malformed prefixed name: $bad"; return 1; }
  done
  return 0
}

test_allocator_composes_prefixed_branch_when_seal_resolves() {
  # When bin/version --seal returns a parseable vN.N.N value the allocator
  # composes pool/<vYYYY.MAIN>/nN.kind.suffix (and the paired safety/<same>)
  # instead of the legacy flat shape. Assert the composition logic is in
  # place by grepping the script body for the seal-derived MAJOR_PREFIX
  # branch composition and the legacy fallback.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/allocate-pool-branch.sh"
  grep -q '^MAJOR_PREFIX=' "$f" \
    || { echo "MAJOR_PREFIX initialization missing in allocator"; return 1; }
  grep -q '\$VERSION_BIN.*--seal' "$f" \
    || { echo "bin/version --seal invocation missing in allocator"; return 1; }
  grep -q 'MAJOR_PREFIX="\${SEAL%\.\*}"' "$f" \
    || { echo "parameter-expansion trim of trailing .DEV missing in allocator"; return 1; }
  grep -q 'POOL_REF="pool/\$MAJOR_PREFIX/\$SUFFIX"' "$f" \
    || { echo "prefixed POOL_REF composition missing in allocator"; return 1; }
  grep -q 'SAFETY_REF="safety/\$MAJOR_PREFIX/\$SUFFIX"' "$f" \
    || { echo "prefixed SAFETY_REF composition missing in allocator"; return 1; }
  # Legacy fallback must remain visible so offline allocation still works
  grep -q 'POOL_REF="pool/\$SUFFIX"' "$f" \
    || { echo "legacy flat POOL_REF fallback missing in allocator"; return 1; }
  grep -q 'SAFETY_REF="safety/\$SUFFIX"' "$f" \
    || { echo "legacy flat SAFETY_REF fallback missing in allocator"; return 1; }
}

test_allocator_next_n_walks_both_layouts() {
  # The n-counter must remain globally unique across the flat and the
  # prefixed namespaces. The original implementation used a single
  # parenthesised-alternation sed expression to strip the optional
  # major-prefix segment in one pass, but BSD sed on macOS rejects that
  # shape ("RE error: parentheses not balanced") which broke the
  # off-grid path on operator Macs. The portable replacement anchors
  # on '/n<digits>.' via grep -oE first and then strips the delimiters
  # with a delimited sed; both forms walk both layouts.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/allocate-pool-branch.sh"
  grep -q 'next_n()' "$f" \
    || { echo "next_n() helper missing"; return 1; }
  grep -qE "grep -oE '/n\[0-9\]\+\\\\\\.'" "$f" \
    || { echo "next_n grep anchor on '/n<digits>.' missing"; return 1; }
  grep -qE "sed -E 's\\|/n\\(\\[0-9\\]\\+\\)\\\\\\.\\|" "$f" \
    || { echo "next_n sed strip of delimiters missing"; return 1; }
}

test_archive_pool_branch_accepts_prefixed_input() {
  # archive-pool-branch.sh accepts both a flat pool input (pool/nN.kind.short)
  # and a prefixed pool input (pool/vYYYY.MAIN/nN.kind.short). When the input
  # is prefixed the vault path inherits that prefix verbatim instead of
  # double-prefixing or trying to re-derive via bin/version --seal.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/archive-pool-branch.sh"
  grep -q '^INPUT_MAJOR_PREFIX=' "$f" \
    || { echo "INPUT_MAJOR_PREFIX tracking missing"; return 1; }
  grep -q 'BARE_SUFFIX=' "$f" \
    || { echo "BARE_SUFFIX extraction missing"; return 1; }
  grep -qE 'SUFFIX.*=~.*\^\(v\[0-9\]\+\\\.\[0-9\]\+\)/' "$f" \
    || { echo "prefixed-input detection regex missing"; return 1; }
}

test_archive_pool_branch_prefixed_input_e2e() {
  # End-to-end: invoking archive-pool-branch.sh --dry-run on a PREFIXED pool
  # input (pool/v2026.0/n9.feature.probe) must surface the vault path under
  # the SAME major prefix, not a double-prefixed nor seal-rederived path.
  local d="$SCRATCH_BASE/22-archive-prefixed-input"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev
  echo a > .seed
  git -c user.email=t@t -c user.name=t add .seed
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] seed"
  local year; year=$(date -u +%Y)
  git tag -a "v${year}.0.1" -m "synthetic" HEAD
  # Create a PREFIXED pool branch as the allocator would post-task-28.
  git checkout -q -b "pool/v${year}.0/n9.feature.probe"
  echo p > .p
  git -c user.email=t@t -c user.name=t add .p
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] probe"
  git push -q origin "pool/v${year}.0/n9.feature.probe"
  local out; out=$(bash .io.v4rian.how-git/scripts/archive-pool-branch.sh --dry-run "pool/v${year}.0/n9.feature.probe" 2>&1)
  echo "$out" | grep -qE "vault/v${year}\.0/n9\.feature\.probe" \
    || { echo "prefixed-input dry-run did not surface inherited vault path; got: $out"; return 1; }
  # Negative check: no double-prefix in the output
  if echo "$out" | grep -qE "vault/v${year}\.0/v${year}\.0/"; then
    echo "prefixed-input dry-run double-prefixed the vault path; got: $out"; return 1
  fi
}

test_auto_rebase_reconcile_inherits_major_prefix() {
  # The auto-rebase pass cuts pool/[<major>/]nN.reconcile.<short> off the new
  # dev tip. When the original head carried a vYYYY.MAIN/ prefix the
  # reconcile branch must inherit the same prefix so the release-line
  # classification stays consistent across the iterative chain.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/auto-rebase-pools-after-dev-merge.sh"
  grep -q '^major_prefix_of()' "$f" \
    || { echo "major_prefix_of helper missing"; return 1; }
  grep -q 'ORIG_MAJOR=' "$f" \
    || { echo "ORIG_MAJOR capture missing"; return 1; }
  grep -q 'RECON_BRANCH="pool/\${ORIG_MAJOR}/\${ORIG_N}\.reconcile\.\${ORIG_SHORT}"' "$f" \
    || { echo "prefixed RECON_BRANCH composition missing"; return 1; }
  grep -q 'RECON_BRANCH="pool/\${ORIG_N}\.reconcile\.\${ORIG_SHORT}"' "$f" \
    || { echo "flat RECON_BRANCH fallback missing"; return 1; }
  # POOL_PATTERN now accepts the optional major-prefix segment
  grep -qE 'POOL_PATTERN=.*\(v\[0-9\]\{4\}\\\.\[0-9\]\+/\)\?n\[0-9\]\+' "$f" \
    || { echo "POOL_PATTERN does not accept the optional vYYYY.MAIN/ segment"; return 1; }
}

test_open_pr_pool_regex_accepts_prefixed_layout() {
  # open-pr.sh enforces the pool/* shape before POSTing to the GitHub API.
  # The regex must accept both layouts so an allocated prefixed branch can
  # open a PR into dev without local rejection.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/open-pr.sh"
  grep -qE "pattern=.*\\^pool/\\(v\\[0-9\\]\\{4\\}\\\\\\.\\[0-9\\]\\+/\\)\\?n\\[0-9\\]\\+" "$f" \
    || { echo "open-pr pool/* regex does not accept optional vYYYY.MAIN/ prefix"; return 1; }
}

test_validate_pr_open_accepts_prefixed_layout() {
  # validate-pr-open.sh closes PRs whose source branch does not match the
  # pool/[<major>/]nN.kind.short shape. The matcher must accept both layouts.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/validate-pr-open.sh"
  grep -qE 'PR_HEAD_REF.*=~.*\^pool/\(v\[0-9\]\{4\}\\\.\[0-9\]\+/\)\?n\[0-9\]\+' "$f" \
    || { echo "validate-pr-open PR_HEAD_REF matcher does not accept prefixed layout"; return 1; }
  grep -qE 'pool_kind\(\)' "$f" \
    || { echo "pool_kind helper missing"; return 1; }
  grep -qE 's\|\^pool/\(v\[0-9\]\+\\\.\[0-9\]\+/\)\?n\[0-9\]\+\\\.\(\[a-z&\]\+\)' "$f" \
    || { echo "pool_kind sed expression does not consume optional major-prefix segment"; return 1; }
}

test_claim_dev_merge_detects_prefixed_pool_in_subject() {
  # claim-dev-merge.sh extracts the just-merged pool branch from HEAD's
  # subject so the auto-archive pass knows what to vault. The capture group
  # must include / so prefixed branches (pool/v2026.0/nN.kind.short) are
  # captured intact alongside the legacy flat layout.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/claim-dev-merge.sh"
  grep -qE '\[a-zA-Z0-9\./&-\]' "$f" \
    || { echo "claim-dev-merge MERGED_POOL capture missing the / character for prefixed layout"; return 1; }
}

test_auto_rebase_regex_accepts_reconcile_kind() {
  # Reconcile kind must be accepted on both the flat and the vYYYY.MAIN/
  # prefixed layouts so iterative reconcile chains stay traceable under
  # whichever release-line classification the original allocation carried.
  local POOL_PATTERN='^pool/(v[0-9]{4}\.[0-9]+/)?n[0-9]+\.(feature|fix|r&d|refactor|reconcile|doc)\.(sprint[0-9]+-)?([A-Z]+-[0-9]+-)?[a-z0-9][a-z0-9-]*$'
  for good in \
    "pool/n5.reconcile.vault-archive-pool-on-merge" \
    "pool/n7.reconcile.PROJ-9-token-leak" \
    "pool/n12.reconcile.sprint3-rebase-pool-pattern" \
    "pool/v2026.0/n5.reconcile.vault-archive-pool-on-merge" \
    "pool/v2026.0/n7.reconcile.PROJ-9-token-leak"; do
    [[ "$good" =~ $POOL_PATTERN ]] || { echo "regex rejected valid reconcile name: $good"; return 1; }
  done
}

test_auto_rebase_short_name_and_n_helpers() {
  # n_of and short_name_of helpers must collapse both the flat layout and
  # the vYYYY.MAIN/ prefixed layout to the same n-counter and short-name so
  # the reconcile branch carries the original allocation's identity verbatim.
  for case in \
    "pool/n3.feature.vault-archive-pool-on-merge|n3|vault-archive-pool-on-merge" \
    "pool/n12.r&d.sprint4-PROJ-5-thing|n12|sprint4-PROJ-5-thing" \
    "pool/n7.reconcile.parser-fix|n7|parser-fix" \
    "pool/v2026.0/n3.feature.vault-archive-pool-on-merge|n3|vault-archive-pool-on-merge" \
    "pool/v2026.0/n12.r&d.sprint4-PROJ-5-thing|n12|sprint4-PROJ-5-thing" \
    "pool/v2026.0/n7.reconcile.parser-fix|n7|parser-fix"; do
    local input expected_n expected_short got_n got_short
    input=$(echo "$case" | awk -F'|' '{print $1}')
    expected_n=$(echo "$case" | awk -F'|' '{print $2}')
    expected_short=$(echo "$case" | awk -F'|' '{print $3}')
    got_n=$(echo "$input" | sed -E 's|^pool/(v[0-9]+\.[0-9]+/)?(n[0-9]+)\..*|\2|')
    got_short=$(echo "$input" | sed -E 's|^pool/(v[0-9]+\.[0-9]+/)?n[0-9]+\.[a-z&]+\.||')
    [ "$got_n" = "$expected_n" ] || { echo "n_of FAIL for $input: got $got_n expected $expected_n"; return 1; }
    [ "$got_short" = "$expected_short" ] || { echo "short_name_of FAIL for $input: got $got_short expected $expected_short"; return 1; }
  done
}

test_auto_rebase_orphan_base_detection() {
  local d="$SCRATCH_BASE/22r-orphan-base"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev
  echo a > .a
  git -c user.email=t@t -c user.name=t add .a
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[REFACTOR] dev advance"
  local PROBE_BASE; PROBE_BASE=$(git rev-parse HEAD)
  git checkout -q -b pool/n3.feature.orphan-probe
  echo b > .b
  git -c user.email=t@t -c user.name=t add .b
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] Probe commit"
  git checkout -q dev
  git reset --hard HEAD~1
  echo c > .c
  git -c user.email=t@t -c user.name=t add .c
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[REFACTOR] dev rewrite"
  if git merge-base --is-ancestor "$PROBE_BASE" dev 2>/dev/null; then
    echo "PROBE_BASE unexpectedly still in dev history; orphan setup failed"; return 1
  fi
  local OLD_BASE; OLD_BASE=$(git rev-parse pool/n3.feature.orphan-probe~1)
  if git merge-base --is-ancestor "$OLD_BASE" dev 2>/dev/null; then
    echo "orphan-base check would have used plain rebase; expected --onto path"; return 1
  fi
}

test_build_on_tag_workflow_present_and_wired() {
  # Pool/n55: the standalone build-on-tag.yml is replaced by the
  # sys-layer ci/audits/tag/required.build.sh entry fronted by
  # ci-dispatch.yml's tag trigger. The retry shape (MAX_ATTEMPTS,
  # backoff, idempotency probe) lives in build-retry.sh which the
  # entry dispatches to. Distribution still belongs to a later bundle —
  # build-retry.sh must not invoke distribute-* scripts or touch GitHub
  # Releases.
  local entry="$TEMPLATE_ROOT/.io.v4rian.how-git/ci/audits/tag/required.build.sh"
  local retry="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/workflows/build-retry.sh"
  assert_file_exists "$entry" "tag sys entry" || return 1
  assert_executable "$entry" "tag sys entry executable" || return 1
  assert_file_exists "$retry" "build-retry.sh" || return 1
  assert_grep "build-retry.sh" "$entry" "tag entry dispatches to build-retry.sh" || return 1
  assert_grep "build.sh" "$retry" "build-retry.sh invokes build.sh" || return 1
  assert_grep 'MAX_ATTEMPTS=' "$retry" "retry shape: MAX_ATTEMPTS knob" || return 1
  assert_grep 'BASE_DELAY=' "$retry" "retry shape: BASE_DELAY knob" || return 1
  assert_grep 'MAX_DELAY=' "$retry" "retry shape: MAX_DELAY knob" || return 1
  # Idempotency probe lives in build.sh itself (gated by BUILD_IDEMPOTENCY_CHECK=1).
  assert_grep "BUILD_IDEMPOTENCY_CHECK" "$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/build.sh" "BUILD_IDEMPOTENCY_CHECK probe in build.sh" || return 1
  # ci-dispatch.yml must carry the tag-push trigger.
  local wf="$TEMPLATE_ROOT/.github/workflows/ci-dispatch.yml"
  assert_file_exists "$wf" "ci-dispatch.yml" || return 1
  grep -qE "^[[:space:]]+-[[:space:]]+'v\\*'" "$wf" || { echo "ASSERT FAIL: ci-dispatch.yml does not subscribe to v* tag push"; return 1; }
  # Distribution belongs to a later bundle; build-retry.sh must NOT call
  # distribute-* scripts and must NOT set a prerelease flag or create a
  # Release. Strip comment lines before grepping so the doc preamble does
  # not false-positive on its own words.
  local non_comment
  non_comment=$(grep -v '^[[:space:]]*#' "$retry")
  if echo "$non_comment" | grep -q "distribute-internal\|distribute-public"; then
    echo "build-retry.sh must not invoke distribute scripts (distribution is a separate bundle)"; return 1
  fi
  if echo "$non_comment" | grep -q "gh release create\|gh release edit\|gh release upload\|prerelease"; then
    echo "build-retry.sh must not touch GitHub Releases (distribution is a separate bundle)"; return 1
  fi
  # Legacy yaml gone.
  local legacy="$TEMPLATE_ROOT/.github/workflows/build-on-tag.yml"
  if [ -f "$legacy" ]; then
    echo "ASSERT FAIL: legacy build-on-tag.yml still present; pool/n55 should have removed it"
    return 1
  fi
}

test_build_scripts_present_and_executable() {
  local d="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts"
  for f in build.sh distribute-internal.sh distribute-public.sh; do
    assert_file_exists "$d/$f" "$f present" || return 1
    assert_executable "$d/$f" "$f executable" || return 1
  done
}

test_distribute_scripts_carry_inline_design_doc_header() {
  # Both distribute-* scripts must ship an inline DESIGN DOC header at the
  # top covering the contract every consumer signs by using the framework
  # (purpose / triggers / inputs / outputs / what-this-is-NOT / override
  # pattern). The header lives ABOVE the script body so a consumer who
  # overrides the body still inherits the contract.
  local d="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts"
  for f in distribute-internal.sh distribute-public.sh; do
    local path="$d/$f"
    assert_file_exists "$path" "$f present" || return 1
    assert_grep "DESIGN DOC" "$path" "$f carries DESIGN DOC banner" || return 1
    assert_grep "Purpose" "$path" "$f header documents Purpose" || return 1
    assert_grep "Triggers" "$path" "$f header documents Triggers" || return 1
    assert_grep "Inputs" "$path" "$f header documents Inputs" || return 1
    assert_grep "Outputs" "$path" "$f header documents Outputs" || return 1
    assert_grep "Design tips" "$path" "$f header documents Design tips" || return 1
    assert_grep "What this is NOT" "$path" "$f header documents What this is NOT" || return 1
    assert_grep "Override pattern" "$path" "$f header documents Override pattern" || return 1
    # The DESIGN DOC must come before the script body (set -euo pipefail is
    # the body's leading guard); a header that lands after `set -e` would
    # not be self-evident to a consumer reading top-down.
    local doc_line set_line
    doc_line=$(grep -n "DESIGN DOC" "$path" | head -1 | cut -d: -f1)
    set_line=$(grep -n "^set -euo pipefail" "$path" | head -1 | cut -d: -f1)
    if [ -z "$doc_line" ] || [ -z "$set_line" ] || [ "$doc_line" -ge "$set_line" ]; then
      echo "$f DESIGN DOC must precede 'set -euo pipefail'"; return 1
    fi
  done
  # distribute-internal.sh must explicitly disclaim being the build or the
  # version claim — the two most common conceptual collisions.
  assert_grep "NOT the build" "$d/distribute-internal.sh" "distribute-internal disclaims build role" || return 1
  assert_grep "NOT the version claim" "$d/distribute-internal.sh" "distribute-internal disclaims claim role" || return 1
  # distribute-public.sh must explicitly call out the main-reachability gate
  # so a future contributor cannot wire it onto pre-release dev tags.
  assert_grep "reachable from origin/main" "$d/distribute-public.sh" "distribute-public documents main-reachability gate" || return 1
}

test_build_sh_template_self_emits_summary_artifact() {
  # No package.json, no CMakeLists.txt -> template self build path that
  # emits a small text summary so the workflow always has something to
  # upload even on the template repo's own tag pushes.
  local d="$SCRATCH_BASE/22p-build-template-self"
  setup_scratch_repo "$d"
  cd "$d"
  rm -f package.json CMakeLists.txt
  rm -rf build/artifacts
  TAG=v2026.0.7 bash .io.v4rian.how-git/scripts/build.sh >/dev/null 2>&1 || {
    echo "build.sh template-self path failed"; return 1
  }
  assert_file_exists "build/artifacts/how-git-v2026.0.7.txt" "tag summary artifact produced" || return 1
  assert_grep "v2026.0.7" "build/artifacts/how-git-v2026.0.7.txt" "summary mentions the tag" || return 1
}

test_build_sh_qt_cmake_dispatcher_demands_override() {
  # A CMakeLists.txt-only repo (Qt/C++ consumer that has not yet overridden
  # build.sh) must surface the override banner and exit non-zero so the
  # workflow fails loudly rather than silently producing nothing.
  local d="$SCRATCH_BASE/22p-build-qt-cmake"
  setup_scratch_repo "$d"
  cd "$d"
  rm -f package.json
  : > CMakeLists.txt
  rm -rf build/artifacts
  if TAG=v2026.0.7 bash .io.v4rian.how-git/scripts/build.sh >/dev/null 2>&1; then
    echo "Qt/CMake dispatcher unexpectedly succeeded; consumer must override"; return 1
  fi
}

test_build_sh_idempotency_probe_round_trip() {
  # BUILD_IDEMPOTENCY_CHECK=1 must return non-zero before any build, then
  # return zero after a successful build that placed output naming $TAG
  # under build/artifacts/.
  local d="$SCRATCH_BASE/22p-build-idempotency"
  setup_scratch_repo "$d"
  cd "$d"
  rm -f package.json CMakeLists.txt
  rm -rf build/artifacts
  if TAG=v2026.0.7 BUILD_IDEMPOTENCY_CHECK=1 bash .io.v4rian.how-git/scripts/build.sh >/dev/null 2>&1; then
    echo "idempotency probe returned 0 before any build"; return 1
  fi
  TAG=v2026.0.7 bash .io.v4rian.how-git/scripts/build.sh >/dev/null 2>&1 || {
    echo "build.sh failed during idempotency setup"; return 1
  }
  if ! TAG=v2026.0.7 BUILD_IDEMPOTENCY_CHECK=1 bash .io.v4rian.how-git/scripts/build.sh >/dev/null 2>&1; then
    echo "idempotency probe returned non-zero after a successful build"; return 1
  fi
  # A different tag must still register as not-yet-built even when v2026.0.7
  # output is present.
  if TAG=v2026.0.8 BUILD_IDEMPOTENCY_CHECK=1 bash .io.v4rian.how-git/scripts/build.sh >/dev/null 2>&1; then
    echo "idempotency probe returned 0 for a different tag (v2026.0.8) with only v2026.0.7 output present"; return 1
  fi
}

test_m3_real_consumer_full_lifecycle_with_gh_mock() {
  local d="$SCRATCH_BASE/m3-consumer-lifecycle"
  setup_scratch_repo "$d"
  cd "$d"
  . "$TEMPLATE_ROOT/.io.v4rian.how-git/framework-tests/_gh_mock_enable.sh"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null

  git checkout -q -b dev
  git push -q origin dev
  local year; year=$(date -u +%Y)
  assert_eq "$(.io.v4rian.how-git/bin/version --seal)" "v${year}.0.0" "initial seal vYEAR.0.0" || return 1

  for i in 1 2 3; do
    git checkout -q -b "pool/n${i}.feature.thing${i}"
    echo "feature $i" > "feature${i}.txt"
    git -c user.email=t@t -c user.name=t add "feature${i}.txt"
    git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] feature ${i}"
    git checkout -q dev
    git -c user.email=t@t -c user.name=t merge --no-ff "pool/n${i}.feature.thing${i}" \
      -m "[MERGE] pool/n${i} into dev"
    git push -q origin dev 2>/dev/null  # sync so post-merge claim's pull --ff-only succeeds next iter
  done
  assert_eq "$(.io.v4rian.how-git/bin/version --seal)" "v${year}.0.3" "after 3 dev merges" || return 1

  git checkout -q main
  git -c user.email=t@t -c user.name=t merge --no-ff dev -m "[MERGE] dev into main: release"
  bash .io.v4rian.how-git/scripts/claim-main-release.sh --skip-pull >/dev/null

  assert_eq "$(.io.v4rian.how-git/bin/version --release-tag)" "v${year}.0.3" "release reuses dev tag" || return 1

  python3 -c "
import json
s = json.load(open('$GH_MOCK_STATE'))
rels = [r for r in s['releases'] if r['tag'] == 'v${year}.0.3']
assert rels, f'release v${year}.0.3 not created; got: {s[\"releases\"]}'
" || return 1

  git checkout -q dev
  git checkout -q -b pool/n4.feature.post-release
  echo post > post.txt
  git -c user.email=t@t -c user.name=t add post.txt
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] post-release"
  git checkout -q dev
  git -c user.email=t@t -c user.name=t merge --no-ff pool/n4.feature.post-release -m "[MERGE] pool/n4 into dev"
  # Post-release the cycle bumps: SERIES=1, DEV resets to 0-indexed. The first
  # post-release dev merge tags v.YEAR.1.0 (was v.YEAR.0.4 under the old wrong
  # "no cycle bump" model).
  assert_eq "$(.io.v4rian.how-git/bin/version --seal)" "v${year}.1.0" "post-release dev merge starts cycle 1 at v${year}.1.0 (0-indexed)" || return 1
}

test_m4_real_conflict_resolved_by_reconcile() {
  local d="$SCRATCH_BASE/m4-conflict-reconcile"
  setup_scratch_repo "$d"
  cd "$d"
  . "$TEMPLATE_ROOT/.io.v4rian.how-git/framework-tests/_gh_mock_enable.sh"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev
  git push -q origin dev

  echo "shared: ORIGINAL" > shared.txt
  git -c user.email=t@t -c user.name=t add shared.txt
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] seed shared"
  git push -q origin dev

  git checkout -q -b pool/n1.feature.first-change
  echo "shared: VERSION_A" > shared.txt
  git -c user.email=t@t -c user.name=t add shared.txt
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[REFACTOR] A"
  git push -q origin pool/n1.feature.first-change

  git checkout -q dev
  git checkout -q -b pool/n2.feature.second-change
  echo "shared: VERSION_B" > shared.txt
  git -c user.email=t@t -c user.name=t add shared.txt
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[REFACTOR] B"
  git push -q origin pool/n2.feature.second-change

  gh pr create --title "first" --body b --base dev --head pool/n1.feature.first-change --repo j/m >/dev/null
  gh pr create --title "second" --body b --base dev --head pool/n2.feature.second-change --repo j/m >/dev/null

  git checkout -q dev
  git -c user.email=t@t -c user.name=t merge --no-ff pool/n1.feature.first-change \
    -m "[MERGE] pool/n1 into dev"
  git push -q origin dev
  gh pr close 1 --comment merged >/dev/null

  # Attempt the conflicting rebase
  git fetch -q origin pool/n2.feature.second-change >/dev/null 2>&1 || true
  local WT=$(mktemp -d)
  git worktree add -q --detach "$WT" pool/n2.feature.second-change 2>/dev/null
  pushd "$WT" >/dev/null
  git checkout -q -B pool/n2.feature.second-change
  if git rebase dev >/dev/null 2>&1; then
    echo "expected conflict on shared.txt"
    popd >/dev/null; git worktree remove --force "$WT" 2>/dev/null
    return 1
  fi
  local conflicts=$(git diff --name-only --diff-filter=U)
  echo "$conflicts" | grep -q "shared.txt" || {
    echo "shared.txt not in conflict list: $conflicts"
    git rebase --abort 2>/dev/null
    popd >/dev/null; git worktree remove --force "$WT" 2>/dev/null
    return 1
  }
  # Verify reconcile-branch naming convention preserves n2. The sed
  # expressions consume the optional vYYYY.MAIN/ major-prefix segment so
  # the helpers behave identically on flat and prefixed inputs.
  local n_of_input="pool/n2.feature.second-change"
  local got_n=$(echo "$n_of_input" | sed -E 's|^pool/(v[0-9]+\.[0-9]+/)?(n[0-9]+)\..*|\2|')
  local got_short=$(echo "$n_of_input" | sed -E 's|^pool/(v[0-9]+\.[0-9]+/)?n[0-9]+\.[a-z&]+\.||')
  assert_eq "$got_n" "n2" "n_of extracts n2" || { git rebase --abort 2>/dev/null; popd >/dev/null; git worktree remove --force "$WT" 2>/dev/null; return 1; }
  assert_eq "$got_short" "second-change" "short_of extracts second-change" || { git rebase --abort 2>/dev/null; popd >/dev/null; git worktree remove --force "$WT" 2>/dev/null; return 1; }
  assert_eq "pool/${got_n}.reconcile.${got_short}" "pool/n2.reconcile.second-change" "reconcile name preserves n2" || { git rebase --abort 2>/dev/null; popd >/dev/null; git worktree remove --force "$WT" 2>/dev/null; return 1; }
  git rebase --abort 2>/dev/null
  popd >/dev/null
  git worktree remove --force "$WT" 2>/dev/null
  rm -rf "$WT"
}

test_m5a_year_rollover_via_date_mock() {
  local d="$SCRATCH_BASE/m5a-year-rollover"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev

  for i in 1 2; do
    git checkout -q -b "pool/n${i}.feature.thing${i}"
    echo "$i" > "f${i}"
    git -c user.email=t@t -c user.name=t add "f${i}"
    git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] ${i}"
    git checkout -q dev
    git -c user.email=t@t -c user.name=t merge --no-ff "pool/n${i}.feature.thing${i}" -m "[MERGE] pool/n${i} into dev"
  done
  local this_year=$(date -u +%Y)
  assert_eq "$(.io.v4rian.how-git/bin/version --seal)" "v${this_year}.0.2" "pre-rollover" || return 1

  local NEXT_YEAR=$((this_year + 1))
  local FAKEDIR=$(mktemp -d -t v4rian-fakedate-XXXXXX)
  cat > "$FAKEDIR/date" <<EOF
#!/usr/bin/env bash
# Fake date for year-rollover test: returns NEXT_YEAR for any %Y query,
# strips leading + (the format-spec prefix) from the output.
for arg in "\$@"; do
  case "\$arg" in
    *%Y*)
      result=\$(echo "\$arg" | sed 's|%Y|${NEXT_YEAR}|g' | sed 's|^+||')
      echo "\$result"
      exit 0
      ;;
  esac
done
exec /bin/date "\$@"
EOF
  chmod +x "$FAKEDIR/date"

  local rolled=$(PATH="$FAKEDIR:$PATH" .io.v4rian.how-git/bin/version --seal)
  rm -rf "$FAKEDIR"

  assert_eq "$rolled" "v${NEXT_YEAR}.0.0" "rollover: v${NEXT_YEAR}.0.0" || return 1
}

test_gh_mock_basic_pr_create_list_close() {
  local d="$SCRATCH_BASE/22zz-gh-mock-basic"
  setup_scratch_repo "$d"
  cd "$d"
  . "$TEMPLATE_ROOT/.io.v4rian.how-git/framework-tests/_gh_mock_enable.sh"
  # Empty state to start
  local n=$(gh pr list --state open --json number | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
  assert_eq "$n" "0" "starts with no PRs" || return 1
  # Create one
  local url=$(gh pr create --title "T1" --body "B1" --base dev --head pool/n1.feature.x --repo mock-owner/mock)
  echo "$url" | grep -q "/pull/1$" || { echo "expected /pull/1; got: $url"; return 1; }
  # List shows it
  local title=$(gh pr list --state open --json number,title | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['title'])")
  assert_eq "$title" "T1" "created PR title surfaces in list" || return 1
  # Close with comment
  gh pr close 1 --comment "superseded by #2" >/dev/null
  local nopen=$(gh pr list --state open --json number | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
  local nclosed=$(gh pr list --state closed --json number | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
  assert_eq "$nopen" "0" "no open after close" || return 1
  assert_eq "$nclosed" "1" "1 closed" || return 1
  # Forwarding comment recorded in state
  python3 -c "
import json
s = json.load(open('$GH_MOCK_STATE'))
assert s['comments'] and 'superseded by #2' in s['comments'][0]['body'], 'forward comment missing'
"
}

test_gh_mock_reconcile_flow_simulation() {
  # Pool/n43: simulate the comment-only reconcile flow (no PR close,
  # no new PR). The auto-rebase pass creates a reconcile branch + posts
  # a comment on the existing PR; admin reviews and decides via review.
  local d="$SCRATCH_BASE/22zz-gh-mock-reconcile"
  setup_scratch_repo "$d"
  cd "$d"
  . "$TEMPLATE_ROOT/.io.v4rian.how-git/framework-tests/_gh_mock_enable.sh"
  # Stage: original pool PR open (the developer's submission)
  gh pr create --title "[NEW] vault feature" --body "body" --base dev --head pool/n3.feature.vault --repo j/m >/dev/null
  # Auto-rebase action: comment on the original PR with the reconcile recap.
  # No `gh pr close` of #1, no `gh pr create` of a [RECONCILE] PR.
  gh pr comment 1 --body "Auto-rebase: dev advanced to abc1234. Reconcile branch \`pool/n3.reconcile.vault\` carries the cherry-picked commits onto the new dev tip." --repo j/m >/dev/null

  # Verify: original PR is STILL OPEN, exactly one PR total, exactly
  # one comment on it.
  local nopen=$(gh pr list --state open --json number | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
  assert_eq "$nopen" "1" "original PR still open after auto-rebase" || return 1
  python3 -c "
import json
s = json.load(open('$GH_MOCK_STATE'))
assert len(s['prs']) == 1, f'expected 1 PR (no new RECONCILE PR), got {len(s[\"prs\"])}'
assert s['prs'][0]['state'] == 'open', f'expected original PR still open, got {s[\"prs\"][0][\"state\"]}'
assert s['prs'][0]['title'] == '[NEW] vault feature', f'expected original title untouched, got {s[\"prs\"][0][\"title\"]}'
assert s['comments'] and 'pool/n3.reconcile.vault' in s['comments'][0]['body'], 'reconcile branch name missing from comment'
assert s['comments'] and 'dev advanced' in s['comments'][0]['body'], 'dev-advanced context missing from comment'
" || return 1
}

test_gh_mock_release_create_and_upload() {
  local d="$SCRATCH_BASE/22zz-gh-mock-release"
  setup_scratch_repo "$d"
  cd "$d"
  . "$TEMPLATE_ROOT/.io.v4rian.how-git/framework-tests/_gh_mock_enable.sh"
  # Create release
  gh release create v2026.1.5 --title v2026.1.5 --generate-notes >/dev/null
  # Verify exists
  gh release view v2026.1.5 >/dev/null || { echo "release v2026.1.5 not found"; return 1; }
  # Upload an artifact (use this script as a fake artifact for the test)
  mkdir -p out
  echo "fake build" > out/myapp-v2026.1.5.tar.gz
  gh release upload v2026.1.5 out/myapp-v2026.1.5.tar.gz >/dev/null
  # Verify asset recorded
  python3 -c "
import json
s = json.load(open('$GH_MOCK_STATE'))
r = next((r for r in s['releases'] if r['tag'] == 'v2026.1.5'), None)
assert r is not None, 'release not in state'
assert any('myapp-v2026.1.5.tar.gz' in a for a in r['assets']), f'artifact not uploaded; assets: {r[\"assets\"]}'
" || return 1
}

test_ops_bins_present_and_executable() {
  local d="$TEMPLATE_ROOT/.io.v4rian.how-git/bin"
  for b in status ship release-of; do
    assert_file_exists "$d/$b" "bin/$b present" || return 1
    assert_executable "$d/$b" "bin/$b executable" || return 1
  done
}

test_status_bin_reports_seal_and_branch() {
  local d="$SCRATCH_BASE/22v-status"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  local out; out=$(.io.v4rian.how-git/bin/status)
  echo "$out" | grep -q "current version:" || { echo "status output missing 'current version:'"; return 1; }
  echo "$out" | grep -q "branch:" || { echo "status output missing 'branch:'"; return 1; }
  # JSON mode produces parseable JSON
  local json; json=$(.io.v4rian.how-git/bin/status --json)
  echo "$json" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || {
    echo "status --json output is not valid JSON: $json"; return 1; }
}

test_release_of_reports_unreleased_for_unmerged() {
  local d="$SCRATCH_BASE/22x-release-of"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev
  git checkout -q -b pool/n1.feature.probe
  echo a > probe
  git -c user.email=t@t -c user.name=t add probe
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] probe"
  local PROBE_SHA; PROBE_SHA=$(git rev-parse HEAD)
  local out; out=$(.io.v4rian.how-git/bin/release-of "$PROBE_SHA")
  echo "$out" | grep -q "unreleased" || { echo "release-of should report 'unreleased' for unmerged pool commit; got: $out"; return 1; }
}

test_ship_dry_run_describes_steps() {
  local d="$SCRATCH_BASE/22y-ship"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  # ship is the off-grid local release driver; flip mode before invoking.
  .io.v4rian.how-git/bin/set-mode off-grid >/dev/null
  git checkout -q -b dev
  git checkout -q -b pool/n1.feature.probe
  echo a > probe
  git -c user.email=t@t -c user.name=t add probe
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] probe"
  git checkout -q dev
  git -c user.email=t@t -c user.name=t merge --no-ff pool/n1.feature.probe -m "[MERGE] pool/n1 into dev"
  local out; out=$(.io.v4rian.how-git/bin/ship --dry-run 2>&1)
  echo "$out" | grep -q "shipping release" || { echo "ship --dry-run missing 'shipping release' line; got: $out"; return 1; }
  echo "$out" | grep -q "claim-main-release.sh" || { echo "ship --dry-run missing claim-main-release reference"; return 1; }
}

test_new_ops_bins_present_and_executable() {
  local d="$TEMPLATE_ROOT/.io.v4rian.how-git/bin"
  for b in queue changelog doctor preview-merge; do
    assert_file_exists "$d/$b" "bin/$b present" || return 1
    assert_executable "$d/$b" "bin/$b executable" || return 1
  done
}

test_lockdown_bin_present_and_executable() {
  # pool/n41: governance lockdown one-shot. Standalone runnable; refuses
  # cleanly when repo is private + free tier (rulesets API gated by Pro).
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/lockdown"
  assert_file_exists "$f" "bin/lockdown present" || return 1
  assert_executable "$f" "bin/lockdown executable" || return 1
  bash -n "$f" 2>&1 || { echo "bin/lockdown syntax error"; return 1; }
}

test_lockdown_help_describes_eligibility() {
  # --help must name the four rulesets it applies AND the Pro/public
  # eligibility requirement so operators do not run blind.
  local out
  out=$("$TEMPLATE_ROOT/.io.v4rian.how-git/bin/lockdown" --help 2>&1 || true)
  echo "$out" | grep -q "GitHub Pro" || { echo "--help missing Pro requirement note"; return 1; }
  echo "$out" | grep -q "pool" || { echo "--help missing pool ruleset mention"; return 1; }
  echo "$out" | grep -q "safety" || { echo "--help missing safety ruleset mention"; return 1; }
  echo "$out" | grep -q "vault" || { echo "--help missing vault ruleset mention"; return 1; }
  echo "$out" | grep -q "allocator-app-id" || { echo "--help missing allocator-app-id flag"; return 1; }
}

test_lockdown_refuses_without_repo_flag() {
  local out rc
  out=$("$TEMPLATE_ROOT/.io.v4rian.how-git/bin/lockdown" --allocator-app-id 12345 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || { echo "expected exit 2 without --repo, got $rc"; return 1; }
  echo "$out" | grep -q "repo OWNER/REPO is required" || { echo "missing --repo required message"; return 1; }
}

test_lockdown_refuses_without_allocator_id() {
  local out rc
  out=$("$TEMPLATE_ROOT/.io.v4rian.how-git/bin/lockdown" --repo example/test 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || { echo "expected exit 2 without --allocator-app-id, got $rc"; return 1; }
  echo "$out" | grep -q "allocator-app-id" || { echo "missing allocator-app-id required message"; return 1; }
}

test_framework_repo_marker_present_on_source() {
  # pool/n45: the FRAMEWORK_REPO marker file exists at the framework
  # source repo and gates framework-internal test runners (offline-test
  # workflow body, coverage.sh self-test fallback).
  # pool/n72: marker is presence-only; content must not embed any
  # owner/repo literal (the framework derives identity from origin URL
  # at runtime so an origin swap retests connectivity in one step).
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/FRAMEWORK_REPO"
  assert_file_exists "$f" "FRAMEWORK_REPO marker present on framework source" || return 1
  if grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+[[:space:]]*$' "$f"; then
    echo "marker content embeds owner/repo literal; the marker is presence-only"; return 1
  fi
}

test_root_readme_matches_shipped_template_on_source() {
  # pool/n49: the framework-source root README is a byte-copy of the
  # shipped templates/root-readme.template.md. bootstrap-ci's consumer-
  # cleanup md5-compares against the template, so drift between root
  # README and the template breaks the consumer-stub replacement on
  # downstream consumers. This test pins the parity.
  local root="$TEMPLATE_ROOT/README.md"
  local tmpl="$TEMPLATE_ROOT/.io.v4rian.how-git/templates/root-readme.template.md"
  assert_file_exists "$root" "root README present" || return 1
  assert_file_exists "$tmpl" "root-readme template present" || return 1
  local root_md5 tmpl_md5
  if command -v md5sum >/dev/null 2>&1; then
    root_md5=$(md5sum "$root" | awk '{print $1}')
    tmpl_md5=$(md5sum "$tmpl" | awk '{print $1}')
  else
    root_md5=$(md5 -q "$root")
    tmpl_md5=$(md5 -q "$tmpl")
  fi
  [ "$root_md5" = "$tmpl_md5" ] \
    || { echo "root README md5 ($root_md5) != template md5 ($tmpl_md5); sync them"; return 1; }
}

test_offline_test_workflow_gates_on_marker() {
  # pool/n45: offline-test.sh skips clean when the marker is absent so
  # consumer repos do not run framework-internal tests.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/workflows/offline-test.sh"
  assert_file_exists "$f" "offline-test.sh present" || return 1
  grep -q "FRAMEWORK_REPO" "$f" || { echo "marker check missing in offline-test.sh"; return 1; }
  grep -q "marker not present" "$f" || { echo "absent-marker skip message missing"; return 1; }
}

test_coverage_sh_template_fallback_gated_on_marker() {
  # pool/n45: coverage.sh's framework-tests fallback only fires when the
  # FRAMEWORK_REPO marker is present. Consumers with no project markers
  # see exit 2 with the override-required message, not a silent
  # framework-tests run.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/audits/coverage.sh"
  grep -q "FRAMEWORK_REPO" "$f" \
    || { echo "coverage.sh does not check FRAMEWORK_REPO marker"; return 1; }
  grep -q "framework source repo detected" "$f" \
    || { echo "framework-source detection log missing in coverage.sh"; return 1; }
  grep -q "Consumers must provide" "$f" \
    || { echo "consumer-override message missing in coverage.sh"; return 1; }
}

test_workflow_yamls_are_thin_dispatchers() {
  # pool/n45: workflow yamls dispatch to scripts in
  # .io.v4rian.how-git/scripts/workflows/. Pool/n55: the per-trigger
  # claim / audit / build / test workflows were collapsed into the
  # layered ci-dispatch harness, so the dispatch surface is now:
  #   - ci-dispatch.yml itself, which delegates to ci-dispatch.sh and
  #     to the matrix entries under ci/{tests,audits}/<trigger>/, each
  #     of which delegates to one of the scripts/workflows/*-retry.sh
  #     or offline-test.sh wrappers.
  #   - sys-layer required.*.sh entries (one per migrated check), each
  #     a thin exec into scripts/workflows/.
  # Verify the dispatcher pattern survives at both layers.
  local dispatcher="$TEMPLATE_ROOT/.github/workflows/ci-dispatch.yml"
  [ -f "$dispatcher" ] || { echo "missing workflow: $dispatcher"; return 1; }
  grep -qE 'bash \.io\.v4rian\.how-git/scripts/workflows/' "$dispatcher" \
    || { echo "ci-dispatch.yml does not dispatch to scripts/workflows/"; return 1; }
  # Each migrated sys-layer entry is a thin dispatcher into scripts/workflows/.
  local dispatch_count=0
  local entry
  for entry in \
    "$TEMPLATE_ROOT/.io.v4rian.how-git/ci/audits/push/required.compile.sh" \
    "$TEMPLATE_ROOT/.io.v4rian.how-git/ci/audits/push/required.coverage.sh" \
    "$TEMPLATE_ROOT/.io.v4rian.how-git/ci/audits/push/required.runtime.sh" \
    "$TEMPLATE_ROOT/.io.v4rian.how-git/ci/tests/push/required.offline-test-suites.sh" \
    "$TEMPLATE_ROOT/.io.v4rian.how-git/ci/audits/pr-merge-dev/required.claim.sh" \
    "$TEMPLATE_ROOT/.io.v4rian.how-git/ci/audits/pr-merge-main/required.claim.sh" \
    "$TEMPLATE_ROOT/.io.v4rian.how-git/ci/audits/tag/required.build.sh"; do
    [ -f "$entry" ] || { echo "missing sys-layer entry: $entry"; return 1; }
    if grep -qE 'scripts/workflows/' "$entry"; then
      dispatch_count=$((dispatch_count + 1))
    fi
  done
  [ "$dispatch_count" -ge 7 ] \
    || { echo "expected >= 7 sys-layer entries dispatching to scripts/workflows/, got $dispatch_count"; return 1; }
  # Legacy yamls deleted; defensive assert.
  local legacy
  for legacy in audit-pushed-branch test claim-on-merge-dev claim-on-merge-main build-on-tag; do
    if [ -f "$TEMPLATE_ROOT/.github/workflows/$legacy.yml" ]; then
      echo "ASSERT FAIL: legacy $legacy.yml still present; pool/n55 should have removed it"
      return 1
    fi
  done
}

test_workflow_dispatcher_scripts_present() {
  # pool/n45: each scripts/workflows/*.sh referenced by a workflow yaml
  # must exist + be executable.
  local d="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/workflows"
  assert_file_exists "$d" "scripts/workflows dir" || return 1
  for s in offline-test audit-retry build-retry claim-retry claim-tag-drift-sanity verify-actor-admin; do
    assert_file_exists "$d/$s.sh" "$s.sh" || return 1
    assert_executable "$d/$s.sh" "$s.sh executable" || return 1
    bash -n "$d/$s.sh" || { echo "$s.sh syntax error"; return 1; }
  done
}

test_bootstrap_ci_consumer_cleanup_step_present() {
  # pool/n45: bootstrap-ci has the step_consumer_cleanup function and
  # wires it into the main flow between step_topics and step_report.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/bootstrap-ci"
  grep -q "^step_consumer_cleanup()" "$f" \
    || { echo "step_consumer_cleanup function missing"; return 1; }
  grep -q "^step_consumer_cleanup\$" "$f" \
    || { echo "step_consumer_cleanup not wired in main flow"; return 1; }
  grep -q "FRAMEWORK_REPO marker present" "$f" \
    || { echo "cleanup step does not check marker for source-vs-consumer"; return 1; }
}

test_offline_test_workflow_skips_on_consumer_repo_e2e() {
  # Behavioral: in a scratch consumer repo (FRAMEWORK_REPO marker absent,
  # framework-tests/ absent), invoking offline-test.sh must exit 0 with
  # the skip message — not run the framework's suite, not fail.
  local d="$SCRATCH_BASE/22-offline-test-consumer"
  setup_scratch_repo "$d"
  cd "$d"
  rm -f .io.v4rian.how-git/FRAMEWORK_REPO  # ensure consumer state
  rm -rf framework-tests
  local out rc
  out=$(bash .io.v4rian.how-git/scripts/workflows/offline-test.sh 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || { echo "expected exit 0 on consumer, got $rc; output: $out"; return 1; }
  echo "$out" | grep -q "Skipping" \
    || { echo "expected skip message on consumer; got: $out"; return 1; }
  # Confirm the framework-tests suite did NOT run (the suite's output would
  # contain "passed, .* failed" tally — absent here).
  if echo "$out" | grep -qE "[0-9]+ passed, [0-9]+ failed"; then
    echo "consumer offline-test.sh ran the framework suite (leak); output: $out"
    return 1
  fi
}

test_offline_test_workflow_runs_on_framework_source_e2e() {
  # Behavioral: in a scratch repo with the marker present AND framework-tests/
  # populated, offline-test.sh actually runs the suite (exit code follows
  # the suite's outcome).
  local d="$SCRATCH_BASE/22-offline-test-source"
  setup_scratch_repo "$d"
  cd "$d"
  # Synthesize framework-source state: marker present + framework-tests/ with
  # a trivial passing suite.
  echo "# test fixture marker" > .io.v4rian.how-git/FRAMEWORK_REPO
  mkdir -p .io.v4rian.how-git/framework-tests
  cat > .io.v4rian.how-git/framework-tests/test-lifecycle.sh <<'SUITE'
#!/usr/bin/env bash
echo "  synthetic-test-1 ... PASS"
echo "  synthetic-test-2 ... PASS"
echo "=========================================================="
echo "  2 passed, 0 failed"
exit 0
SUITE
  cat > .io.v4rian.how-git/framework-tests/test-hooks.sh <<'SUITE'
#!/usr/bin/env bash
echo "  hooks-1 ... PASS"
echo "=== Summary ==="
echo "  1 passed, 0 failed"
exit 0
SUITE
  chmod +x .io.v4rian.how-git/framework-tests/test-lifecycle.sh .io.v4rian.how-git/framework-tests/test-hooks.sh
  local out rc
  out=$(LIFECYCLE_TEST_MODE=1 bash .io.v4rian.how-git/scripts/workflows/offline-test.sh 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || { echo "expected exit 0; got $rc; output: $out"; return 1; }
  echo "$out" | grep -q "marker present" \
    || { echo "marker-detection log missing; output: $out"; return 1; }
  echo "$out" | grep -q "running lifecycle suite" \
    || { echo "lifecycle invocation log missing; output: $out"; return 1; }
  echo "$out" | grep -q "synthetic-test-1" \
    || { echo "synthetic lifecycle suite did not actually run; output: $out"; return 1; }
}

test_coverage_sh_exits_2_on_consumer_with_no_project_markers_e2e() {
  # Behavioral: in a scratch consumer with no package.json, no CMakeLists.txt,
  # no marker, coverage.sh must exit 2 with the override-required message,
  # NOT silently run framework tests.
  local d="$SCRATCH_BASE/22-coverage-consumer-no-markers"
  setup_scratch_repo "$d"
  cd "$d"
  rm -f .io.v4rian.how-git/FRAMEWORK_REPO
  rm -rf framework-tests
  local out rc
  out=$(bash .io.v4rian.how-git/scripts/audits/coverage.sh 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || { echo "expected exit 2 on no-marker consumer, got $rc; output: $out"; return 1; }
  echo "$out" | grep -q "Consumers must provide" \
    || { echo "expected override-required message; got: $out"; return 1; }
  echo "$out" | grep -q "no project type detected" \
    || { echo "expected no-project-detected message; got: $out"; return 1; }
}

test_coverage_sh_runs_framework_tests_when_marker_present_e2e() {
  # Behavioral: in a scratch repo synthesizing the framework source state
  # (marker + framework-tests/ populated), coverage.sh actually runs the
  # framework's test-lifecycle.sh as the self-coverage proxy and exits 0.
  local d="$SCRATCH_BASE/22-coverage-framework-source"
  setup_scratch_repo "$d"
  cd "$d"
  echo "# test fixture marker" > .io.v4rian.how-git/FRAMEWORK_REPO
  mkdir -p .io.v4rian.how-git/framework-tests
  cat > .io.v4rian.how-git/framework-tests/test-lifecycle.sh <<'SUITE'
#!/usr/bin/env bash
echo "[from synthetic framework-tests] passed"
exit 0
SUITE
  chmod +x .io.v4rian.how-git/framework-tests/test-lifecycle.sh
  local out rc
  out=$(bash .io.v4rian.how-git/scripts/audits/coverage.sh 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || { echo "expected exit 0 on framework source; got $rc; output: $out"; return 1; }
  echo "$out" | grep -q "framework source repo detected" \
    || { echo "framework-source detection log missing; output: $out"; return 1; }
  echo "$out" | grep -q "from synthetic framework-tests" \
    || { echo "framework-tests script did not actually run; output: $out"; return 1; }
}

test_bootstrap_ci_consumer_cleanup_actually_removes_framework_tests_e2e() {
  # Behavioral: in a scratch consumer with synthetic framework-tests/ and
  # framework-self-tests.yml + marker absent, the consumer-cleanup step
  # (extracted and run in isolation) actually removes both. README is
  # replaced because its md5 matches the framework's README.
  local d="$SCRATCH_BASE/22-bootstrap-cleanup-e2e"
  setup_scratch_repo "$d"
  cd "$d"
  rm -f .io.v4rian.how-git/FRAMEWORK_REPO
  mkdir -p .io.v4rian.how-git/framework-tests .github/workflows
  echo "synthetic" > .io.v4rian.how-git/framework-tests/test-lifecycle.sh
  echo "name: framework-self-tests" > .github/workflows/framework-self-tests.yml
  # README matches the framework's root-readme template so the md5-gated
  # replace fires. (Pre-pool/n49 this compared root README to the namespace
  # README; now it compares to the shipped templates/root-readme.template.md.)
  cp "$TEMPLATE_ROOT/.io.v4rian.how-git/templates/root-readme.template.md" README.md 2>/dev/null || \
    cp .io.v4rian.how-git/templates/root-readme.template.md README.md

  # Run the cleanup function in isolation. Source bootstrap-ci's body up to
  # the main block and just call step_consumer_cleanup.
  REPO_ROOT="$PWD" OWNER_REPO="test/consumer" MODE="apply" \
    bash -c '
      ok()   { printf "  ok %s\n" "$1"; }
      miss() { printf "  miss %s - %s\n" "$1" "$2"; }
      note() { printf "  . %s\n" "$1"; }
      hdr()  { printf "\n-> %s\n" "$1"; }
      # Inline the function body so we exercise the real code from disk
      eval "$(sed -n "/^step_consumer_cleanup/,/^}$/p" .io.v4rian.how-git/bin/bootstrap-ci)"
      step_consumer_cleanup
    ' >/dev/null 2>&1

  # Post-conditions (pool/n47 revised):
  #   - .io.v4rian.how-git/framework-tests/ STAYS (diagnostic suite for bin/doctor --deep)
  #   - .github/workflows/framework-self-tests.yml is removed
  #   - README.md replaced with consumer stub (md5 matched)
  [ -d .io.v4rian.how-git/framework-tests ] || {
    echo ".io.v4rian.how-git/framework-tests/ was removed by cleanup — pool/n47 reverted that deletion"; return 1; }
  [ ! -f .github/workflows/framework-self-tests.yml ] || {
    echo "framework-self-tests.yml still present after cleanup"; return 1; }
  grep -q "Your project description here." README.md \
    || { echo "README.md was not replaced with consumer stub; got: $(head -5 README.md)"; return 1; }
}

test_bootstrap_ci_consumer_cleanup_handles_both_modes_in_body() {
  # pool/n45: instead of an end-to-end behavioral run (which requires
  # auth tokens + GitHub API mock), assert the step's body covers BOTH
  # paths inline: replaces README.md only when md5-matched, removes the
  # framework-self-tests workflow. Pool/n47 explicitly removed the
  # framework-tests/ deletion (it stays for bin/doctor --deep).
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/bootstrap-ci"
  grep -q 'rm -f "\$fw_self_workflow"' "$f" \
    || { echo "cleanup does not remove framework-self-tests.yml"; return 1; }
  grep -q 'md5sum\|md5 -q' "$f" \
    || { echo "README replacement is not gated on md5 comparison"; return 1; }
  grep -q "consumer stub" "$f" \
    || { echo "consumer README stub generation missing"; return 1; }
  grep -q 'MODE = "check"\|MODE" = "check"' "$f" \
    || { echo "check mode path missing in consumer-cleanup"; return 1; }
  grep -q 'MODE = "dry-run"\|MODE" = "dry-run"' "$f" \
    || { echo "dry-run mode path missing in consumer-cleanup"; return 1; }
}

test_vault_readonly_ruleset_present() {
  # pool/n41 added vault-readonly.json so apply-repo-rules + lockdown both
  # have the same source of truth for the vault ruleset. pool/n44 extended
  # the include patterns to cover both legacy flat and prefixed layouts.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/rulesets/vault-readonly.json"
  assert_file_exists "$f" "vault-readonly.json present" || return 1
  grep -q "v4rian-vault-readonly" "$f" || { echo "ruleset name missing"; return 1; }
  grep -q "refs/heads/vault/\*\"" "$f" || { echo "legacy flat vault/* pattern missing"; return 1; }
  grep -q "refs/heads/vault/\*/\*" "$f" || { echo "prefixed vault/*/* pattern missing"; return 1; }
}

test_archive_pool_branch_builds_prefixed_vault_path() {
  # pool/n44: archive-pool-branch.sh must compute a vYYYY.MAIN prefix from
  # bin/version --seal and build vault/<prefix>/<suffix>, falling back to
  # the legacy flat vault/<suffix> when seal is empty or malformed. Since
  # n51 the same script also accepts a PREFIXED pool input and uses
  # BARE_SUFFIX (the suffix with any leading major-prefix consumed) when
  # composing the legacy + prefixed vault refs so the input layout is
  # round-tripped without double-prefixing.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/archive-pool-branch.sh"
  grep -qE 'LEGACY_VAULT_BRANCH="vault/\$(BARE_)?SUFFIX"' "$f" \
    || { echo "legacy vault path variable not defined"; return 1; }
  grep -q '^MAJOR_PREFIX=' "$f" \
    || { echo "MAJOR_PREFIX initialization missing"; return 1; }
  grep -q '\$VERSION_BIN.*--seal' "$f" \
    || { echo "bin/version --seal invocation missing"; return 1; }
  grep -q 'MAJOR_PREFIX="\${SEAL%\.\*}"' "$f" \
    || { echo "parameter-expansion trim of trailing .DEV segment missing"; return 1; }
  grep -qE 'VAULT_BRANCH="vault/\$MAJOR_PREFIX/\$(BARE_)?SUFFIX"' "$f" \
    || { echo "prefixed VAULT_BRANCH composition missing"; return 1; }
  # Fallback path must also be visible
  grep -q 'VAULT_BRANCH="\$LEGACY_VAULT_BRANCH"' "$f" \
    || { echo "legacy-fallback assignment missing"; return 1; }
}

test_archive_pool_branch_legacy_match_guard() {
  # pool/n44: if the legacy flat vault already exists for a suffix (from a
  # pre-prefix-era archive), the script treats it as the canonical vault
  # for that suffix and does NOT double-vault under the prefixed path.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/archive-pool-branch.sh"
  grep -q 'legacy_vault_exists=true' "$f" \
    || { echo "legacy_vault_exists tracking missing"; return 1; }
  grep -q 'legacy-match guard' "$f" \
    || { echo "legacy-match guard comment block missing"; return 1; }
  grep -q 'EFFECTIVE_VAULT="\$LEGACY_VAULT_BRANCH"' "$f" \
    || { echo "EFFECTIVE_VAULT reassignment to legacy missing"; return 1; }
}

test_archive_pool_branch_prefixed_path_e2e() {
  # End-to-end: in a scratch repo with bin/version reachable, calling
  # archive-pool-branch.sh --dry-run on a pool branch must mention the
  # prefixed vault path in its planned output.
  local d="$SCRATCH_BASE/22-archive-prefixed"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev
  echo a > .seed
  git -c user.email=t@t -c user.name=t add .seed
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] seed"
  # Annotate dev with a tag so bin/version --seal returns something parseable.
  local year; year=$(date -u +%Y)
  git tag -a "v${year}.0.1" -m "synthetic" HEAD
  git checkout -q -b pool/n9.feature.probe
  echo p > .p
  git -c user.email=t@t -c user.name=t add .p
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] probe"
  git push -q origin pool/n9.feature.probe
  local out; out=$(bash .io.v4rian.how-git/scripts/archive-pool-branch.sh --dry-run pool/n9.feature.probe 2>&1)
  echo "$out" | grep -qE "vault/v${year}\.0/n9\.feature\.probe" \
    || { echo "dry-run did not surface prefixed vault path; got: $out"; return 1; }
}

test_claim_main_release_gc_resolves_both_vault_layouts() {
  # pool/n44: the 3-gate GC must find vault branches whether they live at
  # the legacy flat refs/heads/vault/<suffix> or the new prefixed
  # refs/heads/vault/<vYYYY.MAIN>/<suffix>. The resolve_vault_ref helper
  # tries the flat path first then walks the prefixed candidates.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/claim-main-release.sh"
  grep -q '^  resolve_vault_ref()' "$f" \
    || { echo "resolve_vault_ref helper missing"; return 1; }
  grep -q '"vault/\$suf"' "$f" \
    || { echo "legacy flat lookup in resolver missing"; return 1; }
  grep -q '"vault/\*/\$suf"' "$f" \
    || { echo "prefixed wildcard lookup in resolver missing"; return 1; }
}

test_apply_repo_rules_surfaces_pro_required_no_silent_mask() {
  # pool/n41 removed the "(ruleset may already exist - verify in UI)"
  # silent-mask line that hid the 403 returned when the repo is private +
  # free tier. The script must now surface "GitHub Pro" in its error
  # path instead of fallthrough-OK.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/apply-repo-rules.sh"
  if grep -q "ruleset may already exist - verify in UI" "$f"; then
    echo "silent-mask line still present in apply-repo-rules.sh"
    return 1
  fi
  grep -q "GitHub Pro" "$f" || { echo "Pro requirement message not surfaced"; return 1; }
}

test_doctor_clean_repo_reports_ok() {
  local d="$SCRATCH_BASE/22z-doctor-clean"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  if ! .io.v4rian.how-git/bin/doctor --quiet 2>&1; then
    echo "doctor reported issues on a fresh healthy repo:"
    .io.v4rian.how-git/bin/doctor 2>&1 | head -10
    return 1
  fi
}

test_doctor_deep_flag_present_in_help() {
  # pool/n47: bin/doctor --deep is documented in --help output.
  local out
  out=$("$TEMPLATE_ROOT/.io.v4rian.how-git/bin/doctor" --help 2>&1 || true)
  echo "$out" | grep -q -- "--deep" \
    || { echo "doctor --help missing --deep flag mention"; return 1; }
  echo "$out" | grep -q "behavioral diagnostics" \
    || { echo "doctor --help missing 'behavioral diagnostics' description"; return 1; }
  echo "$out" | grep -q "framework-tests/" \
    || { echo "doctor --help does not mention framework-tests/ as the diagnostic source"; return 1; }
}

test_doctor_deep_runs_framework_tests_e2e() {
  # End-to-end: in a scratch repo with framework-tests/ populated with a
  # trivial passing suite, bin/doctor --deep --quiet exits 0; with a
  # failing suite it exits non-zero. The deep mode is gated on the
  # directory's existence — not on the FRAMEWORK_REPO marker — because
  # the marker gates AUTOMATIC CI runs only; the on-demand doctor
  # invocation runs whatever framework-tests/ contains.
  local d="$SCRATCH_BASE/22z-doctor-deep-pass"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  mkdir -p .io.v4rian.how-git/framework-tests
  cat > .io.v4rian.how-git/framework-tests/test-lifecycle.sh <<'PASS'
#!/usr/bin/env bash
echo "  synthetic ... PASS"
echo "  1 passed, 0 failed"
exit 0
PASS
  cat > .io.v4rian.how-git/framework-tests/test-hooks.sh <<'PASS'
#!/usr/bin/env bash
echo "  hooks-synthetic ... PASS"
exit 0
PASS
  chmod +x .io.v4rian.how-git/framework-tests/test-lifecycle.sh .io.v4rian.how-git/framework-tests/test-hooks.sh
  if ! .io.v4rian.how-git/bin/doctor --deep --quiet 2>&1; then
    echo "doctor --deep --quiet exited non-zero on passing framework-tests"
    return 1
  fi

  # Now flip the lifecycle suite to fail; doctor --deep must exit non-zero
  cat > .io.v4rian.how-git/framework-tests/test-lifecycle.sh <<'FAIL'
#!/usr/bin/env bash
echo "  synthetic ... FAIL"
exit 1
FAIL
  if .io.v4rian.how-git/bin/doctor --deep --quiet 2>&1; then
    echo "doctor --deep --quiet exited 0 on a failing framework-tests suite (should fail)"
    return 1
  fi
}

test_doctor_default_mode_does_not_run_framework_tests_e2e() {
  # The default doctor mode (no --deep) must stay fast: even if
  # framework-tests/ contains a slow or failing suite, default doctor
  # only does structural checks and ignores it.
  local d="$SCRATCH_BASE/22z-doctor-default-stays-fast"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  mkdir -p .io.v4rian.how-git/framework-tests
  cat > .io.v4rian.how-git/framework-tests/test-lifecycle.sh <<'FAIL'
#!/usr/bin/env bash
echo "this should not be invoked by default doctor"
sleep 60
exit 1
FAIL
  chmod +x .io.v4rian.how-git/framework-tests/test-lifecycle.sh
  # Default doctor must complete in under 5 seconds (no framework-tests
  # invocation). Use timeout to prove it.
  local start end elapsed
  start=$(date +%s)
  .io.v4rian.how-git/bin/doctor --quiet >/dev/null 2>&1 || true
  end=$(date +%s)
  elapsed=$((end - start))
  if [ "$elapsed" -gt 5 ]; then
    echo "default doctor took ${elapsed}s — must complete fast (no framework-tests invocation)"
    return 1
  fi
}

test_bootstrap_ci_cleanup_keeps_framework_tests_on_consumer() {
  # pool/n47: the consumer-cleanup step KEEPS framework-tests/ (was
  # deleting in pool/n45). Assert via script body — the rm -rf line on
  # the framework-tests directory MUST be gone.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/bootstrap-ci"
  if grep -q 'rm -rf "\$fw_tests_dir"' "$f"; then
    echo "bootstrap-ci still deletes framework-tests/ — pool/n47 should have removed that"
    return 1
  fi
  grep -q "kept (diagnostic suite for bin/doctor --deep)" "$f" \
    || { echo "consumer-cleanup does not announce keeping framework-tests/ as diagnostic"; return 1; }
}

test_doctor_detects_stray_version_file() {
  local d="$SCRATCH_BASE/22z-doctor-stray"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  echo "v2026.1.5" > VERSION
  local out; out=$(.io.v4rian.how-git/bin/doctor 2>&1) || true
  echo "$out" | grep -q "stray VERSION" || { echo "doctor did not flag stray VERSION; got: $out"; return 1; }
}

test_doctor_detects_missing_bin() {
  local d="$SCRATCH_BASE/22z-doctor-missing"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  rm .io.v4rian.how-git/bin/status
  local out; out=$(.io.v4rian.how-git/bin/doctor 2>&1) || true
  echo "$out" | grep -q "missing:.*bin/status" || { echo "doctor did not flag missing bin/status; got: $out"; return 1; }
}

test_queue_no_open_prs_reports_none() {
  local d="$SCRATCH_BASE/22z-queue-empty"
  setup_scratch_repo "$d"
  cd "$d"
  . "$TEMPLATE_ROOT/.io.v4rian.how-git/framework-tests/_gh_mock_enable.sh"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  local out; out=$(.io.v4rian.how-git/bin/queue 2>&1)
  echo "$out" | grep -q "no open PRs" || { echo "queue should report no open PRs; got: $out"; return 1; }
}

test_queue_json_with_mock_prs() {
  local d="$SCRATCH_BASE/22z-queue-json"
  setup_scratch_repo "$d"
  cd "$d"
  . "$TEMPLATE_ROOT/.io.v4rian.how-git/framework-tests/_gh_mock_enable.sh"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev
  git push -q origin dev
  # Seed two pool branches + PRs in the mock
  git checkout -q -b pool/n1.feature.a
  echo a > shared.txt
  git -c user.email=t@t -c user.name=t add shared.txt
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] A"
  git push -q origin pool/n1.feature.a
  git checkout -q dev
  git checkout -q -b pool/n2.feature.b
  echo b > shared.txt
  git -c user.email=t@t -c user.name=t add shared.txt
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] B"
  git push -q origin pool/n2.feature.b
  gh pr create --title "first" --body b --base dev --head pool/n1.feature.a --repo j/m >/dev/null
  gh pr create --title "second" --body b --base dev --head pool/n2.feature.b --repo j/m >/dev/null
  local json; json=$(.io.v4rian.how-git/bin/queue --json 2>&1)
  echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
assert len(data) == 2, f'expected 2 PRs in queue; got {len(data)}'
# Both PRs touch shared.txt -> should conflict with each other
nums = {p['num']: set(p['conflicts_with']) for p in data}
assert 2 in nums.get(1, set()), f'PR 1 should conflict with PR 2; got {nums.get(1)}'
assert 1 in nums.get(2, set()), f'PR 2 should conflict with PR 1; got {nums.get(2)}'
" || return 1
}

test_changelog_no_tags_prints_empty_section() {
  local d="$SCRATCH_BASE/22z-changelog-empty"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  local out; out=$(.io.v4rian.how-git/bin/changelog 2>&1)
  echo "$out" | grep -q "# Changelog" || { echo "changelog missing header; got: $out"; return 1; }
  echo "$out" | grep -q "No tags this year" || { echo "changelog should say no tags; got: $out"; return 1; }
}

test_changelog_with_tags_lists_commits() {
  local d="$SCRATCH_BASE/22z-changelog-tags"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev
  echo a > a.txt
  git -c user.email=t@t -c user.name=t add a.txt
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] feature a"
  local year; year=$(date -u +%Y)
  git tag -a "v${year}.0.1" -m "first"
  local out; out=$(.io.v4rian.how-git/bin/changelog 2>&1)
  echo "$out" | grep -q "v${year}.0.1" || { echo "changelog missing tag header; got: $out"; return 1; }
  echo "$out" | grep -q "feature a" || { echo "changelog missing commit; got: $out"; return 1; }
}

test_preview_merge_predicts_clean_merge() {
  local d="$SCRATCH_BASE/22z-preview-clean"
  setup_scratch_repo "$d"
  cd "$d"
  . "$TEMPLATE_ROOT/.io.v4rian.how-git/framework-tests/_gh_mock_enable.sh"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev
  git push -q origin dev
  git checkout -q -b pool/n1.feature.x
  echo x > x.txt
  git -c user.email=t@t -c user.name=t add x.txt
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] x"
  git push -q origin pool/n1.feature.x
  gh pr create --title "x" --body b --base dev --head pool/n1.feature.x --repo j/m >/dev/null
  local out; out=$(.io.v4rian.how-git/bin/preview-merge 1 2>&1)
  echo "$out" | grep -q "CLEAN" || { echo "preview should predict CLEAN merge; got: $out"; return 1; }
}

test_canary_full_integration_local_consumer() {
  # M3 prime: a NON-template consumer repo that uses the template bins
  # end-to-end. Goes one step beyond the M3 simulator by structuring the
  # consumer with its own code + .io.v4rian.how-git copy + the full
  # claim flow + version bin reads + ops bins functioning.
  local d="$SCRATCH_BASE/22z-canary"
  setup_scratch_repo "$d"
  cd "$d"
  . "$TEMPLATE_ROOT/.io.v4rian.how-git/framework-tests/_gh_mock_enable.sh"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null

  # Doctor on a freshly-healed repo must report OK
  .io.v4rian.how-git/bin/doctor --quiet || { echo "doctor failed on fresh repo"; return 1; }

  # Add some "real" consumer code (mimicking a CLI tool)
  mkdir -p src
  cat > src/main.py <<'PY'
def hello(): return "hello v4rian"
PY
  git -c user.email=t@t -c user.name=t add src/main.py
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] initial src/main.py"

  # Stage dev
  git checkout -q -b dev
  git push -q origin dev

  # 3 feature cycles
  local year; year=$(date -u +%Y)
  for i in 1 2 3; do
    git checkout -q -b "pool/n${i}.feature.endpoint-${i}"
    cat >> src/main.py <<EOF
def endpoint_${i}(): return "endpoint $i"
EOF
    git -c user.email=t@t -c user.name=t add src/main.py
    git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] endpoint ${i}"
    git checkout -q dev
    git -c user.email=t@t -c user.name=t merge --no-ff "pool/n${i}.feature.endpoint-${i}" -m "[MERGE] endpoint ${i} into dev"
    git push -q origin dev
  done

  # status bin reports a sane snapshot
  local status_out; status_out=$(.io.v4rian.how-git/bin/status 2>&1)
  echo "$status_out" | grep -q "v${year}.0.3" || { echo "status didn't show v${year}.0.3; got: $status_out"; return 1; }

  # changelog has all 3 feature tags
  local cl; cl=$(.io.v4rian.how-git/bin/changelog 2>&1)
  for v in "v${year}.0.1" "v${year}.0.2" "v${year}.0.3"; do
    echo "$cl" | grep -q "$v" || { echo "changelog missing $v"; return 1; }
  done

  # release-of reports the right release for the dev tip
  local dev_tip_sha; dev_tip_sha=$(git rev-parse HEAD)
  # dev tip isn't on main yet -> "unreleased"
  local ro; ro=$(.io.v4rian.how-git/bin/release-of "$dev_tip_sha" 2>&1)
  echo "$ro" | grep -q "unreleased" || { echo "release-of should say unreleased for unmerged commit; got: $ro"; return 1; }

  # Ship: dev -> main release
  git checkout -q main
  git -c user.email=t@t -c user.name=t merge --no-ff dev -m "[MERGE] dev into main: release"
  bash .io.v4rian.how-git/scripts/claim-main-release.sh --skip-pull >/dev/null

  # release-of on main HEAD now finds the v_year.1.3 release tag
  local main_sha; main_sha=$(git rev-parse HEAD)
  local ro2; ro2=$(.io.v4rian.how-git/bin/release-of "$main_sha" 2>&1)
  echo "$ro2" | grep -qE "^v${year}\.0\.3$" || { echo "release-of on main HEAD should be v${year}.0.3; got: $ro2"; return 1; }
}

test_l1_l5_reconcile_real_conflict_behavioral() {
  # Behavioral: construct two pool branches with conflicting changes,
  # merge one, attempt the auto-rebase-pools script on the other.
  # Since LIFECYCLE_TEST_MODE shorts-circuit the auto-rebase, exercise
  # the script's helpers + the cherry-pick + claude_skill_run mock
  # directly to prove the L1-L5 ladder runs.
  local d="$SCRATCH_BASE/22z-l1-l5-behavioral"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev
  echo "shared: ORIG" > shared.txt
  git -c user.email=t@t -c user.name=t add shared.txt
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[NEW] seed"

  git checkout -q -b pool/n1.feature.a
  echo "shared: A" > shared.txt
  git -c user.email=t@t -c user.name=t add shared.txt
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[REFACTOR] A"

  git checkout -q dev
  git checkout -q -b pool/n2.feature.b
  echo "shared: B" > shared.txt
  git -c user.email=t@t -c user.name=t add shared.txt
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[REFACTOR] B"

  git checkout -q dev
  git -c user.email=t@t -c user.name=t merge --no-ff pool/n1.feature.a -m "[MERGE] A"

  # Attempt cherry-pick of pool/n2's commit onto dev (mimics what the
  # reconcile flow does). MUST conflict.
  local PB_TIP; PB_TIP=$(git rev-parse pool/n2.feature.b)
  git checkout -q -b __l1l5_test dev
  if git cherry-pick "$PB_TIP" 2>/dev/null; then
    echo "expected conflict on cherry-pick"; return 1
  fi
  # Verify the conflict markers exist in shared.txt
  grep -q "<<<<<<<" shared.txt || { echo "conflict markers absent in shared.txt"; git cherry-pick --abort 2>/dev/null; return 1; }
  # The auto-rebase script's L3 strategy is `-X theirs`. Verify that
  # strategy resolves the conflict (theirs = pool/n2's content).
  git cherry-pick --abort
  if ! git cherry-pick -X theirs "$PB_TIP" >/dev/null 2>&1; then
    echo "L3 strategy (-X theirs) did not auto-resolve"; return 1
  fi
  # Verify theirs won (shared.txt should have B's content)
  grep -q "shared: B" shared.txt || { echo "L3 -X theirs result: shared.txt does not show B's value"; return 1; }
}

test_multi_iter_reconcile_naming_chain() {
  # Verify the auto-rebase script's iterative chain logic: if
  # pool/n3.reconcile.X exists on origin, the next reconcile is
  # pool/n3.reconcile.X-2, then -3, etc.
  local d="$SCRATCH_BASE/22z-multi-iter"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  git checkout -q -b dev
  git push -q origin dev
  # Push three reconcile branches simulating prior iterations
  git push -q origin dev:refs/heads/pool/n3.reconcile.thing
  git push -q origin dev:refs/heads/pool/n3.reconcile.thing-2
  # Reproduce the iter-detection logic from auto-rebase-pools-after-dev-merge.sh
  RECON="pool/n3.reconcile.thing"
  if git ls-remote --heads origin "$RECON" 2>/dev/null | grep -q "$RECON"; then
    ITER=2
    while git ls-remote --heads origin "${RECON}-${ITER}" 2>/dev/null | grep -q "${RECON}-${ITER}"; do
      ITER=$((ITER + 1))
    done
    RECON="${RECON}-${ITER}"
  fi
  assert_eq "$RECON" "pool/n3.reconcile.thing-3" "iter chain advances to -3" || return 1
}

# ----------------------------------------------------------------------------
# bootstrap-ci enhancements (pool/n38): merge-commit defaults, merge-mode
# lock, auto-delete disable, repo topics, and extended required-status-check
# binding (compile / coverage / runtime / opened-via-correct-flow on dev).
# ----------------------------------------------------------------------------

# Helper: stand up a $PATH stub dir where a fake `curl` returns canned JSON
# matched by URL substring. Pairs are 'pattern|json'; first hit wins. The
# delimiter is '|' (not ':') so JSON colons do not clash. Unmatched URLs
# return '{}'.
_bootstrap_ci_install_curl_mock() {
  local stub_dir="$1"; shift
  mkdir -p "$stub_dir"
  local mock_data="$stub_dir/_mock_data"
  : > "$mock_data"
  local pair
  for pair in "$@"; do
    printf '%s\n' "$pair" >> "$mock_data"
  done
  cat > "$stub_dir/curl" <<'CURL_STUB'
#!/usr/bin/env bash
url=""
for a in "$@"; do
  case "$a" in
    http*) url="$a" ;;
  esac
done
data_file="$(dirname "$0")/_mock_data"
if [ -f "$data_file" ] && [ -n "$url" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    pat="${line%%|*}"
    json="${line#*|}"
    if [ -n "$pat" ] && [ "${url#*$pat}" != "$url" ]; then
      printf '%s' "$json"
      exit 0
    fi
  done < "$data_file"
fi
printf '{}'
CURL_STUB
  chmod +x "$stub_dir/curl"
}

test_bootstrap_ci_required_checks_dev_includes_compile_coverage_runtime() {
  # The pool/n38 extension binds compile/coverage/runtime as required
  # status checks on PRs into dev. Pool/n55 + pool/n58: the bindings
  # are no longer a hardcoded array; bin/bootstrap-ci now discovers them
  # dynamically by walking ci/{tests,audits}/push/required.*.sh across
  # the usr + sys layers. The bound context names are the basenames
  # (minus .sh): required.compile, required.coverage, required.runtime,
  # required.offline-test-suites. The audits run on the push event that
  # lands the head SHA; the PR reuses the result on pr-open by context
  # name.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/bootstrap-ci"
  assert_grep "dev_checks=(" "$f" "dev_checks array drives the binding" || return 1
  assert_grep "_discover_required_checks push" "$f" "discovery walks push trigger" || return 1
  # The sys-layer entries that drive the discovered names must exist.
  local entry
  for entry in \
    "$TEMPLATE_ROOT/.io.v4rian.how-git/ci/audits/push/required.compile.sh" \
    "$TEMPLATE_ROOT/.io.v4rian.how-git/ci/audits/push/required.coverage.sh" \
    "$TEMPLATE_ROOT/.io.v4rian.how-git/ci/audits/push/required.runtime.sh" \
    "$TEMPLATE_ROOT/.io.v4rian.how-git/ci/tests/push/required.offline-test-suites.sh"; do
    [ -f "$entry" ] || { echo "bootstrap-ci discovery surface missing: $entry"; return 1; }
  done
  echo "  ok: required.* discovery walks push trigger and covers compile/coverage/runtime/offline-test-suites"
}

test_bootstrap_ci_required_checks_dev_includes_opened_via_correct_flow() {
  # 'opened-via-correct-flow' is the validator emitted by the PR-open bundle
  # (pool/n34/n35). The binding ships in pool/n38 so the gate is active the
  # moment the workflow lands.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/bootstrap-ci"
  grep -q '"opened-via-correct-flow"' "$f" || {
    echo "bootstrap-ci dev_checks missing opened-via-correct-flow"; return 1; }
}

test_bootstrap_ci_step_merge_commit_defaults_present() {
  # Step 6: merge_commit_title=PR_TITLE, merge_commit_message=PR_BODY.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/bootstrap-ci"
  assert_grep "step_merge_commit_defaults()" "$f" "step function defined" || return 1
  grep -q '"merge_commit_title":"PR_TITLE"' "$f" || { echo "PATCH body missing merge_commit_title=PR_TITLE"; return 1; }
  grep -q '"merge_commit_message":"PR_BODY"' "$f" || { echo "PATCH body missing merge_commit_message=PR_BODY"; return 1; }
  # Idempotency: must probe via GET before PATCH.
  awk '/^step_merge_commit_defaults\(\)/,/^}/' "$f" | grep -q "curl -sS" \
    || { echo "step_merge_commit_defaults missing GET probe"; return 1; }
}

test_bootstrap_ci_step_merge_mode_lock_present() {
  # Step 7: allow_squash_merge=false, allow_rebase_merge=false, allow_merge_commit=true.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/bootstrap-ci"
  assert_grep "step_merge_mode_lock()" "$f" "step function defined" || return 1
  grep -q '"allow_squash_merge":false' "$f" || { echo "PATCH body missing allow_squash_merge=false"; return 1; }
  grep -q '"allow_rebase_merge":false' "$f" || { echo "PATCH body missing allow_rebase_merge=false"; return 1; }
  grep -q '"allow_merge_commit":true'  "$f" || { echo "PATCH body missing allow_merge_commit=true"; return 1; }
  awk '/^step_merge_mode_lock\(\)/,/^}/' "$f" | grep -q "curl -sS" \
    || { echo "step_merge_mode_lock missing GET probe"; return 1; }
}

test_bootstrap_ci_step_disable_auto_delete_present() {
  # Step 8: delete_branch_on_merge=false.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/bootstrap-ci"
  assert_grep "step_disable_auto_delete()" "$f" "step function defined" || return 1
  grep -q '"delete_branch_on_merge":false' "$f" || { echo "PATCH body missing delete_branch_on_merge=false"; return 1; }
  awk '/^step_disable_auto_delete\(\)/,/^}/' "$f" | grep -q "curl -sS" \
    || { echo "step_disable_auto_delete missing GET probe"; return 1; }
}

test_bootstrap_ci_step_topics_present() {
  # Step 9: topics include 'v4rian' and 'how-git'.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/bootstrap-ci"
  assert_grep "step_topics()" "$f" "step function defined" || return 1
  assert_grep 'wanted="v4rian how-git"' "$f" "wanted topics declared" || return 1
  # Topics endpoint uses PUT, not PATCH.
  awk '/^step_topics\(\)/,/^}/' "$f" | grep -q "api_call PUT" \
    || { echo "step_topics missing PUT call"; return 1; }
  awk '/^step_topics\(\)/,/^}/' "$f" | grep -q "/topics" \
    || { echo "step_topics missing /topics endpoint"; return 1; }
}

test_bootstrap_ci_steps_wired_in_main() {
  # Every new step function must be invoked in the main flow at the bottom
  # of the script. Without this, the function exists but never runs.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/bootstrap-ci"
  local s
  for s in step_merge_commit_defaults step_merge_mode_lock step_disable_auto_delete step_topics step_workflows_enabled; do
    grep -E "^$s\$" "$f" >/dev/null || { echo "$s not wired in main"; return 1; }
  done
}

test_bootstrap_ci_step_workflows_enabled_present() {
  # The per-workflow enable step must be defined as a function, must
  # carry the step 1b header label, and must call the enable endpoint
  # in apply mode.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/bootstrap-ci"
  grep -q "^step_workflows_enabled()" "$f" \
    || { echo "step_workflows_enabled function not defined"; return 1; }
  grep -q "step 1b: per-workflow enable state" "$f" \
    || { echo "step 1b header label missing"; return 1; }
  grep -q "actions/workflows/\$basename/enable" "$f" \
    || { echo "enable endpoint not referenced"; return 1; }
  grep -q "disabled_manually" "$f" \
    || { echo "step does not match disabled_manually state"; return 1; }
}

test_bootstrap_ci_step_workflows_enabled_dry_run_emits_put() {
  # With the workflows API mocked to report one workflow as
  # disabled_manually, --dry-run must surface the [dry-run] PUT enable
  # line for that workflow file. Confirms the script reads the registry
  # and routes the disabled state through the dry-run print branch.
  #
  # Pool/n55 + pool/n58: the standalone test.yml workflow was migrated
  # into the layered ci-dispatch harness, so the mock uses
  # ci-dispatch.yml (which exists on disk in the template) as the
  # disabled-state target. step_workflows_enabled walks the on-disk
  # workflow files, so the mocked basename must match a real shipping
  # file.
  local d="$SCRATCH_BASE/22z-bootstrap-ci-workflows-dry-run"
  setup_scratch_repo "$d"
  cd "$d"
  local stub="$d/_curl_stub"
  # Pattern order matters (first-match-wins substring). The workflows-list
  # GET (which carries ?per_page) must come before the bare
  # api.github.com/repos/ catch-all.
  _bootstrap_ci_install_curl_mock "$stub" \
    'actions/permissions|{"enabled":true}' \
    'actions/workflows?per_page|{"workflows":[{"path":".github/workflows/ci-dispatch.yml","state":"disabled_manually"}]}' \
    'protection/required_status_checks|{"contexts":[]}' \
    'branches/dev|{"commit":{"sha":"deadbeef"}}' \
    'branches/main|{"commit":{"sha":"feedface"}}' \
    '/topics|{"names":[]}' \
    'api.github.com/repos/|{"merge_commit_title":"MERGE_MESSAGE","merge_commit_message":"PR_TITLE","allow_squash_merge":true,"allow_rebase_merge":true,"allow_merge_commit":true,"delete_branch_on_merge":true}'

  local out
  out=$(env PATH="$stub:$PATH" GH_TOKEN=mock-token \
    bash .io.v4rian.how-git/bin/bootstrap-ci --dry-run 2>&1)

  echo "$out" | grep -q '\[dry-run\] PUT .*/actions/workflows/ci-dispatch.yml/enable' \
    || { echo "dry-run did not print workflow enable PUT line; got:"; echo "$out"; return 1; }
}

test_bootstrap_ci_step_workflows_enabled_check_reports_drift() {
  # --check mode must surface the miss line for a disabled workflow but
  # must NOT call the enable endpoint (read-only).
  #
  # Pool/n55 + pool/n58: mocked workflow basename is ci-dispatch.yml so
  # it matches a file that actually ships in the template (the legacy
  # test.yml was migrated into the ci-dispatch harness).
  local d="$SCRATCH_BASE/22z-bootstrap-ci-workflows-check"
  setup_scratch_repo "$d"
  cd "$d"
  local stub="$d/_curl_stub"
  _bootstrap_ci_install_curl_mock "$stub" \
    'actions/permissions|{"enabled":true}' \
    'actions/workflows?per_page|{"workflows":[{"path":".github/workflows/ci-dispatch.yml","state":"disabled_manually"}]}' \
    'protection/required_status_checks|{"contexts":[]}' \
    'branches/dev|{"commit":{"sha":"deadbeef"}}' \
    'branches/main|{"commit":{"sha":"feedface"}}' \
    '/topics|{"names":[]}' \
    'api.github.com/repos/|{"merge_commit_title":"MERGE_MESSAGE","merge_commit_message":"PR_TITLE","allow_squash_merge":true,"allow_rebase_merge":true,"allow_merge_commit":true,"delete_branch_on_merge":true}'

  local out
  out=$(env PATH="$stub:$PATH" GH_TOKEN=mock-token \
    bash .io.v4rian.how-git/bin/bootstrap-ci --check 2>&1)

  echo "$out" | grep -q 'ci-dispatch.yml.*would enable' \
    || { echo "check mode did not surface workflow disabled drift; got:"; echo "$out"; return 1; }
  if echo "$out" | grep -q '\[dry-run\] PUT .*/actions/workflows'; then
    echo "check mode emitted [dry-run] for workflows step; got:"
    echo "$out"; return 1
  fi
}

test_bootstrap_ci_dry_run_emits_api_calls_for_new_steps() {
  # With curl mocked to return drift everywhere, --dry-run must print the
  # PATCH/PUT bodies for every new step instead of silently no-oping.
  local d="$SCRATCH_BASE/22z-bootstrap-ci-dry-run"
  setup_scratch_repo "$d"
  cd "$d"
  local stub="$d/_curl_stub"
  # Pattern order matters (first-match-wins substring matching): the more
  # specific protection/required_status_checks pattern must come before
  # the bare branches/dev + branches/main patterns.
  _bootstrap_ci_install_curl_mock "$stub" \
    'actions/permissions|{"enabled":true}' \
    'protection/required_status_checks|{"contexts":[]}' \
    'branches/dev|{"commit":{"sha":"deadbeef"}}' \
    'branches/main|{"commit":{"sha":"feedface"}}' \
    '/topics|{"names":[]}' \
    'api.github.com/repos/|{"merge_commit_title":"MERGE_MESSAGE","merge_commit_message":"PR_TITLE","allow_squash_merge":true,"allow_rebase_merge":true,"allow_merge_commit":true,"delete_branch_on_merge":true}'

  local out
  out=$(env PATH="$stub:$PATH" GH_TOKEN=mock-token \
    bash .io.v4rian.how-git/bin/bootstrap-ci --dry-run 2>&1)

  # Every new step must surface a [dry-run] API call body.
  echo "$out" | grep -q '\[dry-run\] PATCH .*/branches/dev/protection/required_status_checks' \
    || { echo "dry-run did not print dev required-checks PATCH; got:"; echo "$out"; return 1; }
  echo "$out" | grep -q 'merge_commit_title.:.PR_TITLE' \
    || { echo "dry-run did not print merge-commit-defaults PATCH body; got:"; echo "$out"; return 1; }
  echo "$out" | grep -q 'allow_squash_merge.:false' \
    || { echo "dry-run did not print merge-mode-lock PATCH body; got:"; echo "$out"; return 1; }
  echo "$out" | grep -q 'delete_branch_on_merge.:false' \
    || { echo "dry-run did not print disable-auto-delete PATCH body; got:"; echo "$out"; return 1; }
  echo "$out" | grep -q '\[dry-run\] PUT .*/topics' \
    || { echo "dry-run did not print topics PUT call; got:"; echo "$out"; return 1; }
  echo "$out" | grep -q '"v4rian"' \
    || { echo "dry-run topics body missing 'v4rian'; got:"; echo "$out"; return 1; }
  echo "$out" | grep -q '"how-git"' \
    || { echo "dry-run topics body missing 'how-git'; got:"; echo "$out"; return 1; }
}

test_bootstrap_ci_check_mode_reports_drift() {
  # --check mode must surface every drift line for the new steps without
  # printing any [dry-run] API call body (since check is read-only).
  local d="$SCRATCH_BASE/22z-bootstrap-ci-check"
  setup_scratch_repo "$d"
  cd "$d"
  local stub="$d/_curl_stub"
  # Pattern order matters (first-match-wins substring matching): the more
  # specific protection/required_status_checks pattern must come before
  # the bare branches/dev + branches/main patterns.
  _bootstrap_ci_install_curl_mock "$stub" \
    'actions/permissions|{"enabled":true}' \
    'protection/required_status_checks|{"contexts":[]}' \
    'branches/dev|{"commit":{"sha":"deadbeef"}}' \
    'branches/main|{"commit":{"sha":"feedface"}}' \
    '/topics|{"names":[]}' \
    'api.github.com/repos/|{"merge_commit_title":"MERGE_MESSAGE","merge_commit_message":"PR_TITLE","allow_squash_merge":true,"allow_rebase_merge":true,"allow_merge_commit":true,"delete_branch_on_merge":true}'

  local out
  out=$(env PATH="$stub:$PATH" GH_TOKEN=mock-token \
    bash .io.v4rian.how-git/bin/bootstrap-ci --check 2>&1)

  # --check MUST NOT print any [dry-run] line.
  if echo "$out" | grep -q '\[dry-run\]'; then
    echo "check mode emitted [dry-run] markers (should be silent on API); got:"
    echo "$out"; return 1
  fi
  # Every new step must surface a 'miss' line describing what it would change.
  # Pool/n55 + pool/n58: required-check context names are prefixed with
  # 'required.' since they are discovered from required.*.sh files under
  # ci/{tests,audits}/push/ (sys-layer entries that delegate to the
  # canonical retry wrappers).
  echo "$out" | grep -q "missing required check 'required.compile'" \
    || { echo "check did not report missing required.compile context; got:"; echo "$out"; return 1; }
  echo "$out" | grep -q "missing required check 'required.coverage'" \
    || { echo "check did not report missing required.coverage context"; return 1; }
  echo "$out" | grep -q "missing required check 'required.runtime'" \
    || { echo "check did not report missing required.runtime context"; return 1; }
  echo "$out" | grep -q "missing required check 'opened-via-correct-flow'" \
    || { echo "check did not report missing opened-via-correct-flow context"; return 1; }
  echo "$out" | grep -q "merge_commit_title.*want PR_TITLE" \
    || { echo "check did not report merge_commit_title drift"; return 1; }
  echo "$out" | grep -q "allow_squash_merge.*want false" \
    || { echo "check did not report allow_squash_merge drift"; return 1; }
  echo "$out" | grep -q "delete_branch_on_merge.*want false" \
    || { echo "check did not report delete_branch_on_merge drift"; return 1; }
  echo "$out" | grep -q "topic 'v4rian'" \
    || { echo "check did not report missing v4rian topic"; return 1; }
}

test_bootstrap_ci_idempotent_when_state_correct() {
  # With curl mocked to return state already matching every wanted value,
  # --dry-run must NOT emit any PATCH/PUT bodies (idempotency). The 'already
  # set' ok lines are still printed.
  #
  # Pattern order matters: the curl mock uses first-match-wins substring
  # matching, so the more specific protection/required_status_checks
  # patterns must come BEFORE the bare branches/dev + branches/main
  # patterns that match the dev/main probe endpoints.
  local d="$SCRATCH_BASE/22z-bootstrap-ci-idempotent"
  setup_scratch_repo "$d"
  cd "$d"
  local stub="$d/_curl_stub"
  _bootstrap_ci_install_curl_mock "$stub" \
    'actions/permissions|{"enabled":true}' \
    'branches/main/protection/required_status_checks|{"contexts":["doc-freshness"]}' \
    'branches/dev/protection/required_status_checks|{"contexts":["required.commit-audit","required.offline-test-suites","required.compile","required.coverage","required.runtime","opened-via-correct-flow"]}' \
    'branches/dev|{"commit":{"sha":"deadbeef"}}' \
    'branches/main|{"commit":{"sha":"feedface"}}' \
    '/topics|{"names":["v4rian","how-git"]}' \
    'api.github.com/repos/|{"merge_commit_title":"PR_TITLE","merge_commit_message":"PR_BODY","allow_squash_merge":false,"allow_rebase_merge":false,"allow_merge_commit":true,"delete_branch_on_merge":false}'

  local out
  out=$(env PATH="$stub:$PATH" GH_TOKEN=mock-token \
    bash .io.v4rian.how-git/bin/bootstrap-ci --dry-run 2>&1)

  # No PATCH or PUT API calls should appear — everything is already correct.
  if echo "$out" | grep -E '\[dry-run\] (PATCH|PUT)' >/dev/null; then
    echo "idempotency check failed: dry-run emitted mutations when state was already correct"
    echo "$out"
    return 1
  fi
  # The 'already' / 'ok' lines for each new step must still appear.
  echo "$out" | grep -q "merge_commit_title=PR_TITLE.*already set" \
    || { echo "no merge-commit-defaults ok line; got:"; echo "$out"; return 1; }
  echo "$out" | grep -q "merge mode already locked" \
    || { echo "no merge-mode-lock ok line"; return 1; }
  echo "$out" | grep -q "delete_branch_on_merge already false" \
    || { echo "no auto-delete ok line"; return 1; }
  echo "$out" | grep -q "topics already include v4rian + how-git" \
    || { echo "no topics ok line"; return 1; }
}

test_bootstrap_ci_help_lists_every_step() {
  # --help must surface every step in order so operators see the full
  # surface before running. The header range expands as new steps land.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/bootstrap-ci"
  local out; out=$(bash "$f" --help 2>&1) || true
  local label
  for label in \
    "Actions is enabled" \
    "dev branch exists" \
    "branch protection on main" \
    "Repository Rules" \
    "required status checks" \
    "merge-commit defaults" \
    "merge mode to" \
    "auto-delete merged branches" \
    "repo topics" \
    "Report final state"; do
    echo "$out" | grep -q "$label" || { echo "help missing '$label' step"; echo "$out"; return 1; }
  done
}

test_full_lifecycle_simulation() {
  # The big composite: bootstrap → branch → commit → push (simulated) →
  # PR open (simulated) → merge into dev (simulated) → claim runs →
  # dev → main merge (simulated) → claim-main-release runs.
  local d="$SCRATCH_BASE/22-lifecycle"
  setup_scratch_repo "$d"
  cd "$d"

  # STEP 1: heal (sets hooks path, alias, etc.)
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null

  # STEP 2: simulate allocator — create pool/n1.* + safety/n1.* pair at dev HEAD
  git checkout -q -b dev
  git branch pool/n1.feature.parser_rewrite
  git branch safety/n1.feature.parser_rewrite

  # STEP 3: developer work on pool/n1
  git checkout -q pool/n1.feature.parser_rewrite
  echo "# parser" > parser.md
  git -c user.email=dev@test -c user.name=dev add parser.md
  git -c user.email=dev@test -c user.name=dev commit -q --no-verify -m "[NEW] Parser rewrite landing for lifecycle test"

  # STEP 4: simulate PR merge (would be via GitHub UI in real life)
  git checkout -q dev
  local pre_tags; pre_tags=$(git tag -l | wc -l | tr -d ' ')
  git -c user.email=dev@test -c user.name=dev merge --no-ff pool/n1.feature.parser_rewrite \
    -m "[MERGE] pool/n1.feature.parser_rewrite into dev: aspirational"

  # STEP 5: assert post-merge hook ran claim-dev-merge -> new tag, no VERSION
  local mid_tags; mid_tags=$(git tag -l | wc -l | tr -d ' ')
  [ "$mid_tags" -gt "$pre_tags" ] || { echo "no new dev tag after merge"; return 1; }
  local year; year=$(date -u +%Y)
  local expected_dev_tag="v${year}.0.1"
  git tag -l | grep -q "^${expected_dev_tag}$" || { echo "expected dev tag $expected_dev_tag not present (got: $(git tag -l))"; return 1; }

  # STEP 6: dev -> main MUST be --no-ff so the merge commit lands on main's
  # first-parent line; bin/version counts that commit to determine the
  # release number. --ff-only would leave the count broken.
  git checkout -q main
  git -c user.email=dev@test -c user.name=dev merge --no-ff dev \
    -m "[MERGE] dev into main: release"

  # STEP 7: simulate CI by running claim-main-release.sh
  # In the new model, claim-main-release does NOT create a new git tag.
  # The release REUSES the existing dev tag (same code = same version).
  local pre_release_tag_count; pre_release_tag_count=$(git tag -l | wc -l | tr -d ' ')
  bash .io.v4rian.how-git/scripts/claim-main-release.sh --skip-pull --no-release

  # STEP 8: assert NO new git tag was created (release REUSES dev tag).
  local post_release_tag_count; post_release_tag_count=$(git tag -l | wc -l | tr -d ' ')
  [ "$post_release_tag_count" = "$pre_release_tag_count" ] || {
    echo "claim-main-release created a new git tag (must not - release reuses dev tag). Before: $pre_release_tag_count, After: $post_release_tag_count"; return 1; }
  # The release tag IS the dev tag - still present + reachable from main.
  git tag -l | grep -q "^${expected_dev_tag}$" || { echo "expected tag $expected_dev_tag missing after release"; return 1; }
  [ ! -f VERSION ] || { echo "claim-main-release wrote a VERSION file (should never)"; return 1; }

  echo "  ok: lifecycle: pool/n1 -> dev (tag $expected_dev_tag) -> main (release reuses ${expected_dev_tag}); no new git tag, no VERSION file"
}

# ============================================================================
# Off-grid mode coverage (added in pool/n39)
# ============================================================================

test_mode_defaults_to_connected() {
  local d="$SCRATCH_BASE/mode-default"; setup_scratch_repo "$d"
  ( cd "$d"
    # MODE file is in the template + checked in by setup_scratch_repo, so
    # default is "connected".
    local val; val=$(tr -d '\n' < .io.v4rian.how-git/MODE)
    assert_eq "$val" "connected" "default mode value"
  )
}

test_set_mode_off_grid_writes_file() {
  local d="$SCRATCH_BASE/set-mode-off-grid"; setup_scratch_repo "$d"
  ( cd "$d"
    .io.v4rian.how-git/bin/set-mode off-grid >/dev/null
    local val; val=$(tr -d '\n' < .io.v4rian.how-git/MODE)
    assert_eq "$val" "off-grid" "set-mode off-grid value"
  )
}

test_set_mode_back_to_connected_writes_file() {
  local d="$SCRATCH_BASE/set-mode-roundtrip"; setup_scratch_repo "$d"
  ( cd "$d"
    .io.v4rian.how-git/bin/set-mode off-grid >/dev/null
    .io.v4rian.how-git/bin/set-mode connected >/dev/null
    local val; val=$(tr -d '\n' < .io.v4rian.how-git/MODE)
    assert_eq "$val" "connected" "set-mode connected after flip"
  )
}

test_set_mode_invalid_value_rejected() {
  local d="$SCRATCH_BASE/set-mode-invalid"; setup_scratch_repo "$d"
  ( cd "$d"
    if .io.v4rian.how-git/bin/set-mode bogus 2>/dev/null; then
      echo "set-mode bogus must reject; it succeeded"; return 1
    fi
  )
}

test_set_mode_get_reads_current() {
  local d="$SCRATCH_BASE/set-mode-get"; setup_scratch_repo "$d"
  ( cd "$d"
    .io.v4rian.how-git/bin/set-mode off-grid >/dev/null
    local out; out=$(.io.v4rian.how-git/bin/set-mode --get | tr -d '\n')
    assert_eq "$out" "off-grid" "set-mode --get output"
  )
}

test_doctor_reports_mode_value() {
  local d="$SCRATCH_BASE/doctor-mode"; setup_scratch_repo "$d"
  ( cd "$d"
    # Doctor should run cleanly with MODE present; tamper to an invalid value
    # and confirm doctor surfaces the issue.
    printf 'bogus' > .io.v4rian.how-git/MODE
    local out; out=$(.io.v4rian.how-git/bin/doctor 2>&1 || true)
    echo "$out" | grep -q "MODE" || { echo "doctor did not surface MODE issue: $out"; return 1; }
  )
}

test_status_includes_mode_in_human_and_json() {
  local d="$SCRATCH_BASE/status-mode"; setup_scratch_repo "$d"
  ( cd "$d"
    local human; human=$(.io.v4rian.how-git/bin/status 2>/dev/null)
    echo "$human" | grep -q "mode:" || { echo "status human output missing mode: $human"; return 1; }
    local json; json=$(.io.v4rian.how-git/bin/status --json 2>/dev/null)
    echo "$json" | grep -q '"mode":' || { echo "status json missing mode key: $json"; return 1; }
  )
}

test_finalize_pool_merge_refuses_in_connected_mode() {
  local d="$SCRATCH_BASE/finalize-connected"; setup_scratch_repo "$d"
  ( cd "$d"
    if .io.v4rian.how-git/bin/finalize-pool-merge 2>/dev/null; then
      echo "finalize-pool-merge must refuse in connected mode; it succeeded"; return 1
    fi
    local out; out=$(.io.v4rian.how-git/bin/finalize-pool-merge 2>&1 || true)
    echo "$out" | grep -q "off-grid is required" || { echo "missing off-grid refusal message: $out"; return 1; }
  )
}

test_ship_refuses_in_connected_mode() {
  local d="$SCRATCH_BASE/ship-connected"; setup_scratch_repo "$d"
  ( cd "$d"
    if .io.v4rian.how-git/bin/ship 2>/dev/null; then
      echo "ship must refuse in connected mode; it succeeded"; return 1
    fi
    local out; out=$(.io.v4rian.how-git/bin/ship 2>&1 || true)
    echo "$out" | grep -q "off-grid is required" || { echo "missing off-grid refusal message: $out"; return 1; }
  )
}

test_init_pool_merge_refuses_in_off_grid() {
  local d="$SCRATCH_BASE/init-pool-off-grid"; setup_scratch_repo "$d"
  ( cd "$d"
    .io.v4rian.how-git/bin/set-mode off-grid >/dev/null
    if .io.v4rian.how-git/bin/init-pool-merge --dry-run 2>/dev/null; then
      echo "init-pool-merge must refuse in off-grid; it succeeded"; return 1
    fi
    local out; out=$(.io.v4rian.how-git/bin/init-pool-merge --dry-run 2>&1 || true)
    echo "$out" | grep -q "off-grid" || { echo "missing off-grid refusal message: $out"; return 1; }
  )
}

test_init_release_refuses_in_off_grid() {
  local d="$SCRATCH_BASE/init-release-off-grid"; setup_scratch_repo "$d"
  ( cd "$d"
    .io.v4rian.how-git/bin/set-mode off-grid >/dev/null
    if .io.v4rian.how-git/bin/init-release --dry-run 2>/dev/null; then
      echo "init-release must refuse in off-grid; it succeeded"; return 1
    fi
    local out; out=$(.io.v4rian.how-git/bin/init-release --dry-run 2>&1 || true)
    echo "$out" | grep -q "off-grid" || { echo "missing off-grid refusal message: $out"; return 1; }
  )
}

test_apply_repo_rules_refuses_in_off_grid() {
  local d="$SCRATCH_BASE/apply-rules-off-grid"; setup_scratch_repo "$d"
  ( cd "$d"
    .io.v4rian.how-git/bin/set-mode off-grid >/dev/null
    if bash .io.v4rian.how-git/scripts/apply-repo-rules.sh 2>/dev/null; then
      echo "apply-repo-rules must refuse in off-grid; it succeeded"; return 1
    fi
    local out; out=$(bash .io.v4rian.how-git/scripts/apply-repo-rules.sh 2>&1 || true)
    echo "$out" | grep -q "off-grid" || { echo "missing off-grid refusal message: $out"; return 1; }
  )
}

test_bootstrap_ci_refuses_in_off_grid() {
  local d="$SCRATCH_BASE/bootstrap-ci-off-grid"; setup_scratch_repo "$d"
  ( cd "$d"
    .io.v4rian.how-git/bin/set-mode off-grid >/dev/null
    if .io.v4rian.how-git/bin/bootstrap-ci --check 2>/dev/null; then
      echo "bootstrap-ci must refuse in off-grid; it succeeded"; return 1
    fi
    local out; out=$(.io.v4rian.how-git/bin/bootstrap-ci --check 2>&1 || true)
    echo "$out" | grep -q "off-grid" || { echo "missing off-grid refusal message: $out"; return 1; }
  )
}

test_claim_dev_merge_no_ops_when_off_grid_in_ci() {
  local d="$SCRATCH_BASE/claim-dev-off-grid-ci"; setup_scratch_repo "$d"
  ( cd "$d"
    .io.v4rian.how-git/bin/set-mode off-grid >/dev/null
    # Simulate the CI environment: get the no-op exit path, not the mutation.
    local out
    out=$(CI=true LIFECYCLE_TEST_MODE= bash .io.v4rian.how-git/scripts/claim-dev-merge.sh 2>&1) || {
      echo "claim-dev-merge must exit 0 when off-grid+CI; got non-zero: $out"; return 1; }
    echo "$out" | grep -q "no-op" || { echo "expected 'no-op' message; got: $out"; return 1; }
  )
}

test_claim_main_release_no_ops_when_off_grid_in_ci() {
  local d="$SCRATCH_BASE/claim-main-off-grid-ci"; setup_scratch_repo "$d"
  ( cd "$d"
    .io.v4rian.how-git/bin/set-mode off-grid >/dev/null
    local out
    out=$(CI=true LIFECYCLE_TEST_MODE= bash .io.v4rian.how-git/scripts/claim-main-release.sh 2>&1) || {
      echo "claim-main-release must exit 0 when off-grid+CI; got non-zero: $out"; return 1; }
    echo "$out" | grep -q "no-op" || { echo "expected 'no-op' message; got: $out"; return 1; }
  )
}

test_mode_flip_round_trip_full_cycle() {
  local d="$SCRATCH_BASE/mode-flip-cycle"; setup_scratch_repo "$d"
  ( cd "$d"
    # connected -> off-grid -> connected, verifying side-effect surface at each step.
    local m
    m=$(tr -d '\n' < .io.v4rian.how-git/MODE)
    assert_eq "$m" "connected" "initial mode" || return 1

    .io.v4rian.how-git/bin/set-mode off-grid >/dev/null
    m=$(tr -d '\n' < .io.v4rian.how-git/MODE)
    assert_eq "$m" "off-grid" "after first flip" || return 1
    # bin/ship now ACCEPTS in off-grid (gets past the mode gate). It still
    # fails on dev missing or unrelated checks; we only care the off-grid
    # gate is silent now.
    local out
    out=$(.io.v4rian.how-git/bin/ship --dry-run 2>&1 || true)
    if printf '%s' "$out" | grep -q "off-grid is required"; then
      echo "ship still refuses after off-grid flip: $out"
      return 1
    fi

    .io.v4rian.how-git/bin/set-mode connected >/dev/null
    m=$(tr -d '\n' < .io.v4rian.how-git/MODE)
    assert_eq "$m" "connected" "after second flip" || return 1
    # bin/init-pool-merge now accepts in connected (gets past the mode gate).
    out=$(.io.v4rian.how-git/bin/init-pool-merge --dry-run 2>&1 || true)
    if printf '%s' "$out" | grep -q "PRs are not the close-up path"; then
      echo "init-pool-merge still refuses after connected flip: $out"
      return 1
    fi
  )
}

# ----------------------------------------------------------------------------
# smart-commit (pool/n51): sub-claude composes commit messages per the
# in-repo audit skills with subprocess isolation so the caller's context
# stays light.
# ----------------------------------------------------------------------------

test_smart_commit_bin_present_executable_and_help() {
  # Presence + executable + --help responds with a non-empty docstring
  # mentioning the sub-claude isolation idea and the LIFECYCLE_TEST_MODE env.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/smart-commit"
  assert_file_exists "$f" "smart-commit binary" || return 1
  assert_executable "$f" "smart-commit executable" || return 1
  local out rc
  out=$(bash "$f" --help 2>&1); rc=$?
  assert_eq "$rc" "0" "--help exits 0" || { echo "$out"; return 1; }
  echo "$out" | grep -q "smart-commit" || { echo "help missing tool name"; return 1; }
  echo "$out" | grep -q "sub-claude" || { echo "help missing sub-claude isolation language"; return 1; }
  echo "$out" | grep -q "LIFECYCLE_TEST_MODE" || { echo "help missing LIFECYCLE_TEST_MODE doc"; return 1; }
}

test_smart_commit_auto_stages_when_index_is_empty() {
  # When nothing is staged but unstaged/untracked changes exist,
  # smart-commit auto-stages ALL of them (no `git add .`) and proceeds.
  local d="$SCRATCH_BASE/smart-commit-auto-stage"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  echo "fresh content for smart-commit auto-stage" > probe-file.txt
  # Nothing staged on entry.
  [ -z "$(git diff --cached --name-only)" ] || { echo "index unexpectedly non-empty before smart-commit"; return 1; }
  local pre_head; pre_head=$(git rev-parse HEAD)
  local out
  out=$(LIFECYCLE_TEST_MODE=1 bash .io.v4rian.how-git/bin/smart-commit -y 2>&1)
  local rc=$?
  assert_eq "$rc" "0" "smart-commit exits 0 on auto-stage path" || { echo "$out"; return 1; }
  # Auto-stage banner must be in the output.
  echo "$out" | grep -q "no staged scope" || { echo "auto-stage banner missing; got: $out"; return 1; }
  # A new commit landed.
  local post_head; post_head=$(git rev-parse HEAD)
  assert_ne "$pre_head" "$post_head" "HEAD advanced after smart-commit" || return 1
  # The newly committed tree contains probe-file.txt.
  git show --name-only --format= HEAD | grep -q "probe-file.txt" || {
    echo "probe-file.txt missing from new commit"; return 1; }
}

test_smart_commit_lifecycle_test_mode_produces_canned_commit() {
  # With LIFECYCLE_TEST_MODE=1 the script must NEVER spawn a real
  # claude subprocess and must produce a well-formed canned message
  # (tag + title <=72 char OR similar shape, blank line, description
  # paragraph) so the downstream commit-msg length guardrail accepts it.
  local d="$SCRATCH_BASE/smart-commit-test-mode"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  # Pre-create a tracked file so we can exercise the modified-tracked path.
  echo "first" > track-me.txt
  git -c user.email=t@t -c user.name=t add track-me.txt
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[REFACTOR] Seed tracked file for smart-commit test"
  # Now modify it AND add an untracked file.
  echo "second" >> track-me.txt
  echo "brand new" > new-untracked.txt
  # Sabotage PATH so a real `claude` binary, if installed on the test
  # box, cannot be called. The test must rely on LIFECYCLE_TEST_MODE=1
  # to short-circuit before any network call.
  local out
  out=$(LIFECYCLE_TEST_MODE=1 PATH="/usr/bin:/bin" bash .io.v4rian.how-git/bin/smart-commit -y 2>&1)
  local rc=$?
  assert_eq "$rc" "0" "test-mode commit exits 0" || { echo "$out"; return 1; }
  # The canned-message banner must fire and the real claude must not have been called.
  echo "$out" | grep -q "test-mode" || { echo "test-mode banner missing; got: $out"; return 1; }
  echo "$out" | grep -q "no claude call" || { echo "no-claude-call banner missing; got: $out"; return 1; }
  # The composed message lands as a real commit with both files in tree.
  git show --name-only --format= HEAD | grep -q "track-me.txt" || {
    echo "modified file missing from canned commit"; return 1; }
  git show --name-only --format= HEAD | grep -q "new-untracked.txt" || {
    echo "untracked file missing from canned commit"; return 1; }
  # Title carries one of the approved tag prefixes per git-commit-audit.
  local title; title=$(git log -1 --format=%s HEAD)
  echo "$title" | grep -qE '^\[(FIX|NEW|REFACTOR|DOCS|TEST|REVERT|HOTFIX|MERGE)\] ' || {
    echo "canned commit title '$title' lacks approved tag"; return 1; }
}

test_smart_commit_skips_active_requirement_when_absent() {
  # The optional `.io.v4rian.how-git/active-requirement` file may be
  # added by a separate tool (agent-33's stream). smart-commit must
  # PROBE for it and gracefully skip when absent. The script proves this
  # by referencing the path only inside an `[ -f "$ACTIVE_REQ" ]` guard.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/smart-commit"
  # Static grep: the guard pattern must wrap any reference that injects
  # the file into the prompt.
  assert_grep 'if \[ -f "$ACTIVE_REQ" \]' "$f" "active-requirement is guarded" || return 1
  # Behavioral: run smart-commit with no active-requirement file and
  # verify no error / no banner that references it.
  local d="$SCRATCH_BASE/smart-commit-no-active-req"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  [ ! -e .io.v4rian.how-git/active-requirement ] || rm .io.v4rian.how-git/active-requirement
  echo "probe" > probe-no-req.txt
  local out
  out=$(LIFECYCLE_TEST_MODE=1 bash .io.v4rian.how-git/bin/smart-commit -y 2>&1)
  local rc=$?
  assert_eq "$rc" "0" "smart-commit ok without active-requirement" || { echo "$out"; return 1; }
}

test_smart_commit_dry_run_does_not_commit() {
  # --dry-run composes the message and prints it but never advances HEAD.
  local d="$SCRATCH_BASE/smart-commit-dry-run"
  setup_scratch_repo "$d"
  cd "$d"
  bash .io.v4rian.how-git/scripts/heal.sh >/dev/null
  echo "preview only" > preview.txt
  local pre_head; pre_head=$(git rev-parse HEAD)
  local out
  out=$(LIFECYCLE_TEST_MODE=1 bash .io.v4rian.how-git/bin/smart-commit --dry-run 2>&1)
  local rc=$?
  assert_eq "$rc" "0" "dry-run exits 0" || { echo "$out"; return 1; }
  echo "$out" | grep -q "not committing" || { echo "dry-run banner missing; got: $out"; return 1; }
  local post_head; post_head=$(git rev-parse HEAD)
  assert_eq "$pre_head" "$post_head" "HEAD did not advance under --dry-run" || return 1
}

# ----------------------------------------------------------------------------
# Off-grid e2e CLI (pool/n51): operator-run tool that creates a throwaway
# repo via the GitHub API + exercises the full off-grid lifecycle against it.
# These tests cover the STRUCTURE only -- the real API path is never reached
# from the offline lifecycle suite (the script costs real repo creation and
# deletion per invocation). The tests verify the bin + script ship, the
# --help shape, the refusal path when token or account is missing, and that
# --dry-run prints the planned API calls without executing them.
# ----------------------------------------------------------------------------

test_off_grid_e2e_cli_present_and_executable() {
  local bin="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/test-off-grid-e2e"
  local sh="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/test-off-grid-e2e.sh"
  assert_file_exists "$bin" "test-off-grid-e2e CLI" || return 1
  assert_executable "$bin" "test-off-grid-e2e CLI executable" || return 1
  assert_file_exists "$sh" "test-off-grid-e2e canonical script" || return 1
  assert_executable "$sh" "test-off-grid-e2e canonical script executable" || return 1
  # Bin must be a thin shim that dispatches to the canonical script.
  assert_grep "scripts/test-off-grid-e2e.sh" "$bin" "bin dispatches to canonical script" || return 1
  # --help on the CLI must surface the operator-run framing + required-flag posture.
  local out
  out=$(bash "$bin" --help 2>&1)
  echo "$out" | grep -q "operator-run end-to-end" || { echo "--help missing operator-run header; got: $out"; return 1; }
  echo "$out" | grep -q -- "--token TOKEN" || { echo "--help missing --token flag doc; got: $out"; return 1; }
  echo "$out" | grep -q -- "--account OWNER" || { echo "--help missing --account flag doc; got: $out"; return 1; }
  echo "$out" | grep -q -- "--dry-run" || { echo "--help missing --dry-run flag doc; got: $out"; return 1; }
}

test_off_grid_e2e_refuses_without_explicit_token_and_account() {
  # Refusal must happen even when ambient credentials COULD be discovered.
  # We run with env -i and a HOME pointing at a directory with no GCM store,
  # so the token chain is forced to fall through to the refusal branch.
  local bin="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/test-off-grid-e2e"
  local empty_home; empty_home=$(mktemp -d -t "off-grid-empty-home-XXXXXX")
  trap "rm -rf '$empty_home'" RETURN

  # 1. No token, no account -> exits 4 with --token TOKEN error.
  local out rc
  out=$(env -i HOME="$empty_home" PATH="/usr/bin:/bin:/usr/local/bin" bash "$bin" 2>&1); rc=$?
  assert_eq "$rc" "4" "exits 4 when token missing" || { echo "$out"; return 1; }
  echo "$out" | grep -q "token TOKEN is required" || { echo "expected --token refusal; got: $out"; return 1; }
  echo "$out" | grep -q "no implicit default" || { echo "expected 'no implicit default' rationale; got: $out"; return 1; }

  # 2. Token via --token but no account -> still exits 4, this time on --account.
  out=$(env -i HOME="$empty_home" PATH="/usr/bin:/bin:/usr/local/bin" bash "$bin" --token FAKE 2>&1); rc=$?
  assert_eq "$rc" "4" "exits 4 when account missing" || { echo "$out"; return 1; }
  echo "$out" | grep -q "account OWNER is required" || { echo "expected --account refusal; got: $out"; return 1; }
  echo "$out" | grep -q "no implicit default" || { echo "expected 'no implicit default' rationale; got: $out"; return 1; }
}

test_off_grid_e2e_dry_run_prints_planned_api_calls_without_executing() {
  # --dry-run must print the full plan AND never touch the network. We run
  # under env -i with an unreachable HOME so even if curl somehow leaked
  # through, no ambient credential could be used. We verify the planned
  # /generate POST, the planned mode-flip, the planned allocator
  # invocation (the off-grid CLI dispatches the same canonical script that
  # connected mode runs in a workflow), the planned ship invocation, and
  # the planned DELETE all appear in the output in order. The redundant
  # finalize-pool-merge invocation was removed in favour of trusting the
  # post-merge hook to claim the dev tip, so this assertion list no
  # longer expects it.
  local bin="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/test-off-grid-e2e"
  local empty_home; empty_home=$(mktemp -d -t "off-grid-dry-home-XXXXXX")
  trap "rm -rf '$empty_home'" RETURN

  local out rc
  out=$(env -i HOME="$empty_home" PATH="/usr/bin:/bin:/usr/local/bin" \
    bash "$bin" --dry-run --token FAKE --account fakeacct 2>&1); rc=$?
  assert_eq "$rc" "0" "dry-run exits 0" || { echo "$out"; return 1; }

  # pool/n72: expected template derives from this repo's origin URL so the
  # assertion stays correct after an origin swap (no hardcoded owner/repo).
  local expected_template
  expected_template=$(cd "$TEMPLATE_ROOT" && git config --get remote.origin.url 2>/dev/null \
    | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||')
  [ -n "$expected_template" ] \
    || { echo "test setup: cannot derive expected template from origin URL"; return 1; }

  # Plan banner
  echo "$out" | grep -q "off-grid e2e plan against template=$expected_template" \
    || { echo "missing plan banner with template=$expected_template; got: $out"; return 1; }

  # Planned API calls + planned ceremonies, in the order the real run would do them.
  local lines=(
    "POST https://api.github.com/repos/$expected_template/generate"
    "git clone https://fakeacct:"
    "bash .io.v4rian.how-git/scripts/heal.sh"
    "bin/set-mode off-grid"
    "bin/create-pool-branch offgrid-probe --no-jira --kind feature"
    "git merge --no-ff <allocated pool ref>"
    "post-merge hook auto-runs claim-dev-merge.sh"
    "bash .io.v4rian.how-git/bin/ship"
    "DELETE https://api.github.com/repos/fakeacct/"
    "plan complete; no mutation performed"
  )
  for ln in "${lines[@]}"; do
    if ! echo "$out" | grep -qF "$ln"; then
      echo "dry-run plan missing expected line: '$ln'"
      echo "full output:"
      echo "$out"
      return 1
    fi
  done

  # Negative: the redundant finalize-pool-merge invocation must NOT
  # appear in the new plan. The post-merge hook is the off-grid
  # equivalent of connected mode's claim-on-merge-dev workflow; calling
  # finalize-pool-merge again would double-claim the dev tip and the
  # second invocation would fail with "tag already exists locally".
  if echo "$out" | grep -qF "bin/finalize-pool-merge"; then
    echo "dry-run plan still contains the redundant finalize-pool-merge invocation"
    echo "full output:"
    echo "$out"
    return 1
  fi
}

test_off_grid_e2e_trusts_post_merge_hook_for_pool_to_dev_claim() {
  # Static content invariant. The live e2e script (not just the dry-run
  # plan) must NOT invoke bin/finalize-pool-merge after merging the pool
  # branch into dev. The post-merge hook fires automatically on the
  # local git merge and runs claim-dev-merge.sh against the new dev tip;
  # an explicit finalize-pool-merge call after that point would
  # double-claim the dev tip and crash the e2e with "tag already exists
  # locally". The script comment in the post-merge verification step
  # must surface the hook-is-canonical framing so future edits do not
  # silently re-add the redundant call.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/test-off-grid-e2e.sh"
  # No live invocation of finalize-pool-merge. Lines that mention it in
  # explanatory comments are allowed; only `bash .io...bin/finalize-pool-merge`
  # style invocations are banned.
  if grep -nE '^[[:space:]]*bash[[:space:]]+.*bin/finalize-pool-merge' "$f"; then
    echo "test-off-grid-e2e still invokes bin/finalize-pool-merge; the post-merge hook should be the only claim path"
    return 1
  fi
  # Positive: the post-merge hook framing is documented in step 7.
  grep -q "post-merge hook" "$f" \
    || { echo "step 7 comment must surface the post-merge hook as the canonical off-grid claim path"; return 1; }
  grep -q "claim-dev-merge" "$f" \
    || { echo "step 7 comment must name claim-dev-merge.sh so future edits trace the dispatch"; return 1; }
}

test_off_grid_e2e_uses_canonical_allocator_cli() {
  # Static content invariant. The pool branch must be allocated via
  # bin/create-pool-branch (the canonical CLI) so the off-grid e2e
  # exercises the SAME entry point a connected mode operator uses. A
  # bare git checkout -b on the pool ref is the prior shortcut and is
  # banned because it skips the paired safety anchor and pins the nN
  # counter to a hand-picked value instead of letting the allocator
  # assign one.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/test-off-grid-e2e.sh"
  grep -q "bin/create-pool-branch" "$f" \
    || { echo "step 5 must invoke bin/create-pool-branch (the canonical allocator CLI)"; return 1; }
  grep -q -- "--no-jira" "$f" \
    || { echo "step 5 must pass --no-jira (the off-grid escape hatch for callers without JIRA Automation)"; return 1; }
  # Negative: bare git checkout -b on a pool ref is gone.
  if grep -nE 'git checkout -q -b "pool/' "$f"; then
    echo "test-off-grid-e2e still cuts the pool ref with bare git checkout -b; the canonical allocator CLI should own ref creation"
    return 1
  fi
}

# ============================================================================
# Test functions added in pool/n59 (doc-freshness gate):
test_doc_freshness_workflow_present_and_triggers_only_on_main_base() {
  # The workflow YAML must exist, fire on PRs into main (not dev), wire
  # up the env vars the script needs, and dispatch to the canonical
  # script under scripts/workflows/.
  local f="$TEMPLATE_ROOT/.github/workflows/doc-freshness.yml"
  assert_file_exists "$f" "doc-freshness workflow" || return 1
  assert_grep "pull_request" "$f" "pull_request trigger" || return 1
  assert_grep "opened" "$f" "opened type" || return 1
  assert_grep "synchronize" "$f" "synchronize type" || return 1
  assert_grep "reopened" "$f" "reopened type" || return 1
  # Branch filter: ONLY main; pool/n51's whole point is "fires on
  # PR-to-main only", so a dev or pool entry under branches: is a bug.
  assert_grep "- main" "$f" "main branch filter" || return 1
  if grep -E "^\s+-\s+dev\s*$" "$f"; then
    echo "doc-freshness workflow lists dev under branches: (should be main-only)"
    return 1
  fi
  # Required scopes for status posting.
  assert_grep "statuses: write" "$f" "statuses scope" || return 1
  # Dispatches the canonical script.
  assert_grep "bash .io.v4rian.how-git/scripts/workflows/doc-freshness-check.sh" "$f" "dispatches to doc-freshness-check.sh" || return 1
  # Forwards the PR metadata the script needs.
  for var in PR_NUMBER PR_HEAD_REF PR_BASE_REF PR_HEAD_SHA PR_ACTOR; do
    assert_grep "$var:" "$f" "$var env wired" || return 1
  done
}

test_doc_freshness_script_test_mode_detects_stale_changelog() {
  # Behavioral: in a scratch repo with the dev tip ahead of main by a
  # synthetic [MERGE] commit AND a CHANGELOG whose `## Unreleased`
  # section is empty, the doc-freshness script must surface STALE +
  # name the CHANGELOG as the offender.
  local d="$SCRATCH_BASE/n51-doc-freshness-stale"
  setup_scratch_repo "$d"
  cd "$d"
  # Seed dev with a merge that simulates a feature landing.
  git checkout -q -b dev
  # Empty out the Unreleased section to fake staleness.
  if [ -f .io.v4rian.how-git/docs/CHANGELOG.md ]; then
    awk '
      /^## Unreleased/ { print; print ""; in_section=1; next }
      /^## / && in_section { in_section=0 }
      !in_section { print }
    ' .io.v4rian.how-git/docs/CHANGELOG.md > /tmp/cl.new
    mv /tmp/cl.new .io.v4rian.how-git/docs/CHANGELOG.md
  fi
  # Synthetic feature merge commit on dev (no actual feature work
  # needed — the title shape is what the script's substance extractor
  # reads).
  echo "probe" > probe.txt
  git -c user.email=t@t -c user.name=t add probe.txt .io.v4rian.how-git/docs/CHANGELOG.md
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[MERGE] pool/n9.feature.probe into dev: v2026.0.99"
  git push -q origin dev
  # Run the script with the dev → main PR env shape under test mode.
  local out rc
  out=$(env LIFECYCLE_TEST_MODE=1 \
    PR_NUMBER=999 PR_HEAD_REF=dev PR_BASE_REF=main \
    PR_HEAD_SHA=deadbeef PR_ACTOR=tester \
    GH_TOKEN=fake GITHUB_REPOSITORY=t/r GITHUB_RUN_ID=1 \
    DOC_FRESHNESS_CHANGELOG_MIN=80 \
    bash .io.v4rian.how-git/scripts/workflows/doc-freshness-check.sh 2>&1)
  rc=$?
  # Under LIFECYCLE_TEST_MODE the script exits 0 even on STALE so the
  # test harness can read the report shape.
  assert_eq "$rc" "0" "exits 0 under test mode" || { echo "got: $out"; return 1; }
  echo "$out" | grep -q "FRESHNESS=STALE" \
    || { echo "expected FRESHNESS=STALE; got: $out"; return 1; }
  echo "$out" | grep -q "STALE_DOC=.io.v4rian.how-git/docs/CHANGELOG.md" \
    || { echo "expected CHANGELOG named as STALE_DOC; got: $out"; return 1; }
  echo "$out" | grep -q "MISSING_SUBSTANCE=unreleased-section-too-short" \
    || { echo "expected unreleased-section-too-short axis; got: $out"; return 1; }
}

test_doc_freshness_script_canned_claude_response_under_test_mode() {
  # Behavioral: with DOC_FRESHNESS_AUTOFIX=1 and the same stale state
  # from the prior test, the script must invoke the claude worker stub
  # and emit the canned response sentinel AUTOFIX_STUB=ok — proof that
  # LIFECYCLE_TEST_MODE bypasses the real claude call.
  local d="$SCRATCH_BASE/n51-doc-freshness-autofix"
  setup_scratch_repo "$d"
  cd "$d"
  git checkout -q -b dev
  if [ -f .io.v4rian.how-git/docs/CHANGELOG.md ]; then
    awk '
      /^## Unreleased/ { print; print ""; in_section=1; next }
      /^## / && in_section { in_section=0 }
      !in_section { print }
    ' .io.v4rian.how-git/docs/CHANGELOG.md > /tmp/cl.new
    mv /tmp/cl.new .io.v4rian.how-git/docs/CHANGELOG.md
  fi
  echo "p" > p.txt
  git -c user.email=t@t -c user.name=t add p.txt .io.v4rian.how-git/docs/CHANGELOG.md
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[MERGE] pool/n9.feature.probe into dev: v2026.0.99"
  git push -q origin dev
  local out rc
  out=$(env LIFECYCLE_TEST_MODE=1 DOC_FRESHNESS_AUTOFIX=1 \
    PR_NUMBER=999 PR_HEAD_REF=dev PR_BASE_REF=main \
    PR_HEAD_SHA=deadbeef PR_ACTOR=tester \
    GH_TOKEN=fake GITHUB_REPOSITORY=t/r GITHUB_RUN_ID=1 \
    bash .io.v4rian.how-git/scripts/workflows/doc-freshness-check.sh 2>&1)
  rc=$?
  assert_eq "$rc" "0" "exits 0 under test mode" || { echo "got: $out"; return 1; }
  echo "$out" | grep -q "claude-worker-stub: LIFECYCLE_TEST_MODE=1" \
    || { echo "expected canned-response banner; got: $out"; return 1; }
  echo "$out" | grep -q "AUTOFIX_STUB=ok" \
    || { echo "expected AUTOFIX_STUB=ok sentinel; got: $out"; return 1; }
  echo "$out" | grep -q "FAKE_CLAUDE_RESPONSE" \
    || { echo "expected canned-response payload marker; got: $out"; return 1; }
}

test_doc_freshness_script_passes_when_changelog_covers_diff() {
  # Behavioral: when the CHANGELOG's `## Unreleased` section is large
  # enough to cover the diff substance, the script must surface
  # FRESHNESS=PASS and exit 0.
  local d="$SCRATCH_BASE/n51-doc-freshness-pass"
  setup_scratch_repo "$d"
  cd "$d"
  git checkout -q -b dev
  # CHANGELOG already has a substantial Unreleased section (the
  # template's shipped one), so a single feature merge should pass.
  echo "p" > p.txt
  git -c user.email=t@t -c user.name=t add p.txt
  git -c user.email=t@t -c user.name=t commit -q --no-verify -m "[MERGE] pool/n9.feature.probe into dev: v2026.0.99"
  git push -q origin dev
  local out rc
  out=$(env LIFECYCLE_TEST_MODE=1 \
    PR_NUMBER=999 PR_HEAD_REF=dev PR_BASE_REF=main \
    PR_HEAD_SHA=deadbeef PR_ACTOR=tester \
    GH_TOKEN=fake GITHUB_REPOSITORY=t/r GITHUB_RUN_ID=1 \
    bash .io.v4rian.how-git/scripts/workflows/doc-freshness-check.sh 2>&1)
  rc=$?
  assert_eq "$rc" "0" "exits 0 on PASS" || { echo "got: $out"; return 1; }
  echo "$out" | grep -q "FRESHNESS=PASS" \
    || { echo "expected FRESHNESS=PASS; got: $out"; return 1; }
}

test_doc_freshness_script_out_of_scope_when_base_is_dev() {
  # Behavioral: when PR_BASE_REF is `dev` (pool → dev PR), the script
  # exits 0 with an out-of-scope banner and does NOT run the
  # substance extraction. doc-freshness only gates dev → main PRs.
  local d="$SCRATCH_BASE/n51-doc-freshness-scope"
  setup_scratch_repo "$d"
  cd "$d"
  local out rc
  out=$(env LIFECYCLE_TEST_MODE=1 \
    PR_NUMBER=999 PR_HEAD_REF=pool/n9.feature.probe PR_BASE_REF=dev \
    PR_HEAD_SHA=deadbeef PR_ACTOR=tester \
    GH_TOKEN=fake GITHUB_REPOSITORY=t/r GITHUB_RUN_ID=1 \
    bash .io.v4rian.how-git/scripts/workflows/doc-freshness-check.sh 2>&1)
  rc=$?
  assert_eq "$rc" "0" "exits 0 on out-of-scope base" || { echo "got: $out"; return 1; }
  echo "$out" | grep -q "out of scope" \
    || { echo "expected out-of-scope banner; got: $out"; return 1; }
  # Substance extraction should NOT have happened.
  if echo "$out" | grep -q "SUBSTANCE_BEGIN"; then
    echo "substance extraction fired despite out-of-scope base; got: $out"
    return 1
  fi
}

test_doc_freshness_script_test_mode_short_circuit() {
  # When LIFECYCLE_TEST_MODE=1 is set and PR_NUMBER is absent, the
  # script must exit cleanly so it can be sourced or invoked without a
  # live gh API. Mirrors validate-pr-open.sh's short-circuit shape.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/workflows/doc-freshness-check.sh"
  local out rc
  out=$(env -i LIFECYCLE_TEST_MODE=1 PATH="$PATH" bash "$f" 2>&1); rc=$?
  assert_eq "$rc" "0" "exits 0 under test mode without PR_NUMBER" || { echo "got: $out"; return 1; }
  echo "$out" | grep -q "test-mode" || { echo "expected test-mode banner; got: $out"; return 1; }
}

test_doc_freshness_script_env_contract_validation() {
  # When NOT in test mode and required env vars are missing, the script
  # must exit 3 with a clear message naming the missing var.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/workflows/doc-freshness-check.sh"
  local out rc
  out=$(env -i PATH="$PATH" PR_NUMBER=1 bash "$f" 2>&1); rc=$?
  assert_eq "$rc" "3" "exits 3 on missing env var" || { echo "got: $out"; return 1; }
  echo "$out" | grep -q "required env var" || { echo "expected env-contract error; got: $out"; return 1; }
}

test_bootstrap_ci_binds_doc_freshness_on_main() {
  # bootstrap-ci's step_required_checks must list doc-freshness in the
  # main_checks array (pool/n51). The dev_checks array must NOT include
  # it (doc-freshness only gates dev → main release PRs).
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/bin/bootstrap-ci"
  grep -E '^\s+local main_checks=\(' "$f" | grep -q "doc-freshness" \
    || { echo "main_checks does not include doc-freshness"; return 1; }
  # The dev_checks line should NOT carry doc-freshness.
  if grep -E '^\s+local dev_checks=\(' "$f" | grep -q "doc-freshness"; then
    echo "dev_checks unexpectedly includes doc-freshness (it gates main only)"
    return 1
  fi
}

test_apply_repo_rules_binds_doc_freshness_on_main() {
  # apply-repo-rules.sh's PUT against main/protection must include
  # doc-freshness in the required_status_checks contexts list, so the
  # branch-protection layer enforces it in lockstep with bootstrap-ci's
  # required-status-check binding.
  local f="$TEMPLATE_ROOT/.io.v4rian.how-git/scripts/apply-repo-rules.sh"
  grep -q "doc-freshness" "$f" \
    || { echo "apply-repo-rules.sh does not reference doc-freshness"; return 1; }
  # Confirm it's wired into the main-branch PUT specifically, not just a
  # comment somewhere.
  awk '
    /branches\/main\/protection/ { in_block=1 }
    in_block && /doc-freshness/ { found=1 }
    /^echo|^# ---/ && in_block && NR > 2 { in_block=0 }
    END { exit found?0:1 }
  ' "$f" || { echo "doc-freshness not bound under main/protection PUT block"; return 1; }
}


# Runner
# ============================================================================

echo "=== v4rian template lifecycle e2e (offline, simulated) ==="
echo "    scratch base: $SCRATCH_BASE"
echo

echo "→ bootstrap + auto-activation"
run_test "fresh clone has no setup artifacts"               test_clone_state_no_setup_artifacts
run_test "auto-activate on first script call"                test_auto_activate_on_first_script_call
run_test "heal restores core.hooksPath after drift"          test_heal_restores_hooks_path_after_drift
run_test "heal does NOT create VERSION (tags-as-seal model)"  test_heal_does_not_create_version_file
run_test "heal restores executable bits"                      test_heal_restores_executable_bits

echo
echo "→ hooks: regex + length + Step 2 commit stage"
run_test "pre-push regex accepts pool/n* branches"            test_pre_push_regex_accepts_pool
run_test "pre-push regex rejects invalid names"               test_pre_push_regex_rejects_invalid
run_test "doc kind wired across every validation surface"     test_doc_kind_wired_across_every_validation_surface
run_test "claim flow carries PR body recap + PR #N reference" test_claim_flow_carries_pr_body_recap_and_pr_reference
run_test "commit-audit push gate wires through audit-retry"    test_commit_audit_push_gate_wires_through_audit_retry
run_test "commit-msg subject-length guardrail"                test_commit_msg_subject_length
run_test "commit-msg is subject-length guardrail only"        test_commit_msg_is_subject_length_guardrail_only
run_test "commit-msg exempts [MERGE]+[REQ] subjects to 140"   test_commit_msg_exempts_merge_and_req_subjects
run_test "pre-push is branch-name regex only"                 test_pre_push_is_branch_regex_only
run_test "prepare-commit-msg runs the auto-fix layer"         test_prepare_commit_msg_runs_auto_fix_layer
run_test "pre-commit scrubs em/en-dashes from staged files"   test_pre_commit_scrubs_dashes_from_staged_files
run_test "auto-fix lib derives tag + scrubs dashes"           test_auto_fix_lib_derives_tag_and_scrubs_dashes
run_test "async CI audit workflow ships compile/coverage/runtime jobs"  test_async_ci_audit_workflow_present
run_test "retry loops capture exit code correctly (pool/n42)"           test_retry_loops_capture_exit_code_correctly
run_test "dev ruleset binds compile/coverage/runtime as required" test_dev_required_status_checks_ruleset_present
run_test "post-checkout wires git-snapshot-preflight skill"   test_post_checkout_invokes_preflight

echo
echo "→ post-merge automator"
run_test "post-merge auto-claims on dev merge"                test_post_merge_auto_claims_on_dev
run_test "post-merge skips chore(version) bumps"              test_post_merge_skips_chore_version
run_test "post-merge skips squash merges"                     test_post_merge_skips_squash
run_test "post-merge no-op on pool/ branches"                 test_post_merge_skips_pool_branches

echo
echo "→ scripts: math, init, dispatch"
run_test "dead bump.sh + init-version.sh removed"             test_dead_scripts_removed
run_test "open-pr.sh --doctor exits cleanly"                  test_open_pr_doctor_mode
run_test "git repo alias dispatches openPR"                   test_git_repo_alias_dispatches_openPR

echo
echo "→ in-repo assets"
run_test "12 git-* skills shipped"                            test_skills_present_in_repo
run_test "n50 consolidated skills present (git-reconcile-intent + how-dev)" test_consolidated_skills_present_in_repo
run_test "n50 consolidated skills are repo-agnostic"          test_consolidated_skills_are_repo_agnostic
run_test "CI workflow claim-on-merge-dev dispatches"          test_ci_workflow_dev_dispatches
run_test "CI workflow claim-on-merge-main dispatches"         test_ci_workflow_main_dispatches
run_test "n55 build-on-tag migrated to sys layer"             test_ci_build_on_tag_migrated_to_sys_layer
run_test "n55 ci-dispatch resolves dev push as pr-merge-dev"  test_ci_dispatch_resolves_dev_push_as_pr_merge_dev
run_test "n55 ci-dispatch skips chore(version) self-push"     test_ci_dispatch_skips_chore_version_self_push
run_test "n55 ci-dispatch has contents:write permission"      test_ci_dispatch_has_contents_write_permission
run_test "n55 usr-layer harness smoke scripts present"        test_ci_harness_has_usr_layer_smoke_scripts
run_test "n55 ci-dispatch --list enumerates sys+usr layers"   test_ci_dispatch_list_enumerates_sys_and_usr_layers_e2e
run_test "claim-dev-merge delegates version math to bin/version" test_claim_dev_merge_delegates_to_version_bin
run_test "claim workflows accept manual workflow_dispatch"     test_claim_workflows_accept_workflow_dispatch
run_test "claim workflows gate manual dispatch on repo admin"  test_claim_workflows_gate_manual_dispatch_on_admin
run_test "claim workflows wrap the script in in-workflow retry" test_claim_workflows_carry_in_workflow_retry
run_test "tag drift step handles empty DUPS under bash -e"    test_tag_drift_step_handles_empty_dups_under_bash_e
run_test "tag drift step self corrects duplicate tags"        test_tag_drift_step_self_corrects_duplicate_tags

echo
echo "→ pair-safety workflow retired (allocator does the pair atomically)"
run_test "pair-safety workflow deleted"                        test_pair_safety_workflow_removed

echo
echo "→ allocator: workflow + script + CLI wrapper + rulesets"
run_test "allocate-pool-branch workflow present + wired"       test_allocate_workflow_present_and_wired
run_test "allocator script present + executable + complete"    test_allocate_script_present_and_executable
run_test "allocator script rejects missing required inputs"    test_allocate_script_rejects_missing_required_inputs
run_test "allocator script --help works"                       test_allocate_script_help_flag_works
run_test "create-pool-branch CLI present + executable"         test_create_pool_branch_cli_present_and_executable
run_test "legacy repo-create-branch binary removed"            test_old_repo_create_branch_binary_removed
run_test "create-pool-branch --dry-run skips dispatch"         test_create_pool_branch_cli_dry_run_no_dispatch
run_test "create-pool-branch rejects invalid inputs"           test_create_pool_branch_cli_rejects_invalid_inputs
run_test "allocator off-grid creates atomic local pair (n70)"  test_allocator_off_grid_creates_local_refs
run_test "allocator off-grid --no-jira omits segment (n70)"    test_allocator_off_grid_no_jira_omits_segment
run_test "create-pool-branch off-grid invokes allocator (n70)" test_create_pool_branch_cli_off_grid_invokes_allocator_locally
run_test "rulesets pin pool/safety creation to allocator"      test_rulesets_present_and_pin_to_allocator_identity

echo
echo "→ active requirement (pool/n51): branch carries its intent for auditors"
run_test "allocator accepts --requirement + --requirement-file"     test_allocator_accepts_requirement_flags
run_test "allocator writes [REQ] commit + tracked file when supplied"  test_allocator_writes_requirement_commit_when_supplied
run_test "allocator workflow forwards requirement input"            test_allocator_workflow_forwards_requirement_input
run_test "create-pool-branch CLI forwards requirement flags"        test_create_pool_branch_cli_forwards_requirement_flags
run_test "get-active-requirement helper present + executable"       test_get_active_requirement_helper_present_and_executable
run_test "get-active-requirement extracts file content from branch" test_get_active_requirement_helper_extracts_file_content_from_branch
run_test "get-active-requirement falls back to [REQ] commit body"   test_get_active_requirement_helper_falls_back_to_commit_body
run_test "get-active-requirement returns empty for legacy branch"   test_get_active_requirement_helper_empty_for_legacy_branch
run_test "get-active-requirement rejects missing branch arg"        test_get_active_requirement_helper_rejects_missing_arg
run_test "auto-rebase L1-L5 ladder includes requirement in prompts" test_auto_rebase_includes_active_requirement_in_claude_prompts
run_test "post-checkout hook includes requirement in claude prompt" test_post_checkout_includes_active_requirement_in_claude_prompt

echo
echo "→ PR open: PULL_REQUEST_TEMPLATE + validate-pr-open + init CLIs"
run_test "PULL_REQUEST_TEMPLATE present + carries macro sections"  test_pull_request_template_present_and_carries_sections
run_test "validate-pr-open workflow present + wired"               test_validate_pr_open_workflow_present_and_wired
run_test "validate-pr-open script present + executable + sourced"  test_validate_pr_open_script_present_and_executable
run_test "validate-pr-open script bash syntax clean"               test_validate_pr_open_script_syntax_clean
run_test "validate-pr-open short-circuits under test mode"         test_validate_pr_open_script_test_mode_short_circuit
run_test "validate-pr-open enforces env contract outside test mode" test_validate_pr_open_script_env_contract_validation
run_test "validate-pr-open signature is well-formed HTML comment"  test_validate_pr_open_signature_format_is_html_comment
run_test "init-pool-merge CLI present + executable + wired"        test_init_pool_merge_cli_present_and_executable
run_test "init-pool-merge --help works"                            test_init_pool_merge_help_flag_works
run_test "init-pool-merge rejects non-pool source branches"        test_init_pool_merge_rejects_non_pool_branch
run_test "init-pool-merge --dry-run on a clean pool branch"        test_init_pool_merge_dry_run_on_clean_pool_branch
run_test "init-release CLI present + executable + wired"           test_init_release_cli_present_and_executable
run_test "init-release --help works"                               test_init_release_help_flag_works
run_test "init-release rejects non-dev source branches"            test_init_release_rejects_non_dev_branch
run_test "init-release --dry-run on a clean dev branch"            test_init_release_dry_run_on_clean_dev_branch

echo
echo "→ auto-rebase pools after dev merge"
run_test "auto-rebase script present + wired into claim-dev-merge"  test_auto_rebase_script_present_and_wired
run_test "auto-rebase short-circuits in LIFECYCLE_TEST_MODE"        test_auto_rebase_short_circuits_in_test_mode
run_test "auto-rebase never force-pushes pool branches (pool/n43)"   test_auto_rebase_never_force_pushes_developer_branches
run_test "auto-rebase never closes or opens PRs (pool/n43)"          test_auto_rebase_never_closes_or_opens_prs
run_test "auto-rebase comments on existing PR in every path (n43)"   test_auto_rebase_comments_on_existing_pr_in_both_paths
run_test "auto-rebase docstring states the no-rewrite principle"     test_auto_rebase_docstring_states_no_rewrite_principle
run_test "auto-rebase pool/* shape regex enforces hyphens"          test_auto_rebase_no_pool_pattern_skip
run_test "version bin present + executable"                   test_version_bin_present_and_executable
run_test "version bin initial state is vYEAR.0.0"             test_version_bin_initial_state_is_year_zero_zero
run_test "version bin counts dev merges from git log"         test_version_bin_counts_dev_merges_from_git_log
run_test "version bin release bumps SERIES and resets DEV (new model)" test_version_bin_release_bumps_series_and_resets_dev
run_test "version bin: full lifecycle 10-event walkthrough"     test_version_bin_full_lifecycle_sequence
run_test "version bin: orphan merge counts in next-dev"         test_version_bin_orphan_merge_counts_in_next_dev
run_test "version bin: initial empty dev returns 0-indexed seal" test_version_bin_initial_empty_dev
run_test "version bin: ignores legacy SERIES file"               test_version_bin_ignores_legacy_series_file
run_test "apply-repo-rules.sh includes vault read-only"       test_apply_repo_rules_includes_vault_readonly
run_test "safety GC uses 3-gate check (vault+release+main)"   test_safety_gc_three_gate_logic
run_test "safety GC archives under major prefix (pool/n48)"   test_safety_gc_archives_under_major_prefix_instead_of_deleting
run_test "safety-lockdown ruleset covers both layouts (n48)"  test_safety_lockdown_ruleset_covers_both_layouts
run_test "pool-creations ruleset covers both layouts (n51)"   test_pool_creations_ruleset_covers_both_layouts
run_test "pre-push regex accepts prefixed layout (n51)"       test_pre_push_regex_accepts_prefixed_layout
run_test "allocator composes prefixed branch when seal resolves (n51)" test_allocator_composes_prefixed_branch_when_seal_resolves
run_test "allocator next_n walks both layouts (n51)"          test_allocator_next_n_walks_both_layouts
run_test "archive-pool-branch accepts prefixed input (n51)"   test_archive_pool_branch_accepts_prefixed_input
run_test "archive-pool-branch prefixed input e2e (n51)"       test_archive_pool_branch_prefixed_input_e2e
run_test "auto-rebase reconcile inherits major prefix (n51)"  test_auto_rebase_reconcile_inherits_major_prefix
run_test "open-pr pool regex accepts prefixed layout (n51)"   test_open_pr_pool_regex_accepts_prefixed_layout
run_test "validate-pr-open accepts prefixed layout (n51)"     test_validate_pr_open_accepts_prefixed_layout
run_test "claim-dev-merge detects prefixed pool in subject (n51)" test_claim_dev_merge_detects_prefixed_pool_in_subject
run_test "auto-rebase regex accepts the reconcile kind"             test_auto_rebase_regex_accepts_reconcile_kind
run_test "auto-rebase short_name_of + n_of helpers"                 test_auto_rebase_short_name_and_n_helpers
run_test "auto-rebase orphan-base detection (dev rewrite scenario)" test_auto_rebase_orphan_base_detection

echo
echo "→ build-on-tag (canonical build script + retry + idempotency)"
run_test "build-on-tag workflow present + wired"              test_build_on_tag_workflow_present_and_wired
run_test "build + distribute scripts present + executable"    test_build_scripts_present_and_executable
run_test "distribute-* scripts carry inline design doc header" test_distribute_scripts_carry_inline_design_doc_header
run_test "build.sh template-self emits summary artifact"      test_build_sh_template_self_emits_summary_artifact
run_test "build.sh Qt/CMake dispatcher demands consumer override" test_build_sh_qt_cmake_dispatcher_demands_override
run_test "build.sh idempotency probe round-trip"              test_build_sh_idempotency_probe_round_trip

echo
echo "→ real-world e2e simulators (M3 + M4 + M5a)"
run_test "M3: consumer scaffold full lifecycle"                test_m3_real_consumer_full_lifecycle_with_gh_mock
run_test "M4: real conflict on shared file; reconcile naming"  test_m4_real_conflict_resolved_by_reconcile
run_test "M5a: year rollover via date-mock"                    test_m5a_year_rollover_via_date_mock

echo
echo "→ gh API simulation (mock for offline e2e of network-bound paths)"
run_test "gh mock: basic pr create/list/close cycle"          test_gh_mock_basic_pr_create_list_close
run_test "gh mock: reconcile flow (open new + close original)" test_gh_mock_reconcile_flow_simulation
run_test "gh mock: release create + asset upload"             test_gh_mock_release_create_and_upload

echo
echo "→ ops bins (status, ship, release-of)"
run_test "ops bins present + executable"                      test_ops_bins_present_and_executable
run_test "status bin reports seal + branch + json"            test_status_bin_reports_seal_and_branch
run_test "release-of reports 'unreleased' for unmerged commit" test_release_of_reports_unreleased_for_unmerged
run_test "ship --dry-run describes the steps"                 test_ship_dry_run_describes_steps

echo
echo "→ doctor (template health verification)"
run_test "new ops bins present + executable"                  test_new_ops_bins_present_and_executable
run_test "bin/lockdown present + executable (pool/n41)"       test_lockdown_bin_present_and_executable
run_test "bin/lockdown --help names rulesets + Pro req"       test_lockdown_help_describes_eligibility
run_test "bin/lockdown refuses without --repo"                test_lockdown_refuses_without_repo_flag
run_test "bin/lockdown refuses without --allocator-app-id"    test_lockdown_refuses_without_allocator_id
run_test "vault-readonly.json ruleset file present"           test_vault_readonly_ruleset_present
run_test "FRAMEWORK_REPO marker present on source (pool/n45)" test_framework_repo_marker_present_on_source
run_test "root README byte-matches shipped template (pool/n49)" test_root_readme_matches_shipped_template_on_source
run_test "offline-test.sh gates on marker (pool/n45)"         test_offline_test_workflow_gates_on_marker
run_test "coverage.sh framework fallback gated on marker"     test_coverage_sh_template_fallback_gated_on_marker
run_test "workflow yamls dispatch to scripts/workflows/"      test_workflow_yamls_are_thin_dispatchers
run_test "all scripts/workflows/*.sh present + executable"    test_workflow_dispatcher_scripts_present
run_test "bootstrap-ci consumer-cleanup step present + wired" test_bootstrap_ci_consumer_cleanup_step_present
run_test "bootstrap-ci consumer-cleanup body covers both modes"  test_bootstrap_ci_consumer_cleanup_handles_both_modes_in_body
run_test "offline-test.sh skips clean on consumer (e2e)"         test_offline_test_workflow_skips_on_consumer_repo_e2e
run_test "offline-test.sh runs suites on framework source (e2e)" test_offline_test_workflow_runs_on_framework_source_e2e
run_test "coverage.sh exits 2 on no-marker consumer (e2e)"       test_coverage_sh_exits_2_on_consumer_with_no_project_markers_e2e
run_test "coverage.sh runs framework-tests with marker (e2e)"    test_coverage_sh_runs_framework_tests_when_marker_present_e2e
run_test "bootstrap-ci cleanup actually removes files (e2e)"     test_bootstrap_ci_consumer_cleanup_actually_removes_framework_tests_e2e
run_test "archive-pool-branch builds vault/<major>/<suffix> path (pool/n44)"  test_archive_pool_branch_builds_prefixed_vault_path
run_test "archive-pool-branch legacy-match guard (pool/n44)"  test_archive_pool_branch_legacy_match_guard
run_test "archive-pool-branch prefixed vault path e2e (pool/n44)"  test_archive_pool_branch_prefixed_path_e2e
run_test "claim-main-release GC resolves both vault layouts (pool/n44)"  test_claim_main_release_gc_resolves_both_vault_layouts
run_test "apply-repo-rules surfaces Pro req (no silent mask)" test_apply_repo_rules_surfaces_pro_required_no_silent_mask
run_test "doctor reports OK on fresh healthy repo"            test_doctor_clean_repo_reports_ok
run_test "doctor --deep flag documented in --help (pool/n47)" test_doctor_deep_flag_present_in_help
run_test "doctor --deep runs framework-tests (e2e, pool/n47)" test_doctor_deep_runs_framework_tests_e2e
run_test "doctor default mode skips framework-tests (e2e)"    test_doctor_default_mode_does_not_run_framework_tests_e2e
run_test "bootstrap-ci cleanup keeps framework-tests/ (n47)"  test_bootstrap_ci_cleanup_keeps_framework_tests_on_consumer
run_test "doctor detects stray VERSION file"                  test_doctor_detects_stray_version_file
run_test "doctor detects missing bin"                         test_doctor_detects_missing_bin

echo
echo "→ queue (open PR overview with conflict prediction)"
run_test "queue with no open PRs reports none"                test_queue_no_open_prs_reports_none
run_test "queue --json predicts conflicts between PRs"        test_queue_json_with_mock_prs

echo
echo "→ changelog (markdown release notes from tag history)"
run_test "changelog with no tags prints empty-state header"   test_changelog_no_tags_prints_empty_section
run_test "changelog with tags lists commits per tag"          test_changelog_with_tags_lists_commits

echo
echo "→ preview-merge (safe dry run of pending PR merge)"
run_test "preview-merge predicts CLEAN merge for clean case"  test_preview_merge_predicts_clean_merge

echo
echo "→ release-of (consumer canary across full lifecycle)"
run_test "consumer canary: full integration (3 cycles + ship + release-of)" test_canary_full_integration_local_consumer

echo
echo "→ L1-L5 reconcile retry ladder (behavioral)"
run_test "L1-L5: real conflict resolved by -X theirs (L3)"    test_l1_l5_reconcile_real_conflict_behavioral
run_test "multi-iter reconcile naming chain (X, -2, -3)"      test_multi_iter_reconcile_naming_chain

echo
echo "→ bootstrap-ci enhancements (pool/n38: repo config defaults)"
run_test "dev required-checks include compile/coverage/runtime"   test_bootstrap_ci_required_checks_dev_includes_compile_coverage_runtime
run_test "dev required-checks include opened-via-correct-flow"    test_bootstrap_ci_required_checks_dev_includes_opened_via_correct_flow
run_test "step_merge_commit_defaults present + idempotent"        test_bootstrap_ci_step_merge_commit_defaults_present
run_test "step_merge_mode_lock present + idempotent"              test_bootstrap_ci_step_merge_mode_lock_present
run_test "step_disable_auto_delete present + idempotent"          test_bootstrap_ci_step_disable_auto_delete_present
run_test "step_topics present + idempotent"                       test_bootstrap_ci_step_topics_present
run_test "new steps wired into main flow"                         test_bootstrap_ci_steps_wired_in_main
run_test "--dry-run emits API calls for all new steps"            test_bootstrap_ci_dry_run_emits_api_calls_for_new_steps
run_test "--check reports drift on all new steps"                 test_bootstrap_ci_check_mode_reports_drift
run_test "idempotent when state already matches every wanted"     test_bootstrap_ci_idempotent_when_state_correct
run_test "--help lists every step in order"                       test_bootstrap_ci_help_lists_every_step
run_test "step_workflows_enabled present + wired (pool/n40)"      test_bootstrap_ci_step_workflows_enabled_present
run_test "step_workflows_enabled dry-run emits PUT enable"        test_bootstrap_ci_step_workflows_enabled_dry_run_emits_put
run_test "step_workflows_enabled check reports disabled drift"    test_bootstrap_ci_step_workflows_enabled_check_reports_drift

echo
echo "→ off-grid mode (pool/n39)"
run_test "MODE file defaults to connected on fresh repo"        test_mode_defaults_to_connected
run_test "set-mode off-grid writes MODE file"                   test_set_mode_off_grid_writes_file
run_test "set-mode connected after flip writes MODE file"       test_set_mode_back_to_connected_writes_file
run_test "set-mode rejects invalid value"                       test_set_mode_invalid_value_rejected
run_test "set-mode --get prints current mode"                   test_set_mode_get_reads_current
run_test "doctor surfaces invalid MODE value"                   test_doctor_reports_mode_value
run_test "status reports mode in human + json"                  test_status_includes_mode_in_human_and_json
run_test "finalize-pool-merge refuses in connected mode"        test_finalize_pool_merge_refuses_in_connected_mode
run_test "ship refuses in connected mode"                       test_ship_refuses_in_connected_mode
run_test "init-pool-merge refuses in off-grid mode"             test_init_pool_merge_refuses_in_off_grid
run_test "init-release refuses in off-grid mode"                test_init_release_refuses_in_off_grid
run_test "apply-repo-rules refuses in off-grid mode"            test_apply_repo_rules_refuses_in_off_grid
run_test "bootstrap-ci refuses in off-grid mode"                test_bootstrap_ci_refuses_in_off_grid
run_test "claim-dev-merge no-ops cleanly when off-grid+CI"      test_claim_dev_merge_no_ops_when_off_grid_in_ci
run_test "claim-main-release no-ops cleanly when off-grid+CI"   test_claim_main_release_no_ops_when_off_grid_in_ci
run_test "mode flip round-trip (connected ↔ off-grid)"          test_mode_flip_round_trip_full_cycle

echo
echo "→ smart-commit (sub-claude subprocess isolation; pool/n51)"
run_test "smart-commit bin present + executable + --help"     test_smart_commit_bin_present_executable_and_help
run_test "smart-commit auto-stages all when index empty"      test_smart_commit_auto_stages_when_index_is_empty
run_test "smart-commit LIFECYCLE_TEST_MODE canned commit"     test_smart_commit_lifecycle_test_mode_produces_canned_commit
run_test "smart-commit skips active-requirement when absent"  test_smart_commit_skips_active_requirement_when_absent
run_test "smart-commit --dry-run does not commit"             test_smart_commit_dry_run_does_not_commit
run_test "doc-freshness workflow present + main-only trigger"  test_doc_freshness_workflow_present_and_triggers_only_on_main_base
run_test "doc-freshness script test-mode short-circuit"        test_doc_freshness_script_test_mode_short_circuit
run_test "doc-freshness script env-contract validation"        test_doc_freshness_script_env_contract_validation
run_test "doc-freshness detects stale CHANGELOG (e2e)"         test_doc_freshness_script_test_mode_detects_stale_changelog
run_test "doc-freshness canned claude response under test-mode" test_doc_freshness_script_canned_claude_response_under_test_mode
run_test "doc-freshness passes when CHANGELOG covers diff (e2e)" test_doc_freshness_script_passes_when_changelog_covers_diff
run_test "doc-freshness out-of-scope when base is dev"          test_doc_freshness_script_out_of_scope_when_base_is_dev
run_test "bootstrap-ci binds doc-freshness as required on main" test_bootstrap_ci_binds_doc_freshness_on_main
run_test "apply-repo-rules binds doc-freshness on main branch"  test_apply_repo_rules_binds_doc_freshness_on_main

echo
echo "→ off-grid e2e CLI (pool/n62)"
run_test "test-off-grid-e2e CLI present + executable + --help shape"  test_off_grid_e2e_cli_present_and_executable
run_test "test-off-grid-e2e refuses without explicit token + account" test_off_grid_e2e_refuses_without_explicit_token_and_account
run_test "test-off-grid-e2e --dry-run prints planned API calls"       test_off_grid_e2e_dry_run_prints_planned_api_calls_without_executing
run_test "test-off-grid-e2e uses the canonical allocator CLI (n71)"   test_off_grid_e2e_uses_canonical_allocator_cli
run_test "test-off-grid-e2e trusts post-merge hook for claim (n71)"   test_off_grid_e2e_trusts_post_merge_hook_for_pool_to_dev_claim

echo
echo "→ composite end-to-end"
run_test "full lifecycle: pool/n1 → dev → main"               test_full_lifecycle_simulation

echo
echo "=========================================================="
echo "  $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  echo
  echo "Failures:"
  for n in "${FAILURES[@]}"; do echo "  - $n"; done
  exit 1
fi
echo "  ALL LIFECYCLE TESTS PASSED"
exit 0
