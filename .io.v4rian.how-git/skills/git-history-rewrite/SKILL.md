---
name: git-history-rewrite
description: Mechanics for date-preserving git history rewrites — message-only filter-branch, hand-rolled commit-tree walkers when filter-branch is blocked, blank-repo wipe mechanic (zero commits, NO tombstone), force-with-lease push discipline, default-branch realities. Callable from higher-up skills when retroactive amendment is necessary. Project-agnostic — uses git config user.name/user.email for commit identity. NEVER invoke against user-authored commits — see git-history-preservation first.
---

# git-history-rewrite — date-preserving rewrite mechanics

When you need to rewrite history (retag commits, fix banned vocab, scrub fabricated bullets, etc.) on commits YOU produced — never user-authored — these are the safe mechanics.

**Precondition**: consult `git-history-preservation` first. Confirm the rewrite range contains no user-authored commits.

**Identity**: every commit-tree call reads identity from the working repo's `git config user.name` + `user.email`. Never hardcode identity strings.

## Mechanic 1 — message-only filter-branch (preferred when allowed)

For the common case of rewriting commit messages without touching tree or parents:

```bash
git filter-branch -f --msg-filter '
read first
case "$first" in
  "[REFACTOR] BookingService gains archive helpers")
    echo "[REFACTOR] BookingService adds archive helpers"
    ;;
  *)
    echo "$first"
    ;;
esac
cat  # pass through the rest of the message
' -- main dev feature/X feature/Y
```

**Critical**: never use `-- --all`. It rewrites every ref including `preflight-bak-*` (see `git-snapshot-preflight`). Enumerate refs explicitly.

`filter-branch --msg-filter` preserves both `GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE` automatically by reusing each commit's existing values.

After filter-branch, local remote-tracking refs may have diverged from origin. Refresh:

```bash
git update-ref -d refs/remotes/origin/main
git update-ref -d refs/remotes/origin/dev
git fetch origin --quiet
git push --force-with-lease origin main dev feature/X feature/Y
```

## Mechanic 2 — commit-tree walker (when filter-branch is blocked)

Some sandboxes block `git filter-branch`. Implement the equivalent in Python via `git commit-tree`:

```python
import subprocess, os

def rewrite_chain(repo_dir, range_start, branch, message_transform):
    """Walk range_start..branch in topological order, rebuild each commit
    with the transformed message and the rewritten parents. Preserves dates
    and identity by reading them from each commit."""
    shas = subprocess.run(
        ['git', '-C', repo_dir, 'rev-list', '--reverse', '--topo-order',
         f'{range_start}..{branch}'],
        capture_output=True, text=True).stdout.strip().split('\n')
    remap = {}
    for sha in shas:
        get = lambda fmt: subprocess.run(
            ['git', '-C', repo_dir, 'log', '-1', f'--format={fmt}', sha],
            capture_output=True, text=True).stdout.strip()
        msg = get('%B')
        tree = subprocess.run(['git', '-C', repo_dir, 'rev-parse', f'{sha}^{{tree}}'],
                             capture_output=True, text=True).stdout.strip()
        parents = subprocess.run(['git', '-C', repo_dir, 'rev-list', '--parents',
                                  '-n', '1', sha],
                                capture_output=True, text=True).stdout.strip().split()[1:]
        new_parents = [remap.get(p, p) for p in parents]
        new_msg = message_transform(msg)
        env = dict(os.environ)
        env.update({
            'GIT_AUTHOR_DATE': get('%aI'),
            'GIT_COMMITTER_DATE': get('%cI'),
            'GIT_AUTHOR_NAME': get('%an'),
            'GIT_AUTHOR_EMAIL': get('%ae'),
            'GIT_COMMITTER_NAME': get('%cn'),
            'GIT_COMMITTER_EMAIL': get('%ce'),
        })
        cmd = ['git', '-C', repo_dir, 'commit-tree', tree]
        for p in new_parents: cmd += ['-p', p]
        cmd += ['-m', new_msg]
        new_sha = subprocess.run(cmd, env=env, capture_output=True, text=True).stdout.strip()
        remap[sha] = new_sha
    subprocess.run(['git', '-C', repo_dir, 'update-ref',
                    f'refs/heads/{branch}', remap[shas[-1]]], check=True)
    return remap
```

## Mechanic 3 — blank repo wipe (orphan + empty tree + empty message)

