# v4rian git RUNBOOK

The one-page operator cheat sheet. Every command assumes you're at the repo root and `core.hooksPath` is set (run any in-repo script once to auto-activate, or `bash .io.v4rian.how-git/scripts/heal.sh`).

## See where you are

```bash
.io.v4rian.how-git/bin/status           # human-readable
.io.v4rian.how-git/bin/status --json    # machine-readable
```

Reports: current branch + sha, current version (`vYEAR.SERIES.DEV` seal), latest tag, ahead/behind vs origin, open-PR count, dev claims this year, current mode (`connected` or `off-grid`).

## Modes (connected vs off-grid)

Every v4rian repo runs in one of two modes, tracked in `.io.v4rian.how-git/MODE`:

```bash
.io.v4rian.how-git/bin/set-mode --get      # print the current mode
.io.v4rian.how-git/bin/set-mode off-grid   # flip to off-grid (admin-gated)
.io.v4rian.how-git/bin/set-mode connected  # flip back (admin-gated)
```

The flip lands as a normal `[MODE] switch to <new>` commit on the checked-out branch. In connected mode the admin gate runs against the GitHub permission API; in off-grid mode the gate is advisory (the operator is trusted; admins.txt is the only durable allowlist when no remote is authoritative).

Per-mode entry-point matrix:

| Step | Connected | Off-grid |
|---|---|---|
| Allocate pool/safety pair | `bin/create-pool-branch` -> allocator workflow | (currently connected-only; allocator workflow drives it) |
| Open pool to dev PR | `bin/init-pool-merge` | refused (no remote PR concept) |
| Pool to dev merge | GitHub UI button | `git merge --no-ff <pool> -m "..."` then `bin/finalize-pool-merge` |
| Pool to dev claim ceremony | `claim-on-merge-dev` workflow runs `claim-dev-merge.sh` in CI | `bin/finalize-pool-merge` runs `claim-dev-merge.sh` locally |
| Open dev to main release PR | `bin/init-release` | refused |
| Dev to main merge | GitHub UI button | `bin/ship` (merges and runs claim locally; --skip-push for LAN/air-gap) |
| Dev to main claim ceremony | `claim-on-merge-main` workflow runs `claim-main-release.sh` in CI | `bin/ship` invokes `claim-main-release.sh` locally |
| Apply Repository Rules | `bin/bootstrap-ci` (delegates to `apply-repo-rules.sh`) | refused (no remote governance) |

Whichever mode is wrong for the step you're attempting refuses with a message that names the correct mode and the `bin/set-mode` command to flip.

## Get the version of the current commit

```bash
.io.v4rian.how-git/bin/version              # vYEAR.SERIES.DEV-<sha7>.<build>  (with build counter)
.io.v4rian.how-git/bin/version --seal       # vYEAR.SERIES.DEV  (no SHA/build suffix)
.io.v4rian.how-git/bin/version --next-dev   # what the next pool to dev merge would claim
.io.v4rian.how-git/bin/version --build      # same as default, but increment local build counter first
```

The build counter is per-clone (`version.build` file, gitignored). Reset with `--reset`.

## Develop a feature

```bash
# Allocator workflow creates pool/nN + safety/nN pair atomically.
# Dispatch from a local admin shell (calls `gh workflow run` under the hood):
.io.v4rian.how-git/bin/create-pool-branch parser-rewrite --jira PROJ-123 --kind feature \
  --requirement "Rewrite the parser to handle nested blocks per spec section 4.2."
# Branch kinds: feature, fix, r&d, refactor, reconcile, doc (kind classified
# from the JIRA payload when --kind is omitted).
# The --requirement text becomes the body of the initial [REQ] commit
# on the pool branch AND is written to .io.v4rian.how-git/active-requirement
# so auditors (auto-rebase L1-L5 ladder, post-checkout preflight) can fetch
# the branch's canonical intent before invoking claude. Alternatives:
#   --requirement-file ./req.txt   read from a file
#   (JIRA Automation passes it through client_payload.requirement)
git fetch && git checkout pool/n7.feature.PROJ-123-parser-rewrite
# ... edit, commit ...
git push origin pool/n7.feature.PROJ-123-parser-rewrite
.io.v4rian.how-git/bin/init-pool-merge             # opens PR into dev via the template
```

