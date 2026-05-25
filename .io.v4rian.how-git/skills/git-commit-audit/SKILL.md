---
name: git-commit-audit
description: Pre-write audit lens applied to every commit before composing its message. Covers atomicity, title, body, bullets, fabrication, file hygiene, branching, merge format, and the staged-mtime date rule. Run section A-I against the staged diff; if any fails, restage / resplit / rewrite. Invoke from git-snapshots before each commit; do not invoke a separate skill for tag fit (covered here).
---

# git-commit-audit — pre-write commit lens

**STATUS:** deterministic enforcement moved to async CI and the local auto-fix layer. As of the Step 2 lifecycle redesign (`pool/n33`), the synchronous claude pass at `commit-msg` time is dropped. The `pre-commit` hook scrubs em/en-dashes from staged files, `prepare-commit-msg` runs the shared `scripts/lib/auto-fix-commit-message.sh` to rewrite messages in place (em-dash scrub, banned-word replacement, tag derivation, sentence cap, third-person bullets), and `commit-msg` keeps only the cheap 8-100 char subject-length guardrail. The full audit lens below remains the authoritative reference: it is now applied (a) interactively by humans + agents composing commits and (b) asynchronously in CI via `.github/workflows/audit-pushed-branch.yml` against every pushed branch.

Run this audit on every staged change before composing the commit message. Treat the commit like a PR you are reviewing for the first time. Every rule below was earned through correction. Saved memory is binding, not advisory.

## A. Atomicity

1. List every concept the diff touches. ≥2 concepts? Split with `git reset HEAD` + selective re-staging.
2. Natural title contains `+`, `,`, `and`, `with`, or `plus`? Each joiner is a non-atomicity smell. Split.
3. Diff spans unrelated subsystems? Split unless one concept connects them.
4. Soft cap: ~800 lines per commit. A 2400-line monolith is three commits at most.
5. Single atomic commit → straight to `dev`. ≥2 atomic commits → cut `feature/<short_name>` first.

## B. Title format

6. `[TAG] Title in sentence case` (Jira code optional). Approved tags only: `[FIX]`, `[NEW]`, `[REFACTOR]`, `[DOCS]`, `[TEST]`, `[REVERT]`, `[HOTFIX]`, `[MERGE]`.
7. **`[NEW]` qualifies ONLY when**:
   - A brand new file appears (class, component, screen, script, integration, dependency).
   - A new external integration (Apple platform binding, Google API, vendor SDK).
   - A new subsystem bootstraps (service, scheduler, bridge).
   - A new operator workflow.
   - A new dependency in the build.
   Helper methods inside existing classes, palette tokens, case-handler adapters to existing dispatch → `[REFACTOR]`. Smell test: if removing this commit would make a feature disappear → `[NEW]`; if it would leave the existing feature with less internal structure → `[REFACTOR]`.
8. ≤72 chars. Sentence case.
9. Merge title is `[MERGE] <source> into <target>` — no redundant "Merge" word.
10. Banned in title prose: hyphens (in English compounds), em dashes, the word "plus". Identifier hyphens (`io.sessionpass.admin`, `feature/booking-pipeline`, `Objective-C++`) stay.

## C. Body layout

11. **Body opens with a 1-3 sentence general description paragraph** that expands the title at subsystem/class altitude. Title says WHAT; description says WHY and at WHAT SCOPE; bullets say HOW. Never restates the title; never drifts into method-level detail.
12. `[FIX]`/`[HOTFIX]`: after the description, `Cause:` then `Fix:` then bullets.
13. Any other tag: after the description, bullets follow directly. **No `Changes:` header** when it would be the only section or first section after the title.
14. `[MERGE]` body IS the description paragraph only — no bullets, no `Changes:` header.
15. Banned in body prose: hyphens (in English compounds), em dashes, "plus" word.
16. Forbidden zip-mechanism words anywhere: `BAK`, `bak import`, `historical import`, `pre ATM role`, `captured in`, `from the zip`, `recovered from`, `reconstructed`, `WIP snapshot` (as a title), `in this zip`.
17. No `Co-Authored-By: Claude` trailer.