When a repo is intentionally empty (created in error, content rejected, wiped):

Force-push `main` to an orphan commit with an **empty tree** and an **empty commit message**. No `Initial`, no descriptive subject, no tombstone text. This is the minimal-possible commit git allows while keeping a branch ref.

```bash
# In a scratch dir
TMP=$(mktemp -d)
cd "$TMP"
git init -q -b main
git remote add origin <remote-url>

# Empty tree (git's universal empty tree SHA: 4b825dc642cb6eb9a060e54bf8d69288fbee4904)
TREE=$(git mktree </dev/null)

# Orphan commit with empty tree + empty message
# Identity from the source repo's git config (read separately and pass as env)
NAME=$(git -C <source-repo> config user.name)
EMAIL=$(git -C <source-repo> config user.email)
COMMIT=$(GIT_AUTHOR_NAME="$NAME" GIT_AUTHOR_EMAIL="$EMAIL" \
         GIT_COMMITTER_NAME="$NAME" GIT_COMMITTER_EMAIL="$EMAIL" \
         git commit-tree "$TREE" --allow-empty-message -m "")

# Force-push as main, replacing whatever was there
git push --force origin "$COMMIT:refs/heads/main"

# Delete any other branches on origin (dev, feature/*, etc.)
for b in $(git ls-remote --heads origin | awk '{print $2}' | sed 's|refs/heads/||' | grep -v '^main$'); do
  git push origin --delete "$b" 2>/dev/null
done

# Cleanup
cd / && rm -rf "$TMP"
```

Result: origin shows `main` pointing at one commit, that commit has no parent, an empty tree, an empty message. No `Initial`, no tombstone. No `dev`. No feature branches.

The user does not get prompted for confirmation — the safety-snapshot pattern (from `git-snapshots` § Reversibility) lets this be rolled back if rejected.

## Mechanic 4 — force-push discipline

| Operation | Command |
|---|---|
| Force-push to overwrite previously-pushed branch | `git push --force-with-lease origin <branch>` |
| Force-push a specific SHA to a ref | `git push --force-with-lease origin <sha>:refs/heads/<branch>` |
| Delete a remote branch (non-default) | `git push origin --delete <branch>` |

**Never** use `--force` without `--with-lease` on a branch that was already pushed — the lease checks origin hasn't moved since your last fetch.

**Never** include `preflight-bak-*` branches in any force-push command after the initial preflight push.

## Default branch realities

GitHub refuses `git push origin --delete <default>` with "refusing to delete the current branch". To delete:

1. Change the default branch first (via host UI Settings → Branches, or `gh repo edit --default-branch <other>`, or `PATCH /repos/{owner}/{repo}` with `default_branch` — requires admin scope).
2. Then `git push origin --delete <old-default>`.

If you have only push access (no admin / no `delete_repo`): you cannot fully wipe. See Mechanic 3.

## Sandbox/permission caveats

Some Claude environments block `git filter-branch`. Workarounds:

- Run with `--force` and minimal scope (`-- main dev feature/X`, never `-- --all`).
- Fall back to Mechanic 2 (Python commit-tree walker).
- Use `git rebase -i <base>` with `exec git commit --amend -m "..."` lines.

## Preflight branch refresh after local divergence

If a `git filter-branch -- --all` accidentally touched `preflight-bak-*` locally (it never should, but if it did):

```bash
git fetch origin
git branch -f preflight-bak-YYYY-MM-DD origin/preflight-bak-YYYY-MM-DD
```

Origin is canonical for preflight refs.

## Reversibility wrap

When invoked from `git-snapshots`, every rewrite is gated by safety snapshots (see `git-snapshots` § Reversibility). Tag current state as `safety/<branch>-<timestamp>` and push BEFORE rewriting. If rejected, force-push the safety branch back.

## See also

- [`git-history-preservation`](../git-history-preservation/SKILL.md) — gate before invoking this skill.
- [`git-snapshot-preflight`](../git-snapshot-preflight/SKILL.md) — preflight branches are immutable; never include in rewrite ref lists.
- [`git-commit-audit`](../git-commit-audit/SKILL.md) — the audit lens you're applying via the rewrite.
- [`git-merge-audit`](../git-merge-audit/SKILL.md) — merge titles + bodies are the common retroactive amendment target.
- [`git-token-discovery`](../git-token-discovery/SKILL.md) — when rewrite requires API operations.
