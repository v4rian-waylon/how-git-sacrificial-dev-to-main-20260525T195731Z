---
name: how-dev
description: Monitor every CI run that any push triggers. After git push, gh pr create, git push --tags, or any action that lands a SHA workflows react to, watch the runs, inspect every failure via gh run view --log-failed, and surface the outcome (green or red) to the user as the closing artifact of the push. Letting the user catch a red check before you do is a process failure. BINDING for any v4rian-tracked repo with CI.
---

# how-dev — monitor what you push, fix what breaks, never let the user catch CI failures first

## The rule

**BINDING.** Every push triggers CI. A good developer watches every CI run their push fires and surfaces the result. If it fails, they diagnose and fix without waiting for anyone to notice. Letting the user catch a red check is a process failure.

This is the dev side of the v4rian principle that "a good developer shall trigger little reconciles even when not at fault; the faster they monitor their work and fix it, the fewer reconcile-only branches they leave for the admin." Monitoring is the operational expression of that principle.

## When this fires

Any time work is pushed to a remote that runs CI on push events:

- `git push` to `pool/*`, `dev`, `main`, `safety/*` on a v4rian repo
- `gh pr create` (which fires the `pull_request` workflows on the head SHA)
- `git push --tags` to a repo with tag-triggered workflows (e.g. `build-on-tag`)
- Any subsequent push that creates a new SHA (auto-rebase pushes, dev claim force-pushes)
- The completion of a workflow that triggers downstream workflows

In short: **if you caused a SHA to land that workflows react to, watch the runs.**

## How to monitor

Right after pushing:

1. **List the runs on the head SHA** to confirm the expected workflows fired. Use `gh run list --branch <branch> --limit N` or `gh api /repos/<owner>/<repo>/commits/<sha>/check-runs`. If a workflow you expected to trigger didn't show up, that's already a signal — figure out why (disabled workflow? wrong trigger config? anti-recursion?).
2. **Wait for the runs to finish.** Use a Bash `until` loop with `gh run view --json status` until `status=completed`. Don't sleep+poll arbitrary intervals — `gh run watch` or an `until ... done` is correct. When the watcher returns, every check has a conclusion.
3. **Inspect every failure** via `gh run view <id> --log-failed`. Don't just read the conclusion line — read the actual error so you understand the failure mode.
4. **Diagnose root cause** before reacting. If a check fails for a reason that's NOT related to your changes (pre-existing flake, env drift, infra issue), say so explicitly and treat it as a separate fix; if it IS related to your changes, fix it.
5. **Surface the outcome to the user.** Whether green or red, report what ran and what passed/failed. A clean green report is the closing artifact of the push; a red report is the first acknowledgement of the regression.

## What NOT to do

- **Don't push and walk away.** Even on a "small change" — small changes break CI plenty.
- **Don't trust local-green as a substitute.** CI env differs (different OS, different git version, different env vars, missing git identity, different tool versions). Local-green is a necessary precondition, not a final answer.
- **Don't wait for the user to spot the failure.** The user noticing red before you do is the process failure this skill exists to prevent.
- **Don't ship a "looks done" report when CI is still in_progress.** Either wait for completion or say explicitly "CI runs in flight; will report when they finish."

## How to apply (recipe)

```bash
# After push that triggers CI, watch:
TOKEN=$(<resolve your GitHub token: GCM cache, gh auth token, $GH_TOKEN, etc.>)
BRANCH=<branch-you-just-pushed>
SHA=$(git rev-parse HEAD)

# 1. Confirm runs fired
GH_TOKEN="$TOKEN" gh run list --repo <owner>/<repo> --branch "$BRANCH" --limit 6 \
  --json event,name,status,conclusion,headSha \
  --jq '.[] | select(.headSha=="'"$SHA"'") | "\(.event)  \(.name)  \(.status)/\(.conclusion // "-")"'

# 2. Wait for completion (Monitor or until-loop)
until GH_TOKEN="$TOKEN" gh run list --repo <owner>/<repo> --branch "$BRANCH" --limit 6 --json status,headSha \
       --jq '[.[] | select(.headSha=="'"$SHA"'")] | map(select(.status!="completed")) | length' | grep -q '^0$'
do sleep 20; done

# 3. Inspect failures
GH_TOKEN="$TOKEN" gh pr view <N> --repo <owner>/<repo> --json statusCheckRollup
GH_TOKEN="$TOKEN" gh run view <failed-run-id> --repo <owner>/<repo> --log-failed | grep -E "FAIL|ERROR|error"

# 4. Report (green or red) to the user as the closing artifact of the push.
```

For PRs specifically, after `gh pr create` returns the URL: fetch the PR's mergeable and statusCheckRollup and confirm every required check is set.

## Origin

The rule was added after a dev pushed a refactor (auto-rebase reconcile-only path) without checking CI; the user later surfaced that three Ubuntu-only tests in the audit-pushed-branch workflow had failed because the workflow had no git identity setup so annotated `git tag -a` in scratch repos silently failed. The user's words at the time: *"if you push something as a good developer you should be looking at the test results."* The skill exists so the same omission never happens again.

## Cross-references

- [[git-merge-audit]] — the audit lens for any merge commit your push lands; CI verifies what the audit asserts
- [[git-commit-audit]] — applied pre-push; CI is the post-push verification of the same claims
- [[git-reconcile-intent]] — used during the dev cycle (rebase ladder); the reconciled commits still need CI green
