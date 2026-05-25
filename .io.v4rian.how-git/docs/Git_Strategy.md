# Git Strategy

A minimal, production-safe branching model built around stability, traceability,
parallel development, and **atomic version claiming on PR merge**.

---

## Branch Structure

```
main
└── dev
    └── pool/nN.{feature|fix|r&d|refactor|reconcile|doc}.[sprintX-][JIRA-]short-name

# (safety/ branches are ephemeral pre-merge snapshots — see Safety Branches)
```

## Release Flow

1. Working branch (`pool/nN...`) → PR → `dev` (via `--no-ff`)
   - Post-merge hook fires `claim-dev-merge.sh`
   - `bin/version --seal` computes `vYEAR.SERIES.DEV` (from merge counts)
   - Annotated tag created on the merge commit; pushed to origin
   - (No commit written on dev — tags are the seal, no chore-version commit)
2. Stabilize in `dev`
3. PR `dev` → `main` (via `--no-ff`, REQUIRED for merge countability)
   - Post-merge hook fires `claim-main-release.sh`
   - Release REUSES the existing dev tag (same code = same version)
   - GitHub Release object created/attached to that tag via `gh release create`
   - `build-on-tag.yml` workflow ships the built artifact to internal + public channels
4. Deploy

## Stability Model

| Branch         | Deploy | CI Required             | Lifetime  |
|----------------|--------|-------------------------|-----------|
| `main`         | Yes    | Yes                     | Permanent |
| `dev`          | No     | Yes                     | Permanent |
| `pool/nN.…`     | No     | Encouraged              | Temporary |
| `safety/nN.…`  | No     | N/A (read-only snapshot)| Ephemeral |

### `main` — Production

- Always stable and deployable
- No direct commits
- Only merges from `dev` via PR
- Merge commit IS the released version
- **Every dev→main merge produces a GitHub Release** (e.g., `v2026.0.5`) — reusing the existing dev tag, not creating a new one

### `dev` — Integration / Nightly

- Integration branch for completed work
- Weekly builds
- No direct commits
- PR required with CI passing (tests, build)
- **Every merge produces a version tag; tags are internal and never promoted to public releases**

### Working branches — `pool/nN.…`

- Format: `pool/nN.(feature|fix|r&d|refactor|reconcile|doc).[sprintX-][JIRA-]short-name`
- `nN` is a **creation sequence number** allocated by the repo's
  branch-creation endpoint — atomic on the server, no collisions
- **Created via the repo's branch-creation endpoint** (see Branch
  Creation below), not directly by developers
- Merged back via PR into `dev`
- Deleted after merge

The trailing short-name has three parts:

| Segment              | Required | Format                | Notes                              |
|----------------------|----------|-----------------------|------------------------------------|
| `sprintX-`           | Optional | `sprint` + integer    | Sprint context, e.g. `sprint4-`    |
| `JIRA-`              | Optional | `PROJ-NNN-`           | Uppercase project key + ticket ID  |
| `short-name` | Required | `[a-z0-9][a-z0-9-]*` | Hyphens only; lowercase  |

Examples:
- `pool/n3.feature.parser-rewrite`
- `pool/n3.feature.sprint4-parser_rewrite`
- `pool/n7.fix.PROJ-123-token_leak`
- `pool/n12.r&d.sprint5-PROJ-456-embedding_cache`
- `pool/n4.refactor.config-module`

### Safety Branches — Immutable Work Anchors

Each `pool/` branch has a paired `safety/` branch created **at the same
moment, atomically**, by the branch-creation endpoint. Safety is the
immutable record of where the work began — the anchor that survives
even if the working branch is force-pushed, accidentally deleted, or
otherwise destroyed.

- Format: `safety/nN.kind.short-name` — **identical to the paired dev
  branch after the scope prefix**
- Both branches point at the same commit at creation time (current
  `dev` HEAD)
- Created **atomically** with the dev branch; if either creation fails,
  the endpoint rolls back and the caller is told (see Branch Creation)
- **Read-only** — no commits land on safety, no PRs target it, no
  force-pushes
