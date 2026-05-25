---
name: git-merge-audit
description: Apply the merge commit discipline to every merge commit (feature→dev and dev→main). Title format [MERGE] source into target, body is description-paragraph-only, no rebuild/snapshot/recovered language, --no-ff always, date = source branch's latest content commit. Invoke from git-snapshots step 4 (feature merge) and step 5 (zip close).
---

# git-merge-audit — merge commit discipline

Every merge commit follows this exact discipline. Violations are visible at a glance and surface immediately in `git log --merges`.

## Title

1. **Format**: `[MERGE] <source> into <target>: <version>`. Examples:
   - **v4rian:** `[MERGE] pool/n7.feature.parser-rewrite into dev: v2026.0.164`
   - **v4rian:** `[MERGE] dev into main: v2026.0`
   - **Legacy:** `[MERGE] feature/v0/3/3-embed-on-device-audio into dev: v0.3.3`
   - **Legacy:** `[MERGE] dev into main: v0.3.9`
2. **No redundant "Merge" word**. The tag `[MERGE]` and the literal word "Merge" together is the smell:
   - Wrong: `[MERGE] Merge pool/n7.feature.parser-rewrite into dev`
   - Right: `[MERGE] pool/n7.feature.parser-rewrite into dev: v2026.0.164`
3. ≤72 chars. Sentence case.
4. No hyphens in prose, no em dashes, no "plus" word (identifier hyphens in branch names like `pool/n3.feature.foo-bar` or `feature/booking-pipeline` are fine).
4a. **Version is mandatory** per [[feedback_merge_to_main_includes_version]]. Source of the version:
    - **v4rian:** `cat VERSION` on dev gives `vYYYY.main.dev`. Feature→dev merge uses the full version; dev→main merge drops the trailing `.dev` segment for the release tag.
    - **Legacy:** Extract from the branch name (`feature/v0/3/3-name` → `v0.3.3`) or use the dev-tip's highest minor for dev→main (per [[feedback_feature_branches_under_version]]).

## Body

5. **The body IS the description paragraph.** 1-5 sentences. Macro recap. Summarizes what the source branch brought in at the user-facing or subsystem level.
6. **Use a NESTED list breakdown with one-line summaries on every leaf, AND every list line ends with a period.** Top-level bullets are topics; each topic has a sub-bullet list of its constituents; **each constituent leaf is `<label>: <one-line summary>.`** (not a bare label, and always terminated with a period). Topic headers also end with a period. Section headers that end with a colon (`Adds:`, `Reverts within the branch.`) follow normal punctuation. No `Changes:` header. No method names. No comma-separated inline enumeration. Shape:

   ```
   Adds:
   - <Topic A>.
       - <constituent label 1>: <one-line summary of what this feature/change actually does>.
       - <constituent label 2>: <one-line summary>.
   - <Topic B>.
       - <constituent label 1>: <one-line summary>.

   Reverts within the branch.
   - <reverted item>: <one-line summary>.
   ```

   (Shape evolved through four Joel corrections: prose → bullets → nested → nested with leaf summaries → period-terminated. Every list line in the body terminates with a period, including topic header bullets.)
