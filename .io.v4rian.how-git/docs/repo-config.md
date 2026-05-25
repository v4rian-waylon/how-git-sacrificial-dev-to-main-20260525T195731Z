# Repository Configuration

Server-side enforcement of the v4rian git strategy. Without these
rules, the local hooks are bypassable and the model is aspirational.
With them, the model is reality.

This document is forge-agnostic in spirit but uses GitHub terminology
because that's the assumed default. Translate to GitLab / Bitbucket /
Gitea as needed — the *intent* of each rule is what matters.

---

## Required rules

### `main` branch protection

- ✅ Require a pull request before merging
- ✅ Require status checks to pass: `main-merge` workflow's CI jobs
- ✅ Require approvals: **≥1 review**
- ✅ Dismiss stale approvals when new commits are pushed
- ✅ Restrict who can push to matching branches: **bot identity only**
  (for the version-bump commit)
- ❌ No force-pushes
- ❌ No deletions

### `dev` branch protection

- ✅ Require a pull request before merging
- ✅ Require status checks to pass: `dev-merge` workflow's CI jobs
- ✅ Restrict who can push: **bot identity only** (for version-bump commits)
- ❌ No force-pushes
- ❌ No deletions

### `pool/*` pattern (Repository Rule: Restrict creations)

- ✅ Restrict who can create branches matching `pool/*`: **branch-creator
  App identity only**
- Rationale: enforces the atomic-pair invariant — only the allocator can
  create working branches, and the allocator always creates the safety
  pair too

### `safety/*` pattern (Repository Rules: Restrict creations / updates / deletions)

- ✅ Restrict creations to **branch-creator App identity only**
- ✅ Restrict updates (pushes): **no one** — safety branches are
  read-only after creation
- ✅ Restrict deletions to **main-merge workflow identity only**
- Rationale: enforces I3 (safety branches are never modified) and the
  release-driven deletion lifecycle from the strategy

---

## Applying the rules

### Option A — GitHub UI

Settings → Branches → Add classic branch protection rule (for `main` /
`dev`), then Settings → Rules → Rulesets for the `pool/*` and `safety/*`
patterns. Tedious; recommended only for one-off bootstrap.

### Option B — `gh` CLI

Use `scripts/apply-repo-rules.sh`. Edit the placeholder values at the
top (org, repo, App ID, etc.) and run. The script is idempotent.

### Option C — Terraform

The [`integrations/github`](https://registry.terraform.io/providers/integrations/github/latest/docs)
provider has `github_branch_protection`, `github_repository_ruleset`,
and related resources. If your org already manages repos in Terraform,
add the resources there. Sample:

```hcl
resource "github_branch_protection" "main" {
  repository_id = github_repository.this.node_id
  pattern       = "main"

  required_status_checks { strict = true; contexts = ["ci/main-merge"] }
  required_pull_request_reviews { required_approving_review_count = 1 }
  enforce_admins = true
  allows_force_pushes = false
  allows_deletions    = false
}

resource "github_repository_ruleset" "dev_pattern_restrict_creations" {
  name = "dev-pattern-restrict-creations"
  repository = github_repository.this.name
  target = "branch"
  enforcement = "active"
  conditions {
    ref_name {
      include = ["refs/heads/pool/*"]
    }
  }
  rules {
    creation = true  # restricts creations
  }
  # bypass actors: branch-creator app
}
```

(Adapt to your provider version — Terraform's GitHub provider has
evolved its rulesets support; check current syntax.)

---

## Identities required

| Identity | Purpose | Permissions |
|---|---|---|
| `branch-creator` (GitHub App) | Creates `pool/*` + `safety/*` branches via the synchronous endpoint | `contents:write` |
| `ci-bot` (GitHub Actions default `GITHUB_TOKEN`) | Pushes version-bump commits and tags; creates Releases; deletes safety branches on main merge | `contents:write`, `releases:write` |

Keep these as **separate** identities so the audit log distinguishes
allocator activity from release activity.

---

## Verification checklist

Before declaring the rules live, verify each of the following with
*a non-admin developer account*:

- [ ] Cannot create a new `pool/n99.feature.foo` branch via `git push`
- [ ] Cannot create a new `safety/n99.…` branch via `git push`
- [ ] Cannot push commits to an existing `safety/…` branch
- [ ] Cannot delete a `safety/…` branch
- [ ] Cannot force-push to `dev` or `main`
- [ ] Cannot bypass PR review on `main`
- [ ] The branch-creator App **can** create matching branches
- [ ] The ci-bot **can** delete safety branches on main merge
- [ ] The ci-bot **can** push the version-bump commit to `dev` / `main`

If any of the negative cases (the "cannot"s) actually succeed, fix the
rule before going live. Local hooks are not a substitute.
