# how-git

**Template repository for the v4rian way of doing git.**

A minimal, production-safe branching model built around stability,
traceability, parallel development, and atomic version claiming on PR
merge. Clone the template and push — no install step, no `make
setup`, no CI required. Hooks auto-activate on first script use;
version bumping happens via in-repo scripts (`claim-dev-merge.sh`,
`claim-main-release.sh`).

The template's working content lives under the hidden namespace
directory `.io.v4rian.how-git/` so consumer projects bootstrapped from
this template have a clean repo root for their own code, with only
`.gitignore` and the generated `VERSION` file at top level.

---

## What's in the box

```
<repo-root>/
├── .gitignore                              ← stays at root; git reads from here
├── README.md                               ← repo root README for first-time visitors
├── .github/workflows/                      ← 7 CI dispatchers (see below)
└── .io.v4rian.how-git/                     ← every template file lives here
    ├── README.md                           ← you are here
    ├── LICENSE
    ├── docs/
    │   ├── Git_Strategy.md                 ← THE strategy (read this first)
    │   ├── IMPLEMENTATION_HANDOFF.md       ← for engineers/agents building infra
    │   ├── repo-config.md                  ← branch protection / Repository Rules (optional)
    │   ├── RUNBOOK.md                      ← operator cheat sheet
    │   ├── CONTRIBUTING.md                 ← contributor flow + commit conventions
    │   └── CHANGELOG.md                    ← human-readable companion to the tag chain
    ├── githooks/                           ← core.hooksPath points here
    │   ├── pre-commit                      ← scrubs em/en-dashes from staged files
    │   ├── prepare-commit-msg              ← smart auto-fix layer (dash scrub + tag derivation + bullet rewrite)
    │   ├── commit-msg                      ← 8-100 char subject length guardrail
    │   ├── pre-push                        ← branch-name regex guardrail (regex-only since Step 2)
    │   ├── post-checkout                   ← warns on local non-conforming names
    │   ├── post-merge                      ← AUTO-claims version when `git pull` brings a new merge onto dev / main (the automator)
    │   └── README.md
    ├── scripts/                            ← 13 maintenance scripts
    │   ├── _lib.sh                         ← shared helpers (ensure_hooks_path); sourced by the others
    │   ├── apply-repo-rules.sh             ← applies branch protection via gh CLI (optional)
    │   ├── archive-pool-branch.sh          ← vaults a merged pool branch to vault/nN.*
    │   ├── auto-rebase-pools-after-dev-merge.sh   ← L1-L5 reconcile ladder for sibling pools
    │   ├── build.sh                        ← canonical project-type-dispatching build script (consumer overrides for real recipes)
    │   ├── claim-dev-merge.sh              ← canonical dev-merge claim: tag + archive + auto-rebase
    │   ├── claim-main-release.sh           ← canonical main-release claim: tag + (Release) + GC safety
    │   ├── distribute-internal.sh          ← PLACEHOLDER; project fills in
    │   ├── distribute-public.sh            ← default: gh release upload
    │   ├── heal.sh                         ← repair script: re-set core.hooksPath, re-chmod
    │   ├── open-pr.sh                      ← opens or updates a PR for the current branch (idempotent)
    │   ├── validate-pr-open.sh             ← canonical PR-open validator (called by validate-pr-open.yml)
    │   └── verify-template.sh              ← end-to-end test of the template
    ├── bin/                                ← 12 operator binaries
    │   ├── version                         ← canonical version utility (3-segment, merge-count math)
    │   ├── status                          ← current-state snapshot
    │   ├── ship                            ← one-command dev to main release
    │   ├── release-of                      ← commit to release-tag lookup
    │   ├── changelog                       ← markdown release notes from tag history
    │   ├── preview-merge                   ← safe dry-run of a pending PR merge
    │   ├── queue                           ← open PR overview with conflict prediction
    │   ├── doctor                          ← one-shot template health check
    │   ├── bootstrap-ci                    ← one-shot repo-level CI setup (idempotent, --check / --dry-run)
    │   ├── create-pool-branch              ← local CLI wrapper around the allocator workflow
    │   ├── init-pool-merge                 ← local CLI for opening a pool/* to dev PR (validate-pr-open amends)
    │   └── init-release                    ← local CLI for opening a dev to main release PR (body pre-filled from CHANGELOG)
    ├── skills/                             ← 12 git-* skills (full lens stack)
    │   └── git-{commit,compile,coverage,history-preservation,history-rewrite,merge,runtime,shuttle,snapshot-preflight,snapshots,strategy,token-discovery}-audit/
    ├── rulesets/                           ← Repository Ruleset JSON definitions
    │   ├── pool-creations.json             ← pool/* creation pinned to the allocator workflow identity
    │   └── safety-lockdown.json            ← safety/* create/update/delete pinned to allocator + claim
    ├── services/branch-creator/
    │   └── README.md                       ← historical spec for the standalone allocator endpoint
    └── test/
        ├── test-hooks.sh                   ← exercises the local hooks
        └── test-lifecycle.sh               ← offline tests covering hooks + scripts + CI + full cycle
```

