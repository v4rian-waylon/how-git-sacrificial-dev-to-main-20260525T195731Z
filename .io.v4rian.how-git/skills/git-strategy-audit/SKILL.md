---
name: git-strategy-audit
description: Enforce the branching + workflow strategy on every commit cluster. Two models — v4rian (pool/nN.kind.[sprintX-][JIRA-]short_name with paired safety/nN.* anchor created by the allocator) and legacy (feature/v{X}/{Y}/{Z}-name). Single commit → straight to dev; ≥2 commits → working branch; --no-ff merges; dev merges into main at every release; README touched per meaningful branch; no zip-mechanism words in branch names. Invoke from git-snapshots step 2 BEFORE composing commits.
---

# git-strategy-audit — branching + workflow strategy enforcement

**STATUS:** deterministic enforcement moved to the allocator workflow + server-side Repository Rules + async CI. As of the Step 2 lifecycle redesign (`pool/n33`), the synchronous claude pass at `pre-push` time is dropped. Branch-shape correctness is now owned end-to-end by `allocate-pool-branch.yml` (the atomic pool/safety pair allocator), the local `pre-push` hook is regex-only, and the branch-shape lens is re-applied asynchronously in CI via `.github/workflows/audit-pushed-branch.yml` on every pushed branch. The full strategy reference below remains authoritative for humans + agents planning branch layout BEFORE the first commit.

Strategy is decided BEFORE the first commit, not after. This skill answers: what branches do I need, how many commits per branch, what names, and what merge shape.

## Branching model — pick the model first

There are TWO models in play. Identify the repo's model BEFORE any branch design:

| Marker | Model |
|---|---|
| `.io.v4rian.how-git/githooks/pre-push` enforces `^(pool\|safety)/n[0-9]+\.…` regex | **v4rian** |
| `VERSION` file with `vYYYY.main.dev` shape (three segments, no `-b.` separator) | **v4rian** |
| `feature/v{X}/{Y}/{Z}-name` branches in `git branch -a` | **legacy** |
| Brand-new repo with neither marker | **v4rian** (bootstrap from `how-git` template) |

If unclear, ask. Do not mix models within a repo. See [[reference_git_strategy]] for the full model breakdown.

### Canonical model — v4rian (new repos, from [[reference_how_git_template]])

```
main ← dev ← pool/nN.(feature|fix|r&d|refactor|reconcile).[sprintX-][JIRA-]short_name
                                                           ↑
                            paired safety/nN.SAME (atomic anchor) created
                            by the branch-creation endpoint at the same SHA
```