## D. Bullet rules

18. **V.1** — Top-level bullet leads with class or module name, **not path**. Exception: path is part of the story (file move, contract config file).
19. **V.2** — Methods nest under their class. Class name never repeats per line.
20. **V.3** — Bullet describes a class, function, or method ONLY. **Never** fields, properties, vars, constants, Q_PROPERTY data, `readonly` tokens, instance members, signals-without-handler.
21. **V.4** — No constructor bullets. Skip them.
22. **V.5** — One short verb-led sentence per symbol. Drop parameter lists, drop return shapes, drop step-by-step algorithm walks (unless the algorithm IS the concept).
23. **V.6** — If the function carries a docstring, lift its verb and concept noun. Do not invent a paraphrase.
24. **V.7** — Third person present tense. `Normalizes`, `Sends`, `Schedules` — not `Normalize`, `Send`, `Schedule`; not "New", not "New function that ...".
25. **V.8** — Software-standard vocabulary only. `Creates`, `Deletes`, `Updates`, `Reads`, `Writes`, `Schedules`, `Dispatches`, `Returns`, `Throws`, `Adds`, `Exposes`, `Drops`. **Banned**: "Stands up", "Tears down", "Spins up", "Lights up", "Stitches together", "Kicks off", "Gains" (use "Adds" / "Exposes").
26. **V.9** — New symbol: declarative present (`resolveCredential: Tries a cert file ...`). Modified symbol: uses `now` (`getUserAccessLevel now tries ...`).
27. **V.10** — Never fabricate symbol names. Every method/function/class/signal named in a bullet **must exist in the file at the commit's content**. Verify via `git show <sha>:<path>` + grep before composing the bullet.

### V.10 verification recipes

- JS class methods: `grep -nE '^  (async\s+)?(static\s+)?(get\s+|set\s+)?[#a-zA-Z_][a-zA-Z0-9_]*\s*\(' path/to/file.js`
- C++: read `.h` declarations + grep `.cpp` for `ClassName::methodName`.
- QML: grep for `function methodName(`, `signal signalName(`, or `function on<Signal>(`.
- Objective-C: grep for `- (returnType)selectorName:` or `+ (returnType)selectorName:`.

## E. File hygiene

28. `git diff --cached --name-only` shows none of: `.DS_Store`, `**/.DS_Store`, `.auth/`, `keys/`, `*.p8`, `*.p12`, `*.cer`, `*.pem`, `*.provisionprofile`, `*.mobileprovision`, `build/`, `build-*/`, `node_modules/`, `.env`, `exports/`, `*.zip`, `aqtinstall.log`, `runtime-smoke-notes.md`, `*.bak`, `*_old.qml`.
29. Repo `.gitignore` blocks the above on first touch.
30. Never `git add -A` or `git add .`. Stage files by name.
31. `node --check` passes for staged JS files; project still imports.

## F. Date rule (during zip rebuilds)

32. **Both** `GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE` set to the latest mtime of the staged subset:
    ```bash
    DATE_EPOCH=$(git diff --cached --name-only -z | xargs -0 stat -f '%m %N' 2>/dev/null | sort -nr | head -1 | awk '{print $1}')
    DATE_ISO=$(date -u -r "$DATE_EPOCH" +"%Y-%m-%dT%H:%M:%SZ")
    GIT_AUTHOR_DATE="$DATE_ISO" GIT_COMMITTER_DATE="$DATE_ISO" git commit -m "..."
    ```
    Setting only `GIT_AUTHOR_DATE` is the classic bug — committer falls back to "now" and breaks the timeline.

    **Timezone discipline (added 2026-05-20 after a 7h offset incident):**
    - Real-time commit (work happening NOW): omit both env vars; plain `git commit -m "..."` uses host local time + host TZ correctly.
    - Snapshot rebuild commit: use the epoch + `date -u -r` chain above (UTC `Z` tag is genuine — derived from epoch, not local wall-clock).
    - **NEVER `stat -f '%Sm' -t '<...>Z'`.** That format emits LOCAL wall-clock numbers but tags them `Z`, so git stores them as UTC and every commit is off by the local-UTC offset. Either use `%z` (lowercase — explicit offset like `-0700`) or compute from epoch.
    - When the TZ of the original work is ambiguous (zip captured on a different machine, hand-edited timestamp, unclear authoring location), **ASK ONCE** before committing.

    The audit must verify:
    - Author date == committer date (both set, equal value).
    - The date is either current local with explicit offset OR a past UTC derived from epoch (no local-wall-clock-tagged-Z).
    - For snapshot rebuilds, the date is ≤ "now" and ≥ the prior commit's date on the branch (monotonic timeline).