**Seven CI dispatchers ship under `.github/workflows/`** (added incrementally over `pool/n6`, `pool/n11`, `pool/n13`, `pool/n26`, `pool/n32`, `pool/n33`, `pool/n35`, `pool/n51`):
`claim-on-merge-dev.yml`, `claim-on-merge-main.yml`, `allocate-pool-branch.yml`, `ci-dispatch.yml`, `validate-pr-open.yml`, `seed-dev-on-main-create.yml`, `build-on-tag.yml`. They are thin acceptance dispatchers that invoke the in-repo scripts; the model itself runs on git alone and the workflows degrade gracefully on other forges. `ci-dispatch.yml` is the layered CI dispatcher that fans out a separate status check per shell script under `ci/{tests,audits}/<trigger>/` at the repo root (consumer-owned usr layer) and `.io.v4rian.how-git/ci/{tests,audits}/<trigger>/` (framework-owned sys layer, gated on the FRAMEWORK_REPO marker). The framework's own pr-open audit + test gates live as sys-layer `required.compile.sh`, `required.coverage.sh`, `required.runtime.sh`, and `required.offline-test-suites.sh` files; the `required.*` filename prefix marks each as a required status check on PRs to dev, bound automatically by `bin/bootstrap-ci`. The two `claim-on-merge` workflows accept both their primary `push` trigger and a manual `workflow_dispatch` trigger gated on the dispatching actor being a repo admin (the emergency re-claim escape when the automatic push run does not complete); each wraps the canonical claim script invocation in an exponential-backoff retry loop with a 4320 minute job timeout. Retries ride out transient API or network failures, but the workflow exits failed once attempts are exhausted so persistent failures still surface. `build-on-tag.yml` invokes the canonical `scripts/build.sh` on every `v*` tag push (and on `workflow_dispatch` for admin re-builds), with the same exponential backoff retry shape and a `BUILD_IDEMPOTENCY_CHECK` probe that short-circuits when output for the target tag is already present; distribution is a separate bundle and is not wired in here. `validate-pr-open.yml` fires on every PR opened, edited, or synchronize event into dev or main and runs the canonical `validate-pr-open.sh` script that auto-derives the title from `bin/version`, runs the shared auto-fix pass over the body, embeds the workflow signature, and posts the `opened-via-correct-flow` status check. The original "No `Makefile`" claim still holds: the template is tooling-minimal and every operation is either a bin or a script.

---

## The v4rian way in one paragraph

Every working branch is paired at birth with a `safety/` anchor branch
that captures the exact commit it was branched from — atomically, by
the repository itself, never by a developer. Working branches live
under the `pool/` namespace (e.g. `pool/n7.fix.PROJ-123-token_leak`)
and their paired anchors mirror the suffix under `safety/`. Versions
follow `v{YYYY}.{SERIES}.{DEV}` and are claimed
atomically by whichever PR merges first. Dev merges tag internally;
main merges promote to public Releases. Safety branches are deleted
on the release event that includes their work, but abandoned R&D
anchors live forever as institutional memory. The full design,
rationale, and invariants are in [`docs/Git_Strategy.md`](docs/Git_Strategy.md).