`bin/init-pool-merge` dispatches `gh pr create` with the PR body skeleton from `.github/PULL_REQUEST_TEMPLATE.md`. After dispatch, the `validate-pr-open.yml` workflow amends the title to `[KIND] vYYYY.X.Y: <short>` derived from `bin/version --next-dev`, runs the shared auto-fix pass over the body, embeds the workflow signature, and posts the required `opened-via-correct-flow` status check. Pass `--edit` to open `$EDITOR` with the template pre-loaded; `--dry-run` shows the dispatch without calling the API.

### Active requirement: what claude reads when an auditor invokes it

Every pool branch carries a canonical "active requirement" document — the verbatim text the allocator received from JIRA Automation, the workflow_dispatch UI, the CLI wrapper, or claude itself. The text is stored in two equivalent places that travel with the branch:

- `.io.v4rian.how-git/active-requirement` (tracked file at the branch tip)
- Body of the initial `[REQ] active-requirement: <branch>` commit on the pool branch

Auditors that spawn claude (the auto-rebase L1-L5 ladder, the post-checkout preflight) fetch the requirement via `.io.v4rian.how-git/scripts/get-active-requirement.sh <branch>` and prepend it to every claude prompt. The script tries the tracked file first (cheap), falls back to the `[REQ]` commit body (compatible with legacy branches that have the commit but not the file), and exits 0 with empty stdout when neither is present (legacy branches that predate this step — claude is invoked without the extra context).

Direct ad-hoc claude conversations that want to fill in the requirement before dispatching the allocator should compose it themselves and pass it via `--requirement` to `bin/create-pool-branch`.

## Land a feature (pool to dev)

**Connected mode** (default; PR merged via GitHub UI):

```bash
# After the PR merges via the GitHub UI, the claim-on-merge-dev workflow
# runs claim-dev-merge.sh on the remote side automatically. It amends
# the merge subject to [MERGE] pool/X into dev: vYYYY.X.Y, force-pushes
# dev, tags, and archives the pool to vault.
```

**Off-grid mode** (admin drives the merge locally):

```bash
git checkout dev
git merge --no-ff pool/n7.feature.PROJ-123-parser-rewrite -m "your body"
.io.v4rian.how-git/bin/finalize-pool-merge        # admin-gated; amends + tags + vaults
```

What happens (either mode): `bin/version --seal` computes the new tag, the merge subject is amended to the spec form, the merge commit is annotated-tagged, the archive script vaults the merged pool branch. The auto-rebase pass then walks every open pool→dev PR: for each, it updates the PR title's aspirational version, cuts a `pool/nN.reconcile.<short>` candidate branch off the new dev tip, cherry-picks the pool's commits onto it (claude L1-L5 ladder on any conflict), and **comments on the existing PR** with the reconcile candidate and a recap. The auto-rebase **never force-pushes** the developer's pool branch and **never closes or opens** any PR — admin is the sole merge decider on dev (see `feedback_how_git_never_rewrites_history`).

## Ship a release (dev to main)

**Connected mode** (admin merges manually after status checks pass):
```bash
git checkout dev && git pull
.io.v4rian.how-git/bin/init-release          # opens the release PR with body pre-filled from CHANGELOG Unreleased
# admin reviews + merges via the GitHub UI once every required check is green
# claim-on-merge-main workflow runs claim-main-release.sh on the remote side automatically
```

`bin/init-release` extracts the `## Unreleased` section from `docs/CHANGELOG.md` and pre-fills the PR body so the release report carries the curated narrative that landed cycle by cycle on dev. The `validate-pr-open.yml` workflow runs body shielding and posts the `opened-via-correct-flow` status check; the canonical merge subject `[MERGE] dev into main: vYYYY.X` is derived at claim time from `bin/version --release-tag`.

**Off-grid mode** (admin drives the full release locally):
```bash
.io.v4rian.how-git/bin/ship                  # admin-gated; refuses in connected mode
# --skip-push lets it run with no remote (LAN/air-gap):
.io.v4rian.how-git/bin/ship --skip-push
```

Equivalent to:
```bash
git checkout main && git pull --ff-only origin main      # skipped with --skip-push
git merge --no-ff dev -m "[MERGE] dev into main: $(bin/version --release-tag)"
git push origin main                                      # skipped with --skip-push
bash .io.v4rian.how-git/scripts/claim-main-release.sh --skip-pull
```

