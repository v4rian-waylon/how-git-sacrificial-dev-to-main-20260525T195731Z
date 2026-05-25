---
name: git-coverage-audit
description: Binary content coverage verification — applies to BOTH preflight branches AND post-merge dev/main states. Diff -r the working tree (or branch checkout) against the zip's extracted content; must be byte-identical excluding sensitive files + README + gitignore. Invoke from git-snapshots step 1 (preflight) and steps 4/5 (post-merge).
---

# git-coverage-audit — binary content coverage

**STATUS:** deterministic enforcement moved to async CI. As of the Step 2 lifecycle redesign (`pool/n33`), the synchronous claude pass at `pre-push` time is dropped. The coverage audit now runs asynchronously on every pushed branch via `.github/workflows/audit-pushed-branch.yml` and surfaces as the `coverage` required status check on PRs to dev. Local invocation remains supported for diagnostics and for zip-rebuild workflows orchestrated by `git-snapshots`. The two-context lens below remains the authoritative reference.

Coverage proves the rebuild captured the zip's content faithfully. Two contexts:

1. **Preflight coverage**: the preflight branch's tree must match the zip extract for that repo, byte-for-byte (sensitive files excluded). Confirms the offsite backup is a true copy.
2. **Merge coverage**: after `[MERGE] dev into main` at a zip close, main's tree must match the zip extract for that repo, byte-for-byte. Confirms the atomic-commit rebuild reproduced the zip's full content.

## The diff command

```bash
diff -r --brief \
  --exclude=.git --exclude=__MACOSX --exclude=.DS_Store \
  --exclude=.auth --exclude=keys --exclude=node_modules \
  --exclude=.env --exclude='*.p8' --exclude='*.p12' --exclude='*.cer' \
  --exclude='*.pem' --exclude='*.provisionprofile' --exclude='*.mobileprovision' \
  --exclude='build' --exclude='build-*' --exclude=exports --exclude='*.zip' \
  --exclude='README.md' --exclude='.gitignore' --exclude='aqtinstall.log' \
  /tmp/zip<N>/<repo>/ <working-dir-or-checkout>/
```

The `--exclude=README.md` and `--exclude=.gitignore` are necessary because:
- The rebuild can add a richer README via `[DOCS]` commits.
- The rebuild can extend `.gitignore` with new exclusions.

These are **expected additions**, not coverage failures.

## Acceptance criteria

A coverage check passes iff:

- Zero significant `Files X and Y differ` lines (excluding README + gitignore).
- Zero `Only in <working-dir>` lines (other than README + gitignore + permitted scratch files like `aqtinstall.log` if the project produces them).
- Zero `Only in /tmp/zip<N>/<repo>/` lines (would mean missing source content — the rebuild dropped files the zip had).

## Preflight coverage (Step 1 verification)

Right after pushing each preflight branch:

```bash
# Clone the preflight branch into a scratch dir
git clone --branch preflight-bak-YYYY-MM-DD --single-branch \
  "https://github.com/sessionpass/<repo>.git" /tmp/pf-check
# Diff against the zip extract for this repo
diff -r --brief --exclude=.git <excludes> \
  /tmp/zip<N>/<repo>/ /tmp/pf-check/
```

Allowed diff: none for preflight (the zip extract IS the source of the preflight content).

## Merge coverage (Steps 4 and 5 verification)

After each `[MERGE] feature/X into dev` (Step 4) AND after `[MERGE] dev into main` (Step 5):

```bash
git -C <repo> checkout dev   # or main
diff -r --brief <excludes> /tmp/zip<N>/<repo>/ <repo>/
```

Allowed diff: README.md (richer in rebuild), .gitignore (more excludes in rebuild).

## What to do on coverage failure

If `Files X and Y differ`:
- `diff -u zip/X repo/X` to inspect — often whitespace / line ending differences (`diff -w` clean).
- If whitespace-only: acceptable, document.
- If content-only: the rebuild missed a change — go back to Step 3, find the missing edit, amend the right commit.

If `Only in zip/`:
- Source file in zip not in rebuild — the rebuild missed adding this file. Add it in the right atomic commit.

If `Only in repo/`:
- File in rebuild not in zip — usually `runtime-smoke-notes.md`, `aqtinstall.log`, or a backup file. Either add to `.gitignore` and drop, or document why it should ship.

## Per-zip ledger

For each zip rebuilt, save a coverage ledger:

```text
zip 5 (cmna BAK ALL RULES SHIFTCOMPRESSOR BEFORE HOUR NUDGING, 2026-04-12)
  cmna preflight coverage:    PASS (clean diff)
  cmna [MERGE] dev into main: PASS (only README.md, .gitignore additions)
```

Save to `/tmp/coverage/<repo>-<zip-date>.log`. The ledger is the audit trail.

## Banned shortcuts

- Skipping coverage on small zips ("only 2 files changed") — coverage proves binary equivalence, not size.
- Treating any `Files X and Y differ` as fine without `diff -u` inspection.
- Excluding more than the sensitive + README + gitignore set — broad excludes hide regressions.

## See also

- [`git-snapshots`](../git-snapshots/SKILL.md) — invokes coverage-audit in steps 1, 4, 5.
- [`git-snapshot-preflight`](../git-snapshot-preflight/SKILL.md) — preflight content must satisfy coverage first.
- [`git-compile-audit`](../git-compile-audit/SKILL.md) — coverage proves content; compile proves it parses.
- [`git-runtime-audit`](../git-runtime-audit/SKILL.md) — coverage proves content; runtime proves it boots.
