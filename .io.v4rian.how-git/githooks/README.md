# githooks

Local git hooks for the v4rian way. Auto-activated the first time any
in-repo script runs — `open-pr.sh`, `claim-dev-merge.sh`,
`claim-main-release.sh` source `scripts/_lib.sh` and call
`ensure_hooks_path`, which idempotently sets `core.hooksPath` to
`.io.v4rian.how-git/githooks` so these hooks are used in place of
`.git/hooks/` and stay versioned with the repo. To activate explicitly
(repair / drift), run `bash .io.v4rian.how-git/scripts/heal.sh`.

| Hook                  | Purpose                                                                |
|-----------------------|------------------------------------------------------------------------|
| `pre-commit`          | Scrub em-dashes and en-dashes from staged files before the commit lands |
| `prepare-commit-msg`  | Smart auto-fix layer, rewrites messages in place (dash scrub, banned-word replacement, [TAG] derivation from staged diff shape, sentence cap, third-person bullets) |
| `commit-msg`          | Subject line must be 8-100 characters (cheap deterministic guardrail)  |
| `pre-push`            | Reject pushes whose branch name does not match the v4rian format       |
| `post-checkout`       | Warn locally when a branch is created with a non-conforming name       |
| `post-merge`          | Auto-run claim-dev-merge.sh / claim-main-release.sh when a `git pull` brings a new merge onto dev / main; this is the automator, once hooks are active the merger types nothing |

These are **guardrails**, not enforcement. They can be bypassed with
`--no-verify`. The server-side Repository Rules in `docs/repo-config.md`
are authoritative. Local hooks exist to catch and reconcile mistakes
early, before they become noisy round-trips to the remote.

The deterministic enforcement of `compile`, `coverage`, and `runtime`
runs asynchronously in CI on every pushed branch via
`.github/workflows/audit-pushed-branch.yml` and surfaces as required
status checks on PRs to dev. The four claude audits that used to run
synchronously at `pre-push` time (strategy, compile, coverage, runtime)
moved there as of the Step 2 lifecycle redesign in `pool/n33`.