---

## Modes: connected and off-grid

The framework runs in two modes recorded in `.io.v4rian.how-git/MODE`:
`connected` (default) and `off-grid`. The operator-facing workflow is
identical in both. An allocator produces an atomic pool plus safety
pair at the dev tip, pool branches merge into dev via PR with a claim
ceremony amending the merge subject and tagging the dev tip, dev
merges into main with a release ceremony tagging the release and
archiving the pool refs to vault. Only the under-the-hood
implementation differs. Connected mode dispatches GitHub workflows
that POST to the Git Data API and `gh pr create` against the remote.
Off-grid mode invokes the same canonical scripts locally so they
mutate refs in the working copy via `git update-ref --stdin`,
`git commit-tree`, and the post-merge hook. Flip between modes with
`bin/set-mode connected` or `bin/set-mode off-grid`.

---

## Portability

The only owner/repo binding in this framework is `git config --get remote.origin.url`. Every script that needs to know "what repo is this?" derives the answer at runtime from that single source. There are no hardcoded owner/repo strings in framework code, defaults, doc strings, or test assertions. Consequence: when the framework moves to a different org, the operator runs `git remote set-url origin <new-url>` once and every internal mechanism keeps working; nothing else needs to be found and updated. The lifecycle suite enforces this with a check that fails if any framework-internal file embeds an `OWNER/REPO` literal pinned to a specific account.

---

## Using this template

The template works out of the box — no install step. Git hooks
auto-activate the first time you run any in-repo script (`open-pr.sh`,
`claim-dev-merge.sh`, `claim-main-release.sh` source `scripts/_lib.sh`
and call `ensure_hooks_path` on startup), `VERSION` is lazily
initialized from the current calendar the first time a claim script
needs it, and git preserves executable bits via its index so nothing
needs `chmod`.

### Option A — GitHub template repo (recommended)

1. On GitHub, click **Use this template → Create a new repository**
2. Clone the new repo locally
3. Customize `.io.v4rian.how-git/docs/` as needed for your project
4. Push to your remote — hooks will auto-activate on your first
   `bash .io.v4rian.how-git/scripts/open-pr.sh` (or any other in-repo script)

### Option B — Manual clone

The framework is org-agnostic, so the clone URL below is a placeholder. Use the actual clone URL of wherever this framework lives (the GitHub "Code" button on the framework repo gives the right value).

```bash
git clone <framework-source-url> my-new-repo
cd my-new-repo
rm -rf .git
git init
# customize as needed
git add .
git commit -m "chore: bootstrap from how-git template"
git remote add origin <your-remote>
git push -u origin main
# hooks activate on first script run (open-pr.sh, claim-*.sh)
```

### Heal: `bash .io.v4rian.how-git/scripts/heal.sh`

`scripts/heal.sh` is a **repair** script, not a first-time install.
Run it when state has drifted — `core.hooksPath` was overwritten, a
script lost its executable bit through a tool that didn't preserve
mode, or `VERSION` is missing on a repo that should have one.
Idempotent and safe to run repeatedly. A fresh clone of the template
never needs it. `--dry-run` shows what would change without mutating.

### Opening PRs — `bash .io.v4rian.how-git/scripts/open-pr.sh`

`scripts/open-pr.sh` opens (or updates) a PR from the current branch
following the v4rian model. It is **idempotent** — re-running it on the
same branch PATCHes the existing PR's title + body instead of creating
a duplicate.

Auto-derives:

| Field   | From                                                                  |
|---------|-----------------------------------------------------------------------|
| target  | `pool/*` → `dev`; `dev` → `main`                                      |
| version | `bin/version --next-dev` for pool→dev; `bin/version --release-tag` for dev→main (same code = same version, so release reuses dev tag) |
| title   | `[TAG] <version>: <subject of latest commit>` (pool→dev) or `[MERGE] dev into main: <release>` (dev→main) |
| body    | `git log --reverse origin/<base>..HEAD` (or `--body-file <path>` to override) |