- `main` carries released state. Protected. Only merges from `dev` via PR. Tag + GitHub Release on every merge (CI-driven).
- `dev` carries integration state. Protected. Only merges from `pool/nN.*` via PR. Internal version tag on every merge (CI-driven).
- `pool/nN.kind.short-name` is short-lived per feature. Allocated by the branch-creation endpoint ([[reference_v4rian_branch_creation_endpoint]]) — **developers DO NOT create remote pool/* branches** ([[feedback_no_developer_branch_creation]]).
- `safety/nN.kind.short-name` is the paired immutable anchor. Created atomically with the pool/* branch. Read-only. CI auto-GCs on the next main merge that releases the paired work ([[reference_v4rian_safety_anchor_pairs]]).
- `kind ∈ {feature, fix, r&d, refactor}`. `sprintX-` and `JIRA-` segments optional. `short_name` lowercase, `[a-z0-9][a-z0-9-]*`.

Versioning: `vYYYY.main_counter.dev_counter` per [[reference_v4rian_versioning]]. Three segments; `main_counter` resets on year rollover; `dev_counter` resets on main merge or year rollover. Hotfixes follow the standard `dev → main` pipeline per [[feedback_hotfix_through_dev_no_bypass]].

### Legacy model (older repos)

```
main ← dev ← feature/v{X}/{Y}/{Z}-name
```

- `feature/v{X}/{Y}/{Z}-name` per [[feedback_feature_branches_under_version]] (legacy) / `feature/v0/0/N-name` for first pack per [[feedback_first_pack_mid_zero]].
- Branch creation is by-developer.
- Versioning is semver `vX.Y.Z`; Z inherits dev tip's highest minor verbatim.

For zip rebuilds (either model): at every zip close, `dev` merges into `main` (per [[feedback_main_merge_per_zip]]).

## Branch-per-commit-count rule (model-agnostic)

| Atomic commits planned | Strategy |
|---|---|
| 1 | Straight to `dev`. No working branch. |
| ≥2 | Cut a working branch off `dev`. Commit there. Merge `--no-ff` into `dev` at end. |

Verify before starting work:

```bash
# Lay out the atomic commits you intend to make.
# If the list has 1 entry, skip the branch.
# If the list has ≥2 entries, name the working branch FIRST.
```

Atomicity heuristics:
- One new file = one commit.
- One refactor pass = one commit.
- One bug fix = one commit.
- A tooling change adjacent to a feature = its own commit.

When in doubt about whether two changes should be one commit, **split them**. Combining is cheap (squash on merge); splitting after the fact is expensive.

## Working-branch naming

### v4rian repos

5. **Format**: `pool/nN.(feature|fix|r&d|refactor|reconcile).[sprintX-][JIRA-]short_name`. Regex:
   ```
   ^pool/n[0-9]+\.(feature|fix|r&d|refactor|reconcile)\.(sprint[0-9]+-)?([A-Z]+-[0-9]+-)?[a-z0-9][a-z0-9-]*$
   ```
6. **`nN` is allocated by the branch-creation endpoint** ([[reference_v4rian_branch_creation_endpoint]]). Never pick `nN` yourself. Local spike branches with the right shape are fine (`pre-push` hook warns but allows); the remote rejects developer-created `pool/*` pushes per Repository Rules ([[feedback_no_developer_branch_creation]]).
7. **Paired safety branch** is created atomically by the endpoint at `safety/nN.kind.short_name`. Do not create safety branches manually; do not touch them after creation (Pattern 1, per [[reference_v4rian_safety_anchor_pairs]]).

Examples:
- `pool/n3.feature.parser-rewrite`
- `pool/n3.feature.sprint4-parser_rewrite`
- `pool/n7.fix.PROJ-123-token_leak`
- `pool/n12.r&d.sprint5-PROJ-456-embedding_cache`
- `pool/n4.refactor.config-module`

### Legacy repos

5. **Format**: `feature/<kebab-case-short-name>` (early) or `feature/v{X}/{Y}/{Z}-name` (versioned). Examples:
   - `feature/booking-pipeline`
   - `feature/v0/3/3-embed-on-device-audio`

6. **Forbidden in branch names (both models)**:
   - `zip1`, `zip2`, `zipN`, any literal zip reference (`feature/zip1_definitions_backend` is wrong).
   - `bak`, `wip`, `snapshot`, `historical`, `preflight` (other than the literal `preflight-bak-YYYY-MM-DD` security backup branches).
   - `recovered`, `reconstructed`, `from-zip`, `captured-in`.
   - Uppercase in the short-name segment (v4rian requires lowercase; legacy used kebab-case which is also lowercase).

7. **Branch names describe the FEATURE / fix / refactor**, not the mechanism. Multiple working branches per zip is normal.

## Merge shape (both models)

8. `--no-ff` always. Preserves the merge commit even when fast-forward is possible.
9. One tagged `[MERGE] <branch> into dev: <version>` per working branch merge. Never leave parallel untagged `Merge ... into dev` duplicates.
10. `[MERGE] dev into main: <version>` per release (or per zip close during rebuilds).

See [`git-merge-audit`](../git-merge-audit/SKILL.md) for the merge commit's title + body + date discipline.

## README discipline per working branch

11. Every meaningful working branch (new subsystem, new integration, new operator workflow, architecture change) must touch `README.md` at least once. Two paths:
    - **Preferred**: add a `[DOCS] Document X in README` commit ON the working branch (typically the last commit, or a dedicated commit alongside the new code).
    - **Acceptable**: include a one-line README delta in the merge commit's body if the change is tiny.
12. Internal refactors that don't change behavior or surface do NOT require README updates.

## Strategy planning per zip / per release (Step 2 of git-snapshots)

For zip N (or release N), before composing any commits:

1. `diff -r --brief` zip N vs zip N-1 to produce the change list per repo.
2. Group changes into atomic topics (one topic = one working branch).
3. For each topic with ≥2 atomic commits: design the working branch.
   - **v4rian:** plan the kind + sprint/jira + short-name; the allocator will assign `nN` at request time.
   - **Legacy:** branch name kebab-case feature-led.
   - Commit list: each is a single concern with a [TAG] in mind.
   - README touch: which commit on the branch does it?
4. For each topic with 1 atomic commit: plan to commit straight to dev.
5. Confirm the merge order: working branches merge into dev in the order their content layers (deps first).
6. Plan the `[MERGE] dev into main` at zip close / release boundary.

## Strategy audit lens

Before merging or pushing, walk this lens:

| Item | Question |
|---|---|
| 1 | Does every working branch have ≥2 atomic commits? (If 1, should have been straight to dev.) |
| 2 | Does every meaningful working branch carry a `[DOCS]` README commit? |
| 3 | **v4rian:** Does every `pool/nN.*` branch have a paired `safety/nN.*` anchor (Invariants I2 + I7)? Did the allocator create both, never a dev? |
| 4 | **v4rian:** Is every working branch name matching the regex? Lowercase short-name, valid kind, optional sprint/jira correctly formatted? |
| 5 | **Legacy:** Are all feature branch names kebab-case + feature-led (no `zipN`, `bak`, `wip`)? |
| 6 | Did every working branch merge into dev with `--no-ff`? |
| 7 | Is there exactly ONE `[MERGE] <branch> into dev: <version>` per working branch (no parallel untagged dupes)? |
| 8 | Is `dev` merged into `main` at this release / zip close? |
| 9 | Does the order of working-branch merges into dev respect dependency layering? |
| 10 | **v4rian:** Will CI tag + Release on the main push (no manual tagging)? |

If any item fails, fix before pushing.

## Blank `main` exception (legacy mechanic; rarely needed under v4rian)

For repos that should be empty (created by mistake, or wiped per user direction):

- `main` is an orphan commit with empty tree (`git mktree` with no input).
- Commit message: `Initial`.
- No `dev` branch.
- No working branches.
- See `git-history-rewrite` for the mechanic.

The strategy still applies the moment the repo gets real content — the very first work cuts a working branch off the empty `main`. Under v4rian, that work goes through the allocator.

## Banned shortcuts

- Single-commit working branches as a convenience (e.g. "this fits with the feature concept") — violates the 1-commit-straight-to-dev rule; clutters history.
- Branching off `main` directly for features — always off `dev`.
- Squash-merging on `dev` (defeats atomicity).
- Naming `pool/n3.feature.temp` or `feature/test` — every branch carries a real feature short name.
- **v4rian:** Developer-created `pool/*` or `safety/*` branches on the remote (allocator-only; see [[feedback_no_developer_branch_creation]]).
- **v4rian:** Picking `nN` yourself (race condition with allocator).
- **v4rian:** Tagging dev or main manually (CI's job; see [[reference_v4rian_versioning]]).

## See also

- [`git-snapshots`](../git-snapshots/SKILL.md) — strategy planning is Step 2.
- [`git-commit-audit`](../git-commit-audit/SKILL.md) — Section G is the branching slice of the full audit.
- [`git-merge-audit`](../git-merge-audit/SKILL.md) — merge commit shape after strategy is decided.
- [`git-snapshot-preflight`](../git-snapshot-preflight/SKILL.md) — `preflight-bak-*` branches are NOT working branches; different rules.
- [[reference_v4rian_branching]] — v4rian model full detail.
- [[reference_v4rian_branch_creation_endpoint]] — the allocator contract.
- [[reference_v4rian_safety_anchor_pairs]] — atomic pair invariant.
- [[reference_how_git_template]] — the template that bootstraps v4rian repos.