What happens (either mode): the release REUSES the existing dev tag (same code = same version). A GitHub Release object is attached via `gh release create` in connected mode (skipped in off-grid `--skip-push`). The `build-on-tag.yml` workflow builds the artifact once (at dev-tag time) and uploads it under `build/artifacts/`; the later distribution step attaches the same bytes to the Release on main promotion without rebuilding. Safety branches whose paired vaults are reachable from main get GC'd (3-gate check: vault exists + release tag exists + vault is ancestor of main).

## Find which release contains a commit

```bash
.io.v4rian.how-git/bin/release-of <commit-sha>
.io.v4rian.how-git/bin/release-of HEAD
```

Returns the earliest release tag whose ancestor set includes the commit, or `unreleased (...)` if the commit isn't on main yet.

## Heal drift

```bash
bash .io.v4rian.how-git/scripts/heal.sh           # re-set hooks path, chmod, warn on stray VERSION
bash .io.v4rian.how-git/scripts/heal.sh --dry-run # preview
```

Idempotent. Run when state has drifted (overwritten hooks config, stripped exec bits, etc.). NOT a first-time-install: the template auto-activates on first script call.

## Build a tag's artifact (workflow or local)

```bash
# Workflow path (every v* tag push runs this automatically):
gh workflow run build-on-tag.yml -f tag=v2026.0.7   # admin manual re-build

# Local path (useful for verifying build.sh changes before pushing):
git checkout v2026.0.7
TAG=v2026.0.7 bash .io.v4rian.how-git/scripts/build.sh
ls build/artifacts/                                  # output contract path

# Idempotency probe (returns 0 if output already present, 1 otherwise):
TAG=v2026.0.7 BUILD_IDEMPOTENCY_CHECK=1 bash .io.v4rian.how-git/scripts/build.sh
```

`build.sh` is the single source of truth for the build. The template
ships a project-type dispatcher (Node, Qt/CMake, template-self);
consumer projects override it in their fork with their real recipe.
Output ALWAYS lands under `build/artifacts/` so the distribution
bundle (separate from build) can find it. The workflow retries up to
eight times with exponential backoff capped at five minutes, and
skips the build entirely when the idempotency probe says output is
already present for the target tag.

## Verify the template is intact

```bash
bash .io.v4rian.how-git/scripts/verify-template.sh
```

Runs the static + behavioral invariants. Pass means the template is functional.

## Run the full offline test suite

```bash
bash .io.v4rian.how-git/framework-tests/test-lifecycle.sh           # ~30s, all simulators
bash .io.v4rian.how-git/framework-tests/test-lifecycle.sh --verbose
bash .io.v4rian.how-git/framework-tests/test-lifecycle.sh --filter M3   # one test
bash .io.v4rian.how-git/framework-tests/test-hooks.sh               # regex + version-bin structural checks
```

51+ tests cover: branch-name regex, hooks wiring, all 4 ops bins, version bin math, claim scripts, archive flow, auto-rebase + reconcile, build-on-tag workflow shape + canonical build.sh dispatch + idempotency probe, gh API mock, year rollover, full consumer scaffold simulation.

## Exercise the off-grid lifecycle against a real throwaway repo

```bash
.io.v4rian.how-git/bin/test-off-grid-e2e --help
.io.v4rian.how-git/bin/test-off-grid-e2e --dry-run --token <token> --account <owner>
.io.v4rian.how-git/bin/test-off-grid-e2e --token <token> --account <owner>
.io.v4rian.how-git/bin/test-off-grid-e2e --token <token> --account <owner> --keep
```

Operator-run end-to-end exercise of the off-grid lifecycle. The CLI creates a brand-new throwaway repo under `<owner>` via the GitHub "Use this template" API, bootstraps it from this framework's current origin (override with `--template OWNER/REPO`; the default is derived from `git config --get remote.origin.url` so there is no hardcoded owner/repo anywhere in the framework), flips it to off-grid mode, allocates `pool/n1.feature.offgrid-probe` locally, makes two commits, merges `--no-ff` into `dev` and pushes, runs `bin/finalize-pool-merge` for the local pool→dev close-up, then runs `bin/ship` for the local dev→main release. After each ceremony the script verifies the resulting subject is in the `[MERGE]` spec form, the expected tag landed, the pool was archived to `vault/`, and that no GitHub workflow fired against the post-ceremony SHA (the whole point of off-grid). Throwaway is deleted on success unless `--keep` is set.