Token resolution order (first wins): `$GH_TOKEN`,
`$CREATE_POOL_BRANCH_TOKEN`, `gh auth token` (if gh installed),
`~/.gcm/store/git/https/github.com/<account>.credential`. The
`--doctor` flag prints which deps + token sources are available and
exits without calling the API.

### Claiming a version — `bash .io.v4rian.how-git/scripts/claim-dev-merge.sh` / `claim-main-release.sh`

Under the v4rian model the version is **claimed by whichever PR merges
first**, not pre-allocated at branch creation. The claim is a git
operation, not a CI operation. Two scripts handle it.

Both scripts read every dev version derivation through `bin/version`
(the single authority for `vYEAR.SERIES.DEV`); neither computes the
math itself. `claim-dev-merge.sh` calls `bin/version --seal` for the
tag to land on the just-merged commit, and `claim-main-release.sh`
calls `bin/version --release-tag` for the release tag (which reuses
the latest dev tag because same code = same version). Adding or
changing version components is therefore a one-place edit in
`bin/version`; consumers never drift.

| When | Run this | What it does |
|---|---|---|
| After a `pool/*` PR merges into `dev` | `bash .io.v4rian.how-git/scripts/claim-dev-merge.sh` | reads VERSION, tags the current dev HEAD with that version (internal tag, no Release), bumps `dev_counter`, force-adds VERSION (since `/VERSION` is `.gitignore`d), commits, pushes the tag and dev |
| After `dev` merges into `main` | `bash .io.v4rian.how-git/scripts/claim-main-release.sh` | reads VERSION, strips `-b.X` to get the release tag, tags main HEAD with that, **optionally** creates a GitHub Release via API if a token is available, GCs `safety/` anchors whose paired `pool/` branch is reachable from `origin/dev`, bumps `main_counter` + resets `dev_counter`, commits, pushes |

Both scripts refuse to run on a dirty tree, refuse to claim a tag that
already exists (so re-running after a partial failure is safe), and
support `--dry-run` to preview.

Token resolution for the optional GitHub Release in `claim-main-release.sh`
matches `open-pr.sh`'s chain. If no token is reachable, the git tag is
still pushed and is canonical; only the GitHub Release sidecar is
skipped.

### Building on every tag: `.github/workflows/build-on-tag.yml` + `scripts/build.sh`

Every `v*` tag push triggers `build-on-tag.yml`, which checks out the
tagged commit and invokes `.io.v4rian.how-git/scripts/build.sh`. The
script is the **single source of truth** for the build; consumer
projects override it in their fork with their actual recipe (npm run
build, cmake + ninja, xcodebuild, cargo, etc.) and the workflow stays
unchanged.

`build.sh` dispatches by project markers in the repo root:

| Marker present | Behaviour |
|---|---|
| `package.json` | `npm install --no-audit --no-fund` then `npm run build` if a build script exists, then best-effort tar of `dist/`, `build/`, `out/`, or `lib/` into the artifact dir |
| `CMakeLists.txt` | Prints a consumer-must-override banner and exits non-zero (Qt / C++ recipes vary too widely for a meaningful default) |
| Neither (template itself) | Emits a small text summary of the tag for the workflow to upload |

**Output contract:** every artifact lands under `./build/artifacts/`
at the repo root, with filenames embedding `$TAG`. The directory IS
the API between this workflow and the (later) distribution bundle that
attaches the same artifacts to a GitHub Release.

**Triggers:** `push: tags: ['v*']` (primary, event-driven) and
`workflow_dispatch` with a `tag` input for admin manual re-builds of a
specific historical tag.

**Retry + idempotency:** the workflow wraps `build.sh` in the same
exponential backoff retry as the audit workflow (eight attempts, five
second base, five minute cap, seventy two hour envelope). Before
building it asks `build.sh` (with `BUILD_IDEMPOTENCY_CHECK=1`) whether
output for the target tag is already present at the contract path; if
so, the build step is skipped and the workflow exits 0. Distribution
is deliberately out of scope here so the same artifact built at dev
tag time is reused unchanged when the release promotes to main.