7. **For `[MERGE] dev into main`**: summarizes the closed pack at one altitude higher than the source feature-branch merges. What shipped from the user's perspective, not what merged.
8. **METHOD: TOPIC-GROUPED RECAP OF THE UNDERLYING MERGES.** Pull the actual list of feature merges (or, for feature → dev, the commits inside the branch) via `git log --first-parent <prev-tip>..<this-branch>`. Group those titles by topic. Write the body as a topic enumeration: "Adds <topic A> (v0.X.A1 <title>, v0.X.A2 <title>). Adds <topic B> (...). ..." For feature branches: same shape but the parenthetical items are the in-branch commit titles. Reverts go in a closing clause: "Reverts within the branch: <reverts>." This is a literal recap of what merged, not an invented story.

   Pre-write check: read it aloud. If it sounds like a method signature pulled into prose OR like marketing copy, rewrite.

   Forbidden in merge bodies (pseudo-code pole):
   - File or directory names (`intake-context.md`, `task-statement.md`, `.ag-sym9/runs/`)
   - Byte counts, packet sizes, timeout values (`7-byte tag`, `8 s race`, `1500-byte prefix`)
   - Protocol or RFC references (`RFC 3261`, `stream-json`, `HTTP/2`, `WebSocket /audio`)
   - Code-construct names (class names, exported functions, struct keys, JSON frame types)
   - Implementation verbs aimed at a code reviewer (`detached-spawn`, `token-overlap lookup`, `filter-branch`)
   - Token literals (`[END_CALL]`, `[VOICE]`)

   Forbidden in merge bodies (user-manual pole):
   - Outcome-pitch phrases (`actually works`, `reliable enough to`, `just works`, `becomes usable`)
   - Anthropomorphized assistant verbs (`the assistant remembers`, `narrates itself`, `picks up on`)
   - Benefit framing aimed at an end user (`so the call stays light`, `so you can`, `lets you`)
   - Conversational filler (`finally`, `actually`, `now`)

   See `feedback_merge_body_macro_tone` for the canonical statement, the three-tier spectrum, and worked examples of all three tones.
9. **THIS MERGE ONLY.** The body describes the diff of THIS merge. Never references prior merges' scope ("on top of the v0.2.0 voice-note ingest"), sibling feature branches, or future planned work. Absolute terms, not relative. See `feedback_merge_body_scope_is_this_merge_only`.

### Examples

`[MERGE] feature/booking-pipeline into dev`:

```
Lands the booking lifecycle backbone: time utilities, the Google Calendar manager,
the Dogwatch scheduler, and the BookingService class assembled method by method
along the shift, offer, cancellation, and admin tool boundaries.
```

`[MERGE] dev into main`:

```
Closes the booking pipeline ecosystem rollout: shared time utilities, Google Calendar
manager, Dogwatch scheduler, BookingService class, IntegrationsService gateway,
GoogleOAuthCalendar OAuth2 integration, FirebaseHelper credential fallback with
signed download URLs, APNs push subsystem, operator tooling, and the WebSocket
dispatcher wired through the new services.
```

## Forbidden in title or body

8. `BAK`, `bak import`, `historical import`, `pre ATM role`, `captured in`, `from the zip`, `recovered from`, `reconstructed`, `WIP snapshot`, `in this zip`, `preflight`.
9. `rebuild` as a noun ("Closes the rebuild..."). Use feature-led framing.
10. `Co-Authored-By: Claude` trailer.

## Mechanics

11. **`--no-ff` always**. Preserves the merge commit even when fast-forward is possible. Without `--no-ff`, the working branch's atomic commits become indistinguishable from direct-on-dev commits.
12. **Date**: source branch's latest content commit:
    ```bash
    # v4rian:
    DATE_ISO=$(git log -1 --format=%aI pool/<nN.kind.short_name>)
    GIT_AUTHOR_DATE="$DATE_ISO" GIT_COMMITTER_DATE="$DATE_ISO" \
      git merge --no-ff pool/<nN.kind.short_name> -m "[MERGE] pool/<nN.kind.short_name> into dev: <version>
    
    <description paragraph>"

    # Legacy:
    DATE_ISO=$(git log -1 --format=%aI feature/<short_name>)
    GIT_AUTHOR_DATE="$DATE_ISO" GIT_COMMITTER_DATE="$DATE_ISO" \
      git merge --no-ff feature/<short_name> -m "[MERGE] feature/<short_name> into dev: <version>
    
    <description paragraph>"
    ```
13. **For `[MERGE] dev into main`**: date is `dev`'s latest commit date:
    ```bash
    DATE_ISO=$(git log -1 --format=%aI dev)
    git checkout main
    GIT_AUTHOR_DATE="$DATE_ISO" GIT_COMMITTER_DATE="$DATE_ISO" \
      git merge --no-ff dev -m "[MERGE] dev into main: <version>
    
    <description paragraph>"
    ```

## Strategy