33. Bring zip files in with `cp -p` or `rsync -a` to preserve original mtimes. Plain `cp` is forbidden.
34. Merge commit date = source branch's latest content commit date: `DATE_ISO=$(git log -1 --format=%aI feature/<x>)`.
35. `[DOCS]`/README commit date = feature branch's latest content commit date (override README.md's "now" mtime).

## G. Branching

36. One atomic commit → straight to `dev`, no working branch.
37. ≥2 atomic commits → cut a working branch:
    - **v4rian repos** (from [[reference_how_git_template]]): `pool/nN.(feature|fix|r&d|refactor|reconcile).[sprintX-][JIRA-]short_name`, allocated by the branch-creation endpoint ([[reference_v4rian_branch_creation_endpoint]]). Never pick `nN` yourself; never push a developer-created `pool/*` ref to remote ([[feedback_no_developer_branch_creation]]). The paired `safety/nN.SAME` anchor is created atomically — never touch it.
    - **Legacy repos**: `feature/v{X}/{Y}/{Z}-name` per [[feedback_feature_branches_under_version]] or `feature/<short_name>` (kebab case). Either way: no `zipN`, no `bak`, no `wip`, no `snapshot`, no `historical`.
38. `--no-ff` merge into `dev` at the end.
39. Meaningful working branch (new subsystem, integration, operator workflow, architecture change) — at least one commit is `[DOCS]` and touches README.

## H. Merge audit (when committing a merge)

40. Title is `[MERGE] <source> into <target>: <version>` (no redundant "Merge" word). Version mandatory per [[feedback_merge_to_main_includes_version]]. Format:
    - **v4rian:** feature→dev uses `cat VERSION` verbatim (e.g. `vYYYY.main.dev`); dev→main drops the trailing `.dev` segment for the release.
    - **Legacy:** version derived from the branch name's version segment or dev tip's highest minor for dev→main.
41. Body is description-paragraph-only — feature-led; no bullets, no `Changes:` header.
42. Body never mentions `rebuild`, `import`, `snapshot`, `recovered`, `reconstructed`, `WIP`.
43. Merge target follows the strategy: working branches into dev, dev into main at release / zip close. No jumps. Under v4rian: no manual tag (CI does it via `dev-merge.yml` / `main-merge.yml`).

## I. Retroactive review (post-bak-rebuild)

The same lens applies to commits already in `git log`. Walk every commit; catalog every offense; plan the corrective rebase. Never patch only the commit that was flagged — sibling commits made by the same author in the same session usually carry the same defect.

## Pre-commit ritual

Before pressing `git commit`:

1. Re-read items 1-43 against the staged diff.
2. Quote one bullet from your draft into the audit lens — does it pass V.1-V.10?
3. Run V.10 grep verifications for every named symbol.
4. Run `node --check` on staged JS.
5. Confirm date env vars are set.

If any item fails, fix before committing. The cost of pausing is always lower than the cost of the retroactive amendment.

## See also

- [`git-snapshots`](../git-snapshots/SKILL.md) — the main orchestrator.
- [`git-history-preservation`](../git-history-preservation/SKILL.md) — user-authored commits are read-only.
- [`git-strategy-audit`](../git-strategy-audit/SKILL.md) — branching plan before commits.
- [`git-merge-audit`](../git-merge-audit/SKILL.md) — merge commit specifics.