### Verifying the template — `bash .io.v4rian.how-git/scripts/verify-template.sh`

`scripts/verify-template.sh` exercises the template end-to-end on a
separate throwaway repo (never the template repo itself). Default mode
uses GitHub's `POST /repos/{template}/generate` API (the real "Use
this template" path), tests the deliverable on the source's default
branch. `--from-branch <ref>` simulates `/generate` from a non-default
branch — useful for pre-merge testing.

Static invariants always run: root layout, executable bits, auto-config
of `core.hooksPath` on first script call, `heal.sh` restores state
after drift, `test-hooks.sh` passes 27/27, both claim scripts are
present + executable.

Optional `--with-bump-cycle` flag adds five more invariants that run
the canonical `claim-dev-merge.sh` + `claim-main-release.sh` scripts
on the throwaway and verify the tags + Release + VERSION bumps land
correctly — no CI polling. Then deletes the throwaway (or `--keep`).

---

## Reading order for adopters

1. **[`docs/Git_Strategy.md`](docs/Git_Strategy.md)** — the model, the
   invariants, the rationale. Internalize this before changing anything.
2. **[`docs/IMPLEMENTATION_HANDOFF.md`](docs/IMPLEMENTATION_HANDOFF.md)** —
   if you're standing up the infrastructure (hooks, allocator,
   branch protection), the milestone breakdown lives here.
3. **[`docs/repo-config.md`](docs/repo-config.md)** — the server-side
   gates (branch protection, Repository Rules) that make the model
   enforceable rather than aspirational.

---

## What's complete in this skeleton vs. what you'll build

| Component | Status |
|---|---|
| Local hooks (`pre-commit`, `prepare-commit-msg`, `commit-msg`, `pre-push`, `post-checkout`, `post-merge`) | ✅ Ready to use; auto-activate on first script run |
| Layered CI dispatcher (`ci-dispatch.yml` → one check per `ci/{tests,audits}/<trigger>/*.sh` script; sys-layer `required.compile`, `required.coverage`, `required.runtime`, `required.offline-test-suites` required on PRs to dev) | ✅ Ready to use; deterministic enforcement on every PR to dev |
| Hook tests | ✅ Ready to use (`bash .io.v4rian.how-git/framework-tests/test-hooks.sh`) |
| Version claim scripts (`claim-dev-merge.sh`, `claim-main-release.sh`) | ✅ Ready to use |
| PR open / update script (`open-pr.sh`) | ✅ Ready to use |
| PR-open validate workflow (`validate-pr-open.yml` → `opened-via-correct-flow` required check) | ✅ Ready to use; auto-amends title and body, posts the status check |
| Init CLIs (`init-pool-merge`, `init-release`) | ✅ Ready to use; dispatch `gh pr create` with the right base and body skeleton |
| End-to-end template verification (`verify-template.sh`) | ✅ Ready to use |
| Heal script (`heal.sh`) | ✅ Ready to use |
| `create-pool-branch` CLI + allocator workflow | ✅ Ready to use; admin GitHub Actions allocator pairs pool/* and safety/* atomically |
| `bootstrap-ci` one-shot repo setup (Actions, dev seed, branch protection, Repository Rules, required status checks, merge-commit defaults, merge-mode lock, auto-delete disable, topics) | ✅ Ready to use; idempotent; `--check` audits, `--dry-run` prints API calls |
| Branch-creator service (legacy spec) | 📋 Superseded by the in-repo allocator workflow; the spec is retained for historical reference |
| Repository Rules / branch protection script | 📋 Template — needs your repo names |
| JIRA → endpoint integration | ❌ Out of scope (separate work) |

---

## License

MIT — see [`LICENSE`](LICENSE).

---

## Credit

The "v4rian way" is named for the brittle reality that **a single point
of failure is one merge away** without disciplined anchoring, version
claiming, and server-side enforcement. This template encodes one
opinionated answer to that problem. It is not the only answer; it is
the answer that fits the design constraints documented in
`Git_Strategy.md`.