14. Working branches merge into `dev`, not `main`. **v4rian:** `pool/nN.*` only; never push direct merges to dev under any other naming. **Legacy:** `feature/*` or `hotfix/*`.
15. `dev` merges into `main` at every zip close / release (per `feedback_main_merge_per_zip`). Not just at the end of the chain.
16. One tagged `[MERGE]` per working branch; never leave parallel untagged `Merge ... into dev` duplicates in history.
17. **v4rian-specific:** CI auto-tags the merge commit (`dev-merge.yml` for dev merges, `main-merge.yml` for main merges). Do NOT tag manually — would race CI. The merge commit's title carries the version that CI will claim; CI executes the claim.

## PR body parity

10. **The PR description body and the merge commit body MUST be character-identical.** When either is rewritten, PATCH the other via the GitHub API in the same operation. The parity check belongs in the close-up sequence and in any post-hoc rewrite. See `feedback_pr_body_matches_merge_commit` for the canonical statement and the parity-check command. Two text surfaces, one source of truth.

## Pre-push lens

Before pushing a merge commit:

- Title scans `[MERGE]` then space then source then ` into ` then target then `: <version>` (version mandatory per `feedback_merge_to_main_includes_version`).
- For dev → main on **legacy**: version is the dev tip's highest minor that landed, NOT Z reset to 0. See `feedback_feature_branches_under_version`.
- For dev → main on **v4rian**: version is `cat VERSION` with the trailing `.dev_counter` segment dropped (e.g. `vYYYY.main.dev` → `vYYYY.main`). See `reference_v4rian_versioning`.
- For working-branch → dev on **v4rian**: version is `cat VERSION` verbatim (full `vYYYY.main.dev`).
- Body parses as one paragraph with no leading bullets and no `Changes:` header.
- **Macro tone check** (rule 8): grep the body for any of: file names with extensions (`.md`, `.mjs`, `.json`, `.sh`), directory paths (`/`, `<`), byte counts (`\d+\s*(b|byte|bytes|ms|s)`), RFC references (`RFC\s*\d`), token literals in brackets (`\[[A-Z_]+\]`), known implementation verbs (`detached-spawn`, `filter-branch`, `token-overlap`, `stream-json`, `dispatchChain`). Any hit → rewrite the offending clause in plain English.
- **This-merge-only check** (rule 9): grep the body for `on top of`, `extending`, `building on`, mentions of any version OTHER than this merge's own version, references to other branches. Any hit → rewrite to describe only the current merge's diff.
- `git show --stat` confirms the merge brought in the expected feature scope.
- Date column matches the source branch's latest commit's date.
- `--first-parent main` log line for this merge shows the right summary.

## Retroactive cleanup

If old history carries untagged `Merge feature/X into dev` commits or `[MERGE] Merge X into Y` redundancy:

- `git filter-branch --msg-filter` with a `case` statement targeting the exact problem titles, or
- Interactive rebase with `exec` per-commit `git commit --amend -m "..."` (preserves dates via `--no-edit` plus env vars set).

See `git-history-rewrite` for date-preserving rewrite mechanics. Never rewrite history that contains user-authored commits without explicit authorization (`git-history-preservation`).

## See also

- [`git-snapshots`](../git-snapshots/SKILL.md) — orchestrator; invokes merge-audit in steps 4 and 5.
- [`git-commit-audit`](../git-commit-audit/SKILL.md) — Section H is the merge slice of the full audit.
- [`git-strategy-audit`](../git-strategy-audit/SKILL.md) — branching strategy enforcement (v4rian vs legacy model selection).
- [`git-history-rewrite`](../git-history-rewrite/SKILL.md) — date-preserving rewrites for retroactive merge cleanup.
- [`git-coverage-audit`](../git-coverage-audit/SKILL.md) — coverage diff after dev → main merge.
- [[reference_v4rian_versioning]] — version source of truth (`bin/version` derived from git merge counts; no VERSION file, no bump.sh) for v4rian repos.
- [[reference_v4rian_branching]] — working-branch name format for v4rian repos.
- [[feedback_dev_merges_tag_internal_only]] — v4rian: dev tags internal, only main tags Released.