- Lifetime: kept until the next `dev → main` merge that releases the
  paired work. At that moment the work is sealed into a public release
  tag — the anchor's job is done — and the repo deletes the safety
  branch as part of the release CI.
- **Abandoned-work exception.** If the paired `pool/…` branch is never
  merged (work dropped, R&D dead end, redirected), the safety branch
  is **never deleted**. This is deliberate — abandoned exploration
  often becomes valuable reference material later, and the safety
  branch is the cheapest possible institutional memory of "what was
  tried." Cost is near-zero; intent is preservation.

What safety protects against:

- The working branch is force-pushed or rebased into an unrecoverable
  state → `safety/…` still holds the anchor commit
- The working branch is accidentally deleted before merge → `safety/…`
  proves what was branched from
- A merge into `dev` is later determined to be defective → the diff
  between `safety/…` and the merge commit is a clean audit record of
  exactly what changed

Safety branches are about eliminating the **single point of failure**
that a sole working branch represents — without them, a force-push or
delete is unrecoverable without reflog archaeology.

`main` is protected separately by its tag history — every prior release
tag is itself a rollback target, so no safety branch is created on
`dev → main` merges by default.

### Branch Creation

Developers **do not create branches on the remote**. New `pool/` branches
(and their paired `safety/` branches) are provisioned by a
**synchronous branch-creation endpoint owned by the repository**. The
endpoint encapsulates all `nN` allocation logic and is the only non-CI
identity the server's branch-creation restriction trusts.

The endpoint accepts a request specifying:

- Kind (`feature` / `fix` / `r&d` / `refactor`)
- Optional sprint number
- Optional JIRA ticket reference
- Short descriptive name (slug)

On invocation it:

1. Atomically allocates the next available `nN`
2. **Atomically creates both branches** from current `dev` HEAD:
   - `pool/nN.kind.…` (the working branch)
   - `safety/nN.kind.…` (the immutable anchor)
3. Returns **synchronously** with the new branch name on success, or a
   structured error on failure

**Synchronous-with-confirmation is required** — if branch creation
fails (allocator down, permission issue, transient git error, partial
pair creation), the caller must know immediately. A dev who's been
told "your branch is ready" only to find nothing there has no recovery
path; the failure must surface at the moment of request.

If creating the pair partially fails (e.g. `pool/…` succeeds but
`safety/…` fails), the endpoint **rolls back the partial state** — the
operation is all-or-nothing.

Callers of the endpoint include:

- **JIRA** — triggers a request when a task enters the active sprint;
  surfaces the success/error in the ticket
- **CLI** (e.g., `create-pool-branch`) — for spikes, admin actions, or
  workflows outside JIRA; dispatches the in-repo allocator workflow and
  watches the resulting run
- **Other automations** — security advisories, scheduled refactor work,
  etc.

JIRA is one consumer, not the source of truth. **The repo owns branch
naming and number allocation regardless of who is asking.** This keeps
the scheme portable: replacing JIRA with another tracker, or running
without a tracker at all, requires no change to the allocator.

Implementation: a GitHub App (or equivalent on other forges) with
`contents:write` scope. The synchronous contract is most easily met by
exposing the App as an HTTP endpoint backed by a short-lived
workflow_dispatch, or by using a small custom service. Repository Rules
restrict everyone else from creating branches matching `pool/*` or
`safety/*`, so the App is the only viable path to a remote branch.

Developers may create branches **locally** for spikes; the `pre-push`
hook plus the server-side restriction will reject any attempt to push
a new remote branch from a developer identity. Pushing commits to an
existing remote branch is unrestricted.

---

## Versioning

Three-segment format, derived deterministically from git merge counts:

```
v{YYYY}.{SERIES}.{DEV}
```