This is the operator's escape hatch for proving the off-grid claim ceremonies work against a real GitHub repo where no workflow fires - distinct from the offline lifecycle suite which exercises mode flips and the off-grid refusal/acceptance matrix against scratch repos with no network. Because each run costs a real repo creation and deletion plus several API calls, this CLI is NOT wired into automated CI; invoke it manually when you suspect off-grid drift, when you've changed any of `bin/set-mode`, `bin/finalize-pool-merge`, `bin/ship`, `scripts/claim-dev-merge.sh`, or `scripts/claim-main-release.sh`, or when you're cutting a release.

Token + account are NEVER implicit - both must be passed explicitly even though the token would otherwise identify the actor. This is the belt-and-suspenders guard against cross-account PAT mistakes deleting the wrong repo. `--dry-run` prints every planned API call and shell command in order without executing any of them, useful for previewing a run before parting with the API budget.

## Apply branch protection rules to a new repo (one-time)

```bash
# Canonical one-shot CI setup; idempotent; safe to re-run.
.io.v4rian.how-git/bin/bootstrap-ci
.io.v4rian.how-git/bin/bootstrap-ci --check     # read-only audit
.io.v4rian.how-git/bin/bootstrap-ci --dry-run   # print every API call
```

`bootstrap-ci` runs every repo-level setup that the `Use this template` button does NOT copy:

