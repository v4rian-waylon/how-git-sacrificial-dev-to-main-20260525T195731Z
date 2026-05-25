<!--
  v4rian PR template.

  The validate-pr-open workflow (.github/workflows/validate-pr-open.yml)
  fires on opened / edited / synchronize and runs scripts/validate-pr-open.sh
  against this body. The workflow auto-amends the title and runs the
  shared auto-fix pass over the body, then posts the
  opened-via-correct-flow status check. Edit history shows every
  amendment; you can re-edit if an amendment misjudged.

  Skeleton sections below match the v4rian model: macro TLDR at
  subsystem altitude in Summary, Cause + Fix only when the PR carries a
  [FIX] tag, Changes as plain bullets. Do not delete the workflow
  signature marker at the bottom; the workflow uses it to confirm the
  body passed validation.
-->

## Summary

<!--
  One to five sentences at subsystem altitude. Describes WHAT this
  merge changes and WHY. No file names, byte counts, RFC numbers,
  class names, code constructs, token literals, or implementation
  verbs. Reader is future-you scanning the log, not a code reviewer.
-->

## Cause + Fix

<!--
  Include ONLY when the PR's title carries [FIX] or [HOTFIX].
  Cause: one sentence describing the root cause of the bug.
  Fix:   one sentence describing the surgical change that resolves it.
  The validate-pr-open script enforces this conditionally based on the
  derived tag.
-->

## Changes

<!--
  Symbol-led bullets in third-person present (Adds X, Removes Y,
  Updates Z). Lead with the module name when the bullet is per-file.
  The auto-fix pass rewrites imperative bullets ("add", "fix") into
  third-person form ("Adds", "Fixes") to match the convention.
-->

-

<!-- opened-via-correct-flow: signature inserted by validate-pr-open workflow -->