- `YYYY` — 4-digit year, derived from the calendar at compute time
- `SERIES` — count of main merges this year (on main's first-parent line). Increments implicitly on every dev → main release merge. Resets on year rollover. Nothing is manually bumped.
- `DEV` — count of dev merges in the current cycle (since the last main merge, or since year start if no main release has happened yet). In cycle 0 (`SERIES == 0`) the count is 1-indexed because there is no `v.0.0` anchor; in cycle 1+ the count is 0-indexed because the main release itself acts as the `v.X.0` anchor.

**Same code = same version.** Every value is derived deterministically by counting first-parent merges. A pool→dev merge tags the merge commit with `vYYYY.SERIES.(NEXT_DEV)` where `NEXT_DEV = count + 1` in cycle 0 or `NEXT_DEV = count` in cycle 1+. When that work later flows to main via `dev → main --no-ff`, the release REUSES the same tag — no new git tag is created, just a GitHub Release object attached to the existing tag. Two binary-identical builds never carry different versions.

Examples:

```
v2026.0.1    ← first pool→dev merge of 2026 (cycle 0, 1-indexed start)
v2026.0.2    ← second pool→dev merge
v2026.0.7    ← seventh pool→dev merge
              dev → main release happens — REUSES v2026.0.7. SERIES bumps
              to 1 implicitly because main merge count incremented.
v2026.1.0    ← first pool→dev merge after the release (cycle 1, 0-indexed
              start because v2026.1.0 is the anchored start of cycle 1)
v2026.1.1    ← next pool→dev merge in cycle 1
v2027.0.0    ← first state of 2027 (year rollover; clean reset)
```

### Component sources

| Component | Source                                                                                  | When it changes |
|-----------|-----------------------------------------------------------------------------------------|-----------------|
| `YYYY`    | `date -u +%Y` at compute time                                                           | Year rollover (Jan 1 UTC) |
| `SERIES`  | `git log main --first-parent --merges --since=YYYY-01-01 \| wc -l`                       | Every dev → main release merge |
| `DEV`     | `git log dev --first-parent --merges --since=YYYY-01-01 [--not main] \| wc -l` + offset | Every pool → dev merge (offset = +1 in cycle 0, +0 in cycle 1+) |

`bin/version` computes all three; every other tool calls it (`claim-dev-merge.sh`, `claim-main-release.sh`, `open-pr.sh`, `auto-rebase-pools-after-dev-merge.sh`).

### Claim-on-Merge Semantics

Because work happens in parallel and completion order can't be predicted, **the version is claimed by whichever PR merges first** — not assigned at branch creation. Working branches carry an `nN` sequence number, not a version.

Flow for `pool/...` → `dev`:

1. PR is approved and merged into `dev` (--no-ff produces a merge commit on dev's first-parent line)
2. Post-merge hook fires `claim-dev-merge.sh` which calls `bin/version --seal` → returns `vYEAR.SERIES.DEV` reflecting the just-landed merge
3. `git tag -a $SEAL` on the merge commit; push tag
4. (Optional) `auto-rebase-pools-after-dev-merge.sh` rebases other open pool branches against the new dev tip + updates their PR aspirational titles

Flow for `dev` → `main`:

1. PR is approved and merged into `main` via **--no-ff** (REQUIRED — the merge commit on main's first-parent line is what countability depends on)
2. Post-merge hook fires `claim-main-release.sh` which calls `bin/version --release-tag` → returns the SAME value as the latest dev tag (release reuses dev tag)
3. **No new git tag is created.** A GitHub Release object is created/attached to the existing dev tag via `gh release create`. The build pipeline (`build-on-tag.yml`) attaches the build artifact.
4. Safety GC (3-gate): delete `safety/X` IFF paired `vault/X` exists AND release tag exists AND vault's SHA is an ancestor of current main.

Year-rollover behavior: the first merge after Jan 1 UTC reads `YYYY` from the clock; `DEV` resets to 0 + 1 = 1 (counts the new merge). No scheduled job — purely lazy.

Both claim scripts are also wrapped by remote workflows (`claim-on-merge-dev.yml`, `claim-on-merge-main.yml`) that fire automatically on push to the target branch. Each workflow additionally accepts a manual `workflow_dispatch` trigger gated on the dispatching actor holding the admin role per GitHub's collaborators permission API; this is the operator escape when the automatic push run does not complete. Each workflow wraps the canonical script invocation in an exponential-backoff retry loop (8 attempts, capped at 5 minutes between attempts) with a 4320 minute job timeout so transient GitHub API or network failures during tag push, Release creation, or safety GC ride out without surfacing as a workflow failure. The scripts themselves are idempotent (tag-exists check on dev, no-new-tag on main) so each retry is safe.

---

## Hook Architecture

Two complementary layers.

### Local hooks — validation & guardrails

Versioned in `.io.v4rian.how-git/githooks/`, activated with
`git config core.hooksPath .io.v4rian.how-git/githooks` (auto-applied
by the in-repo scripts on first run via `scripts/_lib.sh`'s
`ensure_hooks_path`; no setup step required).

- `pre-commit` — scrub em-dashes and en-dashes from staged files
- `prepare-commit-msg` — smart auto-fix layer (dash scrub, banned-word replacement, [TAG] derivation from staged diff shape, description sentence cap, third-person bullet rewrite)
- `commit-msg` — 8-100 char subject-length guardrail
- `pre-push` — reject branch names that don't match the `(pool|safety)/nN.kind.short_name` format
- `post-checkout` — warn early at branch creation
- `post-merge` — auto-claim version on dev and main when a PR merge lands locally via `git pull`

These keep malformed branches and bad commits off the remote and
auto-reconcile what is mechanically reconcilable. They are bypassable
(`--no-verify`) and are **not** enforcement. The deterministic
enforcement of compile, coverage, runtime, and the offline test
suites runs asynchronously in CI via
`.github/workflows/ci-dispatch.yml`, which fans out every
`ci/{tests,audits}/pr-open/*.sh` script as a separate check (the
framework's own four required.* gates live under the sys layer at
`.io.v4rian.how-git/ci/`) and surfaces as required status checks on
PRs to dev.

### CI — enforcement & source of truth

GitHub Actions (or equivalent) runs on push to `dev` and `main`:

- On `dev` merge: tag the merge commit with the current dev version (internal, no release), commit the `dev_counter` bump. The paired `safety/…` branch already exists from branch-creation time and is left in place.
- On `main` merge: tag the merge commit with the current release version, **promote the tag to a public GitHub Release** (with auto-generated notes), commit the `main_counter` bump and reset `dev_counter` to 1. **Delete every `safety/…` branch whose paired `pool/…` branch is already merged into `dev` at this point** — the work they anchored is now sealed in a release tag.

The atomic version claim happens here, because only the remote can
serialize PR merges.

### Branch Protection (required)

- `main`: PR required, CI green, ≥1 review, no direct push, no force-push
- `dev`: PR required, CI green, no direct push
- **Branch creation restricted** on `pool/*` and `safety/*` patterns:
  only the automation bot identity can create new branches matching those
  patterns. Developers' attempts to push new branches matching those
  patterns are rejected at the server. Implement via GitHub Repository
  Rules ("Restrict creations") or equivalent on other forges.

---

## Hotfix Policy

Hotfixes follow the same path as any other change — there is no
out-of-band route to `main`:

- Allocate a working branch via the endpoint: `pool/nN.fix.JIRA-XXX-short_name`
- Branch is created from current `dev` HEAD (not `main`). If `dev` has
  diverged in ways that complicate the fix, an admin can re-base the
  branch onto a `main`-derived point.
- PR back into `dev`. Merge follows the standard `pool/ → dev` flow:
  safety snapshot created, dev_counter bumped, internal tag applied.
- Immediately open `dev → main` PR to promote the fix. Standard
  `dev → main` flow: `main_counter` bumps, public Release published.

Going through `dev` even for hotfixes preserves the invariant that
`main` only ever sees integrated, CI-verified changes. Speed comes from
PR-review urgency, not from bypassing the pipeline.

If a true bypass is ever required (e.g. catastrophic incident,
integration tests offline), it is an **admin override** documented in
the incident, not a policy.

---

## Open Questions

All previously open items are resolved by the current model. This section
will be repopulated as new questions surface during implementation.