1. Verifies Actions is enabled.
2. Verifies dev exists on origin; seeds at main's SHA if missing.
3. Applies branch protection on main + dev via `apply-repo-rules.sh`.
4. Applies Repository Rules (`pool-creations`, `safety-lockdown`, `vault-readonly`) via the same script.
5. Binds required status checks: `offline test suites` on PRs to dev and main, plus `compile`, `coverage`, `runtime`, and `opened-via-correct-flow` on PRs to dev.
6. Sets merge-commit defaults so the merge subject inherits the PR title (carries the `vYYYY.X.Y` stamp) and the merge body inherits the PR body (the macro-tone TLDR).
7. Locks merge mode to `--no-ff` merge commits only (disables squash + rebase).
8. Disables "auto-delete merged branches" so the claim flow can archive every merged pool branch to its paired `vault/` ref.
9. Sets repo topics `v4rian` and `how-git` for discoverability.
9b. Consumer cleanup: on a consumer repo (the `FRAMEWORK_REPO` marker file is absent), prunes framework-internal artifacts that arrived via `Use this template`. `.io.v4rian.how-git/framework-tests/` STAYS on the consumer because `bin/doctor --deep` uses it as an on-demand diagnostic (pool/n47); `.github/workflows/framework-self-tests.yml` (the auto-run dispatcher) IS removed because consumer CI should not fire framework-internal tests on every push; the root `README.md` is replaced with a project-stub when it still md5-matches the shipped `.io.v4rian.how-git/templates/root-readme.template.md` (i.e. the consumer hasn't customized it). On the framework source repo (marker present) this step is a no-op.

Each step probes current state via GET and only mutates when drift is detected, so the whole run is safe to re-invoke. Operator-only inputs (`ALLOCATOR_APP_ID`, `CI_BOT_APP_ID`) are surfaced as `miss` lines when absent; supply them via env before re-running:

```bash
ALLOCATOR_APP_ID=12345 CI_BOT_APP_ID=12345 .io.v4rian.how-git/bin/bootstrap-ci
```

To apply only the branch protection + ruleset half (legacy, the bootstrap-ci script delegates to this), `bash .io.v4rian.how-git/scripts/apply-repo-rules.sh` remains usable on its own.

## Branch shape cheat sheet

| Pattern | Created by | Touchable? |
|---|---|---|
| `main` | admin merges only | no direct commits; via PR from dev only (--no-ff) |
| `dev` | admin merges only | no direct commits; via PR from pool/* (--no-ff) |
| `pool/nN.kind.short-name` | allocator endpoint (or admin) | yes by dev who owns it; merge via PR into dev |
| `safety/nN.kind.short-name` (active) | allocator (same SHA as pool at creation) | read-only; immutable for the life of the branch. On the 3-gate GC pass at main release, **archived** to `safety/vYYYY.MAIN/nN.kind.short-name` (pool/n48) instead of deleted — branches are cheap pointers and the archived anchor is the receipt of "this n-counter's work was sanctioned for this release cycle". Both layouts are covered by the safety-lockdown ruleset. |
| `vault/vYYYY.MAIN/nN.kind.short-name` | archive flow (post-merge) | **read-only frozen**: repository rule blocks all writes. Major prefix groups every vault from the same release cycle so `refs/heads/vault/v2026.0/` reveals "what landed in cycle 0 of 2026" at a glance. Legacy flat `vault/nN.kind.short-name` from pre-pool/n44 repos still works — both layouts are matched by the ruleset and discovered by the 3-gate GC. |

`kind` values: feature, fix, r&d, refactor, reconcile, doc.

Short-name rule: `[a-z0-9][a-z0-9-]*` (hyphens only, no underscores).

## When things go wrong

- **Rebase conflicts on auto-rebase pass:** the reconcile flow cuts `pool/nN.reconcile.<short>` off the new dev tip + claude attempts L1-L5 strategies on each conflicting cherry-pick. On any outcome it **comments on the existing PR** with the recap and leaves both the original pool branch and the original PR untouched. Admin reviews and decides: merge the reconcile candidate locally (`git checkout dev && git merge --no-ff pool/nN.reconcile.<short> -m "[MERGE] ... into dev: <version>"` then push), tag the developer for changes, or close the PR to reject. If conflicts remained unresolved after L5, the partial reconcile branch is pushed for review and the comment lists every attempted strategy. Dev may also push their own resolution to the pool branch at any time before admin review.
- **Stray VERSION file at repo root** (from a pre-redesign checkout): heal warns, you delete (`rm VERSION`). Tags are the seal now.
- **Tag conflict** (claim-dev-merge says "tag exists"): a previous claim partial-failed. Drop the local tag (`git tag -d vYEAR.SERIES.DEV`) and re-run.
- **Dev rewritten under you:** auto-rebase detects orphan base via `git merge-base --is-ancestor` and switches to `git rebase --onto origin/dev <old-base> <pool>` automatically.
- **Push-triggered claim run never completed:** the `claim-on-merge-dev.yml` / `claim-on-merge-main.yml` workflows each include an in-workflow exponential-backoff retry loop (8 attempts, capped at 5 minutes between attempts, inside a 4320 minute job timeout), so transient GitHub API or network failures auto-recover. If a run still fails past the ceiling, an admin can re-fire the same workflow via `gh workflow run claim-on-merge-dev.yml` (or `claim-on-merge-main.yml`) from the repo. The workflow_dispatch path is gated on the dispatcher holding the admin role per the collaborators permission API; the canonical claim script is idempotent (tag-exists check on dev, no-new-tag on main) so re-runs never double-tag.

## File map

```
.io.v4rian.how-git/
├── MODE                  current mode (`connected` or `off-grid`); committed to the repo
├── bin/
│   ├── version           canonical version utility (3-segment, merge-count math)
│   ├── status            current-state snapshot (includes mode)
│   ├── doctor            template health verification (includes MODE value sanity)
│   ├── set-mode          flip between connected and off-grid (admin-gated)
│   ├── ship              off-grid dev to main release (refuses in connected mode)
│   ├── finalize-pool-merge  off-grid pool to dev close-up (refuses in connected mode)
│   ├── release-of        commit to release-tag lookup
│   ├── bootstrap-ci      connected-mode repo-level CI setup; idempotent; --check / --dry-run modes
│   ├── create-pool-branch  local CLI wrapper that dispatches the allocator workflow
│   ├── init-pool-merge   connected-mode CLI for opening a pool/* to dev PR
│   ├── init-release      connected-mode CLI for opening a dev to main release PR (body from CHANGELOG)
│   └── test-off-grid-e2e operator-run e2e: real throwaway repo + full off-grid lifecycle
├── scripts/
│   ├── claim-dev-merge.sh           post-merge dev claim (tag + archive + auto-rebase)
│   ├── claim-main-release.sh        post-merge main release (Release object + safety GC)
│   ├── archive-pool-branch.sh       rename pool/X to vault/X on origin
│   ├── auto-rebase-pools-after-dev-merge.sh   produce pool/nN.reconcile.<short> candidate + comment on existing PR (never force-pushes, never closes/opens PRs)
│   ├── build.sh                     canonical project-type-dispatching build script (Node / Qt-CMake / template-self); consumers override with real recipes
│   ├── distribute-internal.sh       PLACEHOLDER, project fills in
│   ├── distribute-public.sh         default = gh release upload; extras placeholder
│   ├── open-pr.sh                   opens/updates PR with auto-derived title + body
│   ├── validate-pr-open.sh          canonical PR-open validator (called by validate-pr-open.yml)
│   ├── apply-repo-rules.sh          one-time branch protection setup
│   ├── verify-template.sh           invariant checks
│   ├── test-off-grid-e2e.sh         operator-run off-grid lifecycle e2e against a real throwaway repo
│   └── heal.sh                      drift repair
├── githooks/                         active hooks (core.hooksPath)
│   ├── pre-commit                   scrubs em/en-dashes from staged files
│   ├── prepare-commit-msg           smart auto-fix layer (dash scrub + tag derivation + bullet rewrite)
│   ├── commit-msg                   subject length guardrail (8-100 chars; [MERGE]+[REQ] exempted to 140)
│   ├── pre-push                     branch-name regex guardrail (regex-only since Step 2)
│   ├── post-checkout                branch-name warning + snapshot-preflight audit
│   └── post-merge                   auto-claim on dev/main
└── .github/workflows/                CI (consumer can add their own)
    ├── claim-on-merge-dev.yml       GitHub-side claim-dev-merge dispatcher
    ├── claim-on-merge-main.yml      GitHub-side claim-main-release dispatcher
    ├── allocate-pool-branch.yml     admin-only allocator that atomically creates pool/X + safety/X
    ├── ci-dispatch.yml              layered CI dispatcher; fans out one check per script under ci/{tests,audits}/<trigger>/
    ├── validate-pr-open.yml         on pull_request to dev/main: shield, amend, post opened-via-correct-flow check
    ├── seed-dev-on-main-create.yml  seed dev branch at repo birth from template
    └── build-on-tag.yml             builds via canonical scripts/build.sh on every v* tag (and on workflow_dispatch); retry + idempotency probe; distribution is a separate bundle
```

## Layered CI hooks (consumer-extendable)

Two directories feed the `ci-dispatch.yml` workflow:

- **usr layer**, `ci/` at the repo root, is consumer-owned. Drop any `.sh` under `ci/tests/<trigger>/` or `ci/audits/<trigger>/` and it runs as a separate status check on the named trigger.
- **sys layer**, `.io.v4rian.how-git/ci/`, ships with the framework and runs ONLY when the FRAMEWORK_REPO marker is present.

| Trigger dir | Fires on |
|---|---|
| `push` | every push to any branch |
| `pr-open` | `pull_request` opened, synchronize, or reopened, targeting dev or main |
| `pr-merge-dev` | `pull_request` closed-merged into dev |
| `pr-merge-main` | `pull_request` closed-merged into main |
| `tag` | tag push matching `v*` |

The script's basename minus the `.sh` extension is the GitHub check context name. Any file named `required.*` is bound as a required status check on PRs to dev by `bin/bootstrap-ci` (added to branch protection automatically). Anything else is advisory.

The framework's own audit + test gates live under `.io.v4rian.how-git/ci/` as `required.commit-audit.sh`, `required.compile.sh`, `required.coverage.sh`, `required.runtime.sh`, and `required.offline-test-suites.sh` so the dispatcher posts them under the names `required.commit-audit`, `required.compile`, `required.coverage`, `required.runtime`, and `required.offline-test-suites`. Branch protection on dev binds these five names plus `opened-via-correct-flow` (posted by `validate-pr-open.yml`). The `required.commit-audit` gate applies the `git-commit-audit` lens (atomicity, title format, body shape, bullet style, fabrication detection, file hygiene, branching, merge format) to every commit in the push range; under `LIFECYCLE_TEST_MODE=1` it canned-passes without a `claude -p` call, and in production it falls back to canned PASS when the `claude` CLI is unavailable so a missing client never blocks pushes.
