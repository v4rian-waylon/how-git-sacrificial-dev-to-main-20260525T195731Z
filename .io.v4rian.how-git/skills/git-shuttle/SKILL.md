---
name: git-shuttle
description: Reconstruct atomic git commit history (full rebuild OR simple "code-version these uncommitted changes") from working-tree folders the user drops in the workspace's inbound shuttle. Generalizes git-snapshots for the case where the source is loose folders rather than bak zips — folders that may or may not have .git inside, may contain ONE or MANY nested repos/working trees, and may not yet have a target repo at all. The data the skill operates on is irreplaceable user work — preamble ASKS FOR EVERYTHING, ASSUMES NOTHING. Recursive scan of the shuttle finds every candidate; per-snapshot prompts cover target repo (existing path / clone from URL / git-init new / "explain otherwise"), author identity (previously saved + last 5 distinct contributors + manual override), push policy + credential preflight, and dev/main grant. Methodology is content-hash matching to find the parent commit C*, cross-repo integration check to skip files already represented elsewhere, senior-architect judgment for the remaining orphans (mainline vs archival branch — never lose info), then atomizing the diff into feature commits per the existing git-* audit lenses and merging through dev → main per the workspace's git rules. Project-agnostic — every path, identity, and grant comes from the preamble, never hardcoded.
---

# git-shuttle — rebuild git history from working-tree folders

Sister skill to [[git-snapshots]] (which walks `BAK *.zip` chains). git-shuttle handles the case where the source is one or more **working-tree folders** — possibly with no `.git/` inside, possibly nested deep, possibly not even a real repo (a pre-expanded snapshot of one) — typically delivered through the workspace's inbound shuttle. The target repo(s) may already exist with rich history, may need to be `git init`-ed, may need to be cloned from a URL, or may need path-mapping into a pre-existing repo.

The output git log must look like normal disciplined development per [[feedback_no_zip_refs_in_history]] — no reference to shuttles, snapshots, rebuilds, or zips.

## Two modes of operation

git-shuttle covers two adjacent use cases under one preamble + methodology:

1. **Full rebuild** — multiple snapshots representing different moments in time, each with hours of work, to be atomized into clean commit history. Often spans multiple repos.
2. **Code-version uncommitted changes** — a single working-tree folder represents the current state of in-flight work; commit it cleanly into its existing repo per the git-* audit lenses without faking history.

Both modes use the same preamble and the same audit chain. The difference is purely the number of snapshots and whether content-matching identifies a non-HEAD parent commit.

## Principles (binding, not advisory)

1. **ASK FOR EVERYTHING. ASSUME NOTHING.** Every path, every repo mapping, every identity, every grant comes from explicit user input. There is no fallback to "the most likely choice" — the most likely choice has produced data loss in past runs.
2. **Every prompt includes an "explain otherwise" affordance.** `AskUserQuestion` always exposes "Other" as a user-supplied option — name it explicitly in the question framing ("…or describe what I'm missing") so the user knows the path is available.
3. **The user's working tree is precious and delicate.** It often represents many hours of work and decision-making spread across days or weeks. Default to surfacing findings + asking, not to executing.
4. **Lossless above all.** No file from any snapshot is silently dropped. Files that don't belong on the mainline land on an archival branch with a written reason. The bar is "every byte of user work is reachable from at least one branch after the run completes."
5. **Distinguish "integrated already" from "abandoned/superseded".** A file whose blob exists somewhere in the union of remote-reachable history of the workspace's repos is already integrated — skip it. A file whose blob doesn't exist anywhere is an orphan and needs an explicit judgment call: mainline or archival.

## Preamble (run BEFORE any rebuild work)

The preamble is mandatory and runs once at the start of each invocation. Every path, identity, and grant the rebuild needs is established here. Once the preamble closes, the skill never prompts again mid-flow except for genuinely irreversible operations.

The preamble has a strict order because each step's options depend on the previous step's answer.

In every `AskUserQuestion`, phrase the question so the "Other" affordance is explicitly invited: "…or pick Other and tell me what I'm missing." Never present a closed multi-choice as though those were the only paths — the user always has the right to redirect.

Per the user-global Meta-rule 7 ("If you must halt to prompt the user, CALL — don't idle"), every preamble halt that waits for user input must be paired with a `voice-ask` call so the user hears the question even when away from the terminal. Compose the voice script using the same options the AskUserQuestion presents (neutral greeting → 1-sentence why → 2–4 lettered options → "or something else entirely"). Continue independent work (scanning, content-matching, backup snapshotting) while the call is in flight — those don't depend on the answer.

### Step 1 — Scan folder + identify snapshots

**Sub-step 1a — pick the scan root.** Ask via `AskUserQuestion`:

> "Which folder should I scan for working-tree snapshots? (the source of the rebuild)"
> Options: `<workspace>/shuttle.i/` (default if it exists and is non-empty), `<workspace>/` (broad scan), every prior shuttle path the conversation referenced, "Set a different path manually", "Other — let me describe the situation". Always include the explain-otherwise affordance.

**Sub-step 1b — recursive scan.** From the chosen root, scan recursively to a sane depth (default 4 levels). Classify every directory you find as one of:
- **bare git repo** (`.git/` is the directory itself) — rare
- **working-tree with `.git/`** — a repo checkout. Harvest branches, remotes, HEAD SHA.
- **working-tree without `.git/`** — a pure folder snapshot. The common case.
- **expanded zip artifact** — a folder that visibly came from `unzip` (often named `BAK-YYYY-MM-DD/`, or with file mtimes all matching the zip's stamp). Same handling as working-tree-no-git, but note the origin.
- **container directory** — a folder whose children are themselves snapshots (e.g. `1 JUNE 9 2025 HEAD/` containing 5 sibling repo snapshots). Recurse one level deeper.

**Sub-step 1c — show what you found and confirm.** Build a list:

```
Found in <scan-root>:
  ✓ <name>           — <files-count> files, <size>, mtime <date>, [no .git | branch=<x> head=<sha>]
  ✓ <name>           — …
```

Then ask via `AskUserQuestion`:

> "I found <N> candidate snapshots in <scan-root>. Should I process all of them, or do you want to pick a subset / point me somewhere else?"
> Options: "Process all <N>", "Pick a subset (I'll list them and ask which)", "Look elsewhere first", "Other — let me explain the structure". The explain-otherwise option matters because the folder layout may not match the skill's assumptions (e.g., the user expected one repo but the folder is a meta-container with N children, or vice versa).

If the user picks "Pick a subset", drive a per-snapshot inclusion question. If "Look elsewhere", return to sub-step 1a. If "Other / explain", treat the user's description as the canonical structure and proceed accordingly — never guess past what the user said.

**Sub-step 1d — handle the "this isn't a repo at all" case.** If the scan root or a specific snapshot is NOT a repo and the directory structure doesn't obviously map to one (e.g., a generic `documents/` folder dropped in shuttle), ask via `AskUserQuestion`:

> "<path> doesn't look like a working-tree of a known repo. What is it?"
> Options: "Pre-expanded snapshot of a repo (tell me which one in the next prompt)", "A folder that should become a new repo via `git init`", "Mistaken drop — skip it", "Other — let me explain". This is the no-repo / pre-expanded case the user warned about: never silently assume.

### Step 2 — Target repo per snapshot

For each snapshot, determine the target repo. The skill does NOT auto-pick — it surfaces candidates and asks. Heuristics that surface candidates (none are decisive):

1. Snapshot's directory name matches (case-insensitive) a workspace directory that is a git repo → propose, do not assume.
2. Workspace's `CLAUDE.md` declares a snapshot-to-repo mapping → propose, do not assume.
3. Snapshot's own `.git/config` (if present) names an `origin` whose URL matches a workspace clone → propose, do not assume.
4. Conversation history names a mapping (e.g., the user said "X is the new name of Y") → propose, surface verbatim, do not assume.

Per-snapshot ask via `AskUserQuestion`:

> "Which target repo should snapshot `<name>` rebuild into?"
> Options:
> - Every git repo found under the workspace (deduped, sorted by relevance — heuristic hits first), shown with absolute path, current branch, HEAD short-SHA + subject.
> - "Clone from a remote URL" — for when the target lives upstream but not locally yet.
> - "Initialize a new local repo (`git init`)" — for when there's no target at all yet.
> - "Attach with path-prefix mapping" — for when this snapshot's root should land at a subfolder of an existing repo.
> - "Other — let me explain" — always present, for when none of the above fit.

The "Other" affordance is mandatory in every git-shuttle prompt, called out explicitly in the question framing.

### Step 2b — No-repo fallbacks

If the user picks **Clone**, **Init**, **Attach**, or **Other**, branch accordingly:

- **Init (new local repo)**: ask the folder path verbatim. Run `git init <path>` only after the user confirms — `git init` creates `.git/` in place and is otherwise non-destructive, but the user picks the location. Set the default branch via the workspace's preference (typically `main` per [[reference_git_strategy]]). The first commit on this repo follows [[feedback_bootstrap_follows_strategy]] — commit #1 lands directly on `dev` with no `--no-ff` and no empty INIT commit (per [[feedback_no_empty_commits]]); `main` then fast-forwards to dev.

- **Clone from URL**: ask the user for the repo URL verbatim — never guess from a partial name. Follow with:
  1. Ask which directory should host the clone (default: `<workspace>/<repo-basename>/`). Confirm before running.
  2. Ask which credential identity to use — present every cached `gh auth status` account, every git credential helper entry that matches the URL's host, plus "Set GH_TOKEN / SSH key manually", plus "Other — explain". Never silently fall back to the host's default.
  3. Run `gh repo clone <url> <dest>` if `gh` is authenticated for that host, else `git clone <url> <dest>`. If the credential probe in Step 4 has not run yet, surface that as a blocker before cloning — cloning a private repo triggers the same GCM hang as pushing.
  4. After the clone, refresh the candidate-repo list and reprocess Step 2 — the just-cloned repo is now a valid local target.

- **Attach with path-prefix mapping**: list the discovered repos by absolute path + their HEAD branch + their most recent commit summary. After the user picks one, ask: *"Which subfolder inside that repo should this snapshot's root map to (use `.` if the snapshot is the whole repo)?"* This becomes the path-prefix mapping applied during diff atomization (the matching content-match.sh flag is `--path-prefix STR`).

- **Other — let me explain**: open a free-form follow-up. The user may describe a scenario the skill doesn't yet model (e.g., "this is half of a future split — don't commit to either side yet"). Capture the explanation verbatim into `BACKUP.manifest.json` under `user_clarifications[]` and proceed per the user's direction.

### Step 3 — Author identity

Build the option list dynamically from FOUR sources, in this priority:

1. **Previously saved author identity** — check, in order:
   - Any prior `.ag-git-shuttle/runs/*/BACKUP.manifest.json` with a `user_grants[]` entry of `type=author_identity_override` — read the most recent one.
   - `~/.claude/projects/<workspace-slug>/memory/feedback_user_authors*.md` or any memory file that names an author for snapshot-rebuild work.
   - If multiple, present the most recent first.

2. **Last 5 distinct collaborators in the target repo(s)** (only if a repo exists with prior history):
   ```bash
   cd <target-repo> && git log --format='%an <%ae>' --all 2>/dev/null \
     | awk '!seen[$0]++' | head -5
   ```
   For multi-target runs, dedupe across all targets and take the union (up to 5 distinct identities total).

3. **Every git identity tied to the host user** ("waylon accounts" — generalize to whoever the host user is):
   - `git config --global user.name` + `git config --global user.email` → one identity
   - Every `.git/config` discovered during the workspace scan: extract `user.name` + `user.email` from `[user]` blocks if present
   - Optional: read `~/.config/git/config` if present
   - Deduplicate (name, email) tuples.

4. **"Set manually"** — let the user enter `Name <email>` verbatim via the AskUserQuestion "Other" text input.

Ask via `AskUserQuestion`:

> "Who is the author for the rebuilt commits? (the work in the snapshot was authored by them, not by me — see [[feedback_user_authors_when_rebuilding_history]])"
> Options: each unique identity from sources (1) → (2) → (3), then "Set manually". Mark previously-saved identities visibly: "(saved from <prior-run-id>)".

The selected identity is used for **both** `GIT_AUTHOR_NAME/EMAIL` and `GIT_COMMITTER_NAME/EMAIL` env vars on every commit. The target repo's persistent `git config user.*` is never modified — override per commit only. Rationale per [[feedback_user_authors_when_rebuilding_history]]: when the work being committed comes from the user's own snapshots, the author field must reflect them.

### Step 4 — Push policy

> "Push to origin after every audited git action (per [[feedback_sym9_push_every_git_action]] and [[feedback_push_after_every_commit]]), or local-only with you pushing yourself afterward?"

If push policy = yes, immediately run credential preflight per [[feedback_sym9_push_preflight]]:

- `git credential fill` for `host=github.com` (or whichever host the targets use). Cap with a coreutils-style timeout — macOS lacks `timeout`, so wrap in a backgrounded subshell with manual kill, OR use `gh auth status` as a non-hanging probe.
- If `gh auth status` shows logged in → push will work via `gh`'s credential helper.
- If GCM hangs (the known issue per [[feedback_github_auth_from_claude]]) and no `GH_TOKEN` is set, surface the exact one-line `gh auth login` command and **halt** until the user resolves it. Do not start any task that requires a push until credentials are confirmed working — the cost of discovering the hang at task dispatch time is ≥1 hour of wasted wall-clock per occurrence.

If the targets use SSH remotes, probe with `ssh -T -o ConnectTimeout=5 -o BatchMode=yes git@github.com`. Surface the failure verbatim and ask the user to add their key to the agent.

### Step 5 — dev/main grant

For each target repo that has existing `dev` or `main` branches:

> "Should the rebuilt commits merge into existing `dev`/`main` per the git-zips flow (--no-ff merges + tag on main), or land on a dedicated `rebuild/<timestamp>` branch off the matched ancestor that never touches existing dev/main?"

The first option requires explicit verbatim grant per the inviolable rule [[feedback_sym9_never_touches_dev_or_main]]. Capture the user's exact wording, scope (this chat only? permanent?), and the affected repos. Log all of it under `BACKUP.manifest.json` user_grants. If the user denies, force the dedicated-branch option.

For a freshly init-ed repo from Step 2b option 1, no grant is needed — the repo has no existing dev/main to protect.

### Step 6 — Confirmation summary

Before exiting the preamble, summarize back to the user:

- Each snapshot → its target repo (+ path-prefix mapping if any)
- Author identity (one verbatim line)
- Push policy + credential status
- dev/main grant scope (or "dedicated branch only")
- **Placement strategy chosen** (Step D.5 alternative paths — `feature/* → dev → main` mainline, OR `*_2` parallel branches that the user later promotes, OR `archival/*` permanent forks)
- **Authoritative timestamp rule chosen** (LA timezone always; preserve-original vs HEAD+1day-shift for sub-HEAD orphans — see Step D.7)

Wait for explicit confirmation. After confirmation, no more questions during execution.

### Step 7 — Voice-ask the user before execution begins (MANDATORY)

After the confirmation summary in Step 6 lands and the user has reviewed it in text, ring them via `voice-ask` per the user-global Meta-rule 7 ("if you must halt to prompt the user, CALL"). The pattern is mandatory in git-shuttle because the run is destructive at scale and any silent mis-direction on the preamble produces hours of rework.

CLI: `node /Users/waylon/local_stage/ag.i/bin/agi-call.mjs "<script>"`

Script shape (per [[reference_voice_ask_skill]]):
- Neutral greeting (NO name)
- 1-sentence "why I'm calling" — name the scope (which snapshots, which targets, which strategy)
- 2-4 lettered options — primary path + named amendments + "or something else entirely"
- DON'T BLOCK — the call dials, the user answers when they accept; meanwhile continue any execution-independent work (re-mirroring the safety net, drafting the report skeleton, etc.).

Read the transcript at `127.0.0.1:8094/calls/<uuid>` after the call ends. Treat the user's voice answer as binding; barge-in (the user interrupts and redirects) resets expectations from scratch.

## Methodology (per snapshot)

Once the preamble closes, each (snapshot, target-repo) pair walks through the steps below. Multi-snapshot runs targeting the SAME repo are processed in **chronological order** (by snapshot folder mtime or by user-provided ordering) so each later snapshot sees the commits the earlier ones added.

### Step A — Backup (preflight)

Per [[git-snapshot-preflight]]:

1. `cp -pR <snapshot-folder> <run-dir>/BACKUP/source-snapshots/` — preserve mtimes.
2. `git clone --mirror <target-repo> <run-dir>/BACKUP/target-repos/<name>.mirror.git` — captures every ref + reflog.
3. If push policy = yes, push a `preflight-bak-YYYY-MM-DD[a-z]` branch to origin per [[feedback_preserve_preflight_branches]] **before any commit work begins**. Never delete or force-push against this branch later.

### Step B — Coverage audit (in-scope file list)

Per [[git-coverage-audit]]. Enumerate the snapshot's tracked-equivalent files:

```bash
find . -type f \
  ! -path '*/.git/*' \
  ! -path '*/node_modules/*' \
  ! -path '*/dist/*' \
  ! -path '*/build/*' \
  ! -path '*/build-*/*' \
  ! -name '.DS_Store' \
  ! -name '.session' \
  ! -name 'package-lock.json' \
  ! -name 'yarn.lock' \
  ! -name 'pnpm-lock.yaml' \
  ! -name '*.log' \
  ! -name 'aqtinstall.log' \
  ! -name '*.bak' \
  ! -name '*_old.qml'
```

Add any workspace-specific banned files from `<workspace>/CLAUDE.md` (the "Workspace-wide banned files" section if present).

Apply the path-prefix mapping from Step 2b if applicable — i.e., if the snapshot's `components/Button.svelte` should land at `src/components/Button.svelte` in the target, prepend the prefix.

Write the list to `<run-dir>/snapshots/<name>/coverage.txt`.

### Step C — Content-hash match

Run `tools/content-match.sh <snapshot> <target-repo>` (shipped with this skill). The script:

1. Computes `git hash-object` for every in-scope file in the snapshot.
2. For every commit in the target repo's `git log --all`, computes how many snapshot files match the commit's tree at the same path.
3. Reports the top-N commits by match count, with match percentage and commit date/subject.

Decision rules for picking the parent commit C*:

| Top match | Decision |
|---|---|
| **100%** | Snapshot is already represented at C*. No rebuild needed. Write `parent.txt` with `clean=true`, `parent=<sha>`, and skip Steps D–G. |
| **≥90% AND unambiguous** | C* is the parent. Atomize the small diff in Step D. |
| **<90% AND unambiguous** | C* is the parent. Atomize the larger diff in Step D. Note the divergence in `parent.txt`. |
| **Multiple ties at the top** | Use the **earliest commit by author date** among the ties — the assumption is the work was done on top of the earliest shared state. Note the ambiguity. |
| **Top match below ~30%** | Note that the snapshot diverges substantially from the target's history. This is NOT necessarily a halt — it often means the snapshot pre-dates a structural refactor (e.g., the target later split off some files into a sibling repo). Run Step C.5 (cross-repo integration check) before halting. Only halt-and-ask if Step C.5 also can't account for the divergence. |

Write `<run-dir>/snapshots/<name>/content-match.tsv` (full output) and `parent.txt` (chosen C* + reasoning).

### Step C.5 — Cross-repo integration check (lossless triage)

The per-target content-match only sees ONE repo at a time, so it cannot distinguish "this work was abandoned" from "this work was extracted into a sibling repo". Run `tools/integration-check.sh` (shipped with this skill) to settle it:

```bash
integration-check.sh <snapshot-dir> <comma-separated-list-of-related-repos>
```

The script enumerates every blob OID reachable from `--all` refs in every related repo, then classifies every in-scope snapshot file as:

- **INTEGRATED** — the blob already exists in some related repo's history. Record where (which repo, first-occurrence commit). Skip this file in atomization — committing it would duplicate content already represented.
- **NEW** — the blob does not exist in any related repo's history. Genuinely orphan; goes to Step D / D.5 for atomization.

The "related repos" set comes from:
1. The target repo itself (sanity check).
2. Sibling repos the user named in the preamble (e.g., "this used to be one repo, now it's three").
3. Workspace `CLAUDE.md` declarations of repo lineage.
4. Per-snapshot ask if the lineage isn't established: *"Is this snapshot related to any other repos whose history I should also check? E.g., a precursor that was split into multiple repos later."*

Write `<run-dir>/snapshots/<name>/integration.tsv` (per-file classification) and `<run-dir>/snapshots/<name>/integration-summary.md` (counts + lineage notes).

### Step D — Diff atomization

For files marked NEW in Step C.5 (or for snapshots that skipped C.5 because the top match was unambiguous and high), compute the file-level diff between C* and the snapshot:

- **NEW**: snapshot has the file, C* does not → addition
- **MODIFIED**: same path, different blob hash → modification
- **DELETED**: C* has the file, snapshot does not → deletion

Write `<run-dir>/snapshots/<name>/diff.txt` listing each by category.

### Step D.5 — Placement strategy

For every NEW file that survives Step C.5, choose ONE placement strategy for the run. Strategies are mutually exclusive — pick once for the whole run, not per-file. The user's preamble answer (Step 5 + Step 6) determines the choice.

**Strategy P-1 — `*_2` parallel branches (DEFAULT — lossless mainline-bound rebuild)**

The user's preferred path when they explicitly want the orphans on mainline but don't want to touch existing `dev`/`main` directly. Methodology:

- Build `dev_2` starting from current `dev`'s tip (or current `main`'s tip if `dev` doesn't exist locally — `main` is treated as `dev` in that case).
- Build `main_2` starting from current `main`'s tip.
- Atomize the orphan diff into feature branches as per Step D.6, but each `feature/<name>` is branched off `dev_2` and merged into `dev_2` with `--no-ff` per [[git-merge-audit]].
- After every feature branch merges, the user reviews `dev_2`. On approval, the user (NOT the skill) promotes `dev_2 → dev` and `main_2 → main` and deletes the `_2` branches. The skill never force-pushes `dev` or `main` — promotion is a user-authored step.
- The chronological-ordering rule from Step D.7 applies — each commit's `GIT_AUTHOR_DATE` reflects the authoritative timestamp of the file(s) staged, and feature branches merge in chronological order so `git log dev_2` is strictly monotonic.

This strategy is the right default because:
- No information is lost — every orphan file becomes a real commit on a real branch that's pushed to origin.
- The existing `dev` / `main` are physically untouched until the user explicitly promotes — the skill's destructive footprint is bounded to `*_2` refs.
- Promotion is one user-side command (`git push origin <hash>:refs/heads/main --force-with-lease` after they've reviewed the diff), keeping the inviolable rule [[feedback_sym9_never_touches_dev_or_main]] honored by the skill.

**Strategy P-2 — direct mainline (legacy)**

Same atomization but feature branches merge directly into existing `dev` then existing `main`. Requires the explicit verbatim dev/main grant from Step 5. Use only when the user names this strategy by hand — never as the default.

**Strategy P-3 — `archival/*` permanent forks**

For files whose semantic place is *not* on the mainline trajectory (e.g., the work was an exploratory branch that was deliberately abandoned and shouldn't resurface). Commits land on a `archival/<descriptive-name>` branch off the matched ancestor C* or off the appropriate historical anchor. Pushed to origin so the work is permanently reachable. Never merged into dev/main. Use only when the user explicitly names files for archival OR when their judgment confirms the work is dead-ended.

Write `<run-dir>/snapshots/<name>/judgment.md` with the chosen strategy, the list of orphans, and per-orphan reasoning. For Strategy P-1 (the default), the reasoning is per-cluster, not per-file — the chronological weave handles individual files automatically.

### Step D.6 — Atomization plan

Group the orphans into atomic commits per [[git-strategy-audit]]:

- Same subsystem (matching directory prefix, related module, or import graph) → likely one feature
- New external dependency (`package.json` change + new files importing it) → "introduce X" feature
- Documentation-only changes → separate `[DOCS]` commit
- Unrelated single-line tweaks → separate `[FIX]` or `[REFACTOR]` per [[feedback_tag_new_for_genuine_new_features]]
- "Cleanup" diffs → `[CLEANUP]` commit, kept last so they don't mask feature changes

Per [[feedback_bootstrap_follows_strategy]] and [[git-strategy-audit]]:
- **Single-commit clusters** land directly on the destination branch (no feature branch).
- **≥2-commit clusters** get a `feature/<kebab-case-name>` branch. Name describes the feature, never the snapshot or the workspace mechanism. See [[feedback_no_zip_refs_in_history]].

Cluster commits go in CHRONOLOGICAL order per Step D.7 — if a later cluster (by group) has any file with an earlier authoritative timestamp than the first file of an earlier cluster, the clusters interleave: commit the earlier-timestamped file(s) first, even if they belong to a "later" logical group.

Write the full plan to `<run-dir>/snapshots/<name>/plan.md`: one line per planned commit in chronological order, mapping each commit to its files, its target branch, and its authoritative timestamp.

### Step D.7 — Authoritative timestamps (the file-by-file rule)

For every orphan file, compute its **authoritative LA-timezone timestamp** which will be used as `GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE` on the commit that introduces it.

Steps per file:

1. **Raw timestamp** — capture file mtime first; if unset/zero, fall back to creation time (`stat -f '%B'` on macOS); if both unset, fall back to creation time of the containing folder.
2. **Normalize to LA timezone** — every commit date renders in `America/Los_Angeles`. On macOS use `TZ='America/Los_Angeles' date -r <epoch> '+%Y-%m-%dT%H:%M:%S%z'`.
3. **Sub-HEAD adjustment** — if `T_raw < target_repo.HEAD.commit_date` AND the file's blob is NOT present in any past commit of the target repo's `--all` reachable history:
   - The file represents "leftover" work — work that was on disk during a past commit's day but didn't make it into that day's commit.
   - Adjust to `T_authoritative = (target_repo HEAD.commit_date) + 1 day + (the time-of-day portion of T_raw)`.
   - Rationale (user-provided): if the work wasn't committed before, assume the user finished the work on that day and the leftout was not related to the finished work for that day — so it lands AFTER HEAD, on the next day, preserving the work-pattern time-of-day signal.
4. **Already-blob-matched** — if step 3's "blob is present" branch trips (the file's exact content appears in some past commit), that file is actually INTEGRATED — Step C.5 should have caught it. If it slipped through (rare — content drift due to identical blobs across paths), use the date of the FIRST occurrence commit and skip step 5.
5. **Otherwise (T_raw >= HEAD)** — use `T_raw` directly. The file was modified after the current HEAD; its authoritative timestamp is its actual mtime.

Write the per-file mapping to `<run-dir>/snapshots/<name>/timestamps.tsv`:

```
<path>	<raw_mtime_iso>	<adjusted_iso>	<adjustment_reason>
```

**Strict chronological order rule for commits**: when iterating commits to compose, before staging any file check the mapping for any earlier-timestamped orphan that hasn't been committed yet. If found, that file's commit fires first as an **intermediate commit** to preserve monotonic `git log` order on the destination branch. In practice this just means: sort all orphans by `T_authoritative` ascending, walk the sorted list, group adjacent same-cluster files into a single commit, never reorder.

`GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE` for each commit are set to the LATEST authoritative timestamp among the staged files in that commit (so the commit's "moment" reflects when the last file in it was finished).

### Step E — Commit composition

For each planned commit, in order:

1. **Stage by name** — never `git add .` / `git add -A` (workspace-wide banned). Stage only the files this commit owns per `plan.md`.
2. **Run [[git-commit-audit]] sections A–I** as a pre-write audit:
   - A atomicity, B title format, C body shape, D bullet structure (per [[feedback_commit_bullets_indented]]), E fabrication (per [[feedback_commit_no_fabrication]]), F file hygiene (no banned files), G branching (feature branch present if multi-commit), H merge format (not yet), I staged-mtime date rule (per [[feedback_commit_date_matches_staged_mtime]]).
3. **Compose the message** per [[workflow_git_commits]]:
   - Title: `[TAG] Title` (no JIRA fabrication — see [[feedback_no_invented_jira_codes]])
   - General description paragraph at 1-3 sentences per [[feedback_commit_general_description]]
   - `Cause:` + `Fix:` mandatory on `[FIX]` / `[HOTFIX]`
   - `Changes:` always, indented bullets (file at top, methods nested under) per [[feedback_commit_bullets_indented]]
   - No em-dashes (per [[feedback_hyphens_vs_em_dashes]]); hyphens in compound words OK
   - **Never** include a `Co-Authored-By: Claude …` trailer (per [[feedback_no_claude_coauthor]])
   - **In-the-moment language only.** Write as the author would have at the commit's date — describe what the file/change IS, not what it WILL BECOME or what came BEFORE. Banned phrases: "era", "pre-X", "before the extraction", "later refactored to", "this version that lived under X before Y". Allowed: present-tense "introduces X", "adds Y", "supersedes Z" when Z is in the same commit.
4. **Commit with the chosen author identity and the authoritative timestamp from Step D.7** (LA timezone, sub-HEAD-adjusted if applicable):
   ```bash
   # Per the timestamps.tsv mapping built in Step D.7, the authoritative timestamp for this commit
   # is the MAX of T_authoritative across the staged files. Read it directly from the mapping.
   STAGED_ISO="$(<lookup max T_authoritative from timestamps.tsv for staged files>)"
   # STAGED_ISO is already an ISO-8601 string with LA tz offset (e.g., 2025-06-18T10:13:56-0700)

   GIT_AUTHOR_DATE="$STAGED_ISO" GIT_COMMITTER_DATE="$STAGED_ISO" \
   GIT_AUTHOR_NAME="<chosen>" GIT_AUTHOR_EMAIL="<chosen>" \
   GIT_COMMITTER_NAME="<chosen>" GIT_COMMITTER_EMAIL="<chosen>" \
   git commit -m "$(cat <<'EOF'
   [TAG] Title

   General description paragraph.

   Changes:
   - path/to/file.js
     - functionName: what changed
   EOF
   )"
   ```
   The LA-timezone rule: every commit's author + committer date renders in `America/Los_Angeles`. On macOS, the ISO string is `TZ='America/Los_Angeles' date -r <epoch> '+%Y-%m-%dT%H:%M:%S%z'` which produces e.g. `2025-06-18T10:13:56-0700`. **Never** use `stat -f '%Sm' -t '<format>Z'` (tags local wall-clock as UTC, producing a 7-hour skew). See [[feedback_commit_date_matches_staged_mtime]] for the broader discipline.
5. **Push immediately** if push policy = yes, per [[feedback_push_after_every_commit]] / [[feedback_sym9_push_every_git_action]]. Verify `git rev-parse HEAD` on the remote matches local after the push — BLOCKER + halt on mismatch.

### Step F — Merge to dev_2 / main_2 (or dev / main if direct mainline), then push

After all the snapshot's feature branches are committed:

- Merge each `feature/*` into the destination dev (or `dev_2` under Strategy P-1) with `--no-ff` per [[git-merge-audit]]:
  - Title: `[MERGE] <source> into dev` (or `dev_2`)
  - Body: description paragraph only (no bullets, no rebuild language)
  - Merge date = the source branch's latest content commit date (per Step D.7's authoritative-timestamp rule)
  - Push `dev_2` (or dev under P-2 direct mainline).
- **Under Strategy P-1 (default `*_2`)**: do NOT touch `main` or `dev` directly. `main_2` is created at the start as a sibling of `main` (forked from `main`'s tip), and after all feature merges into `dev_2`, fast-forward `main_2` to `dev_2`'s tip (`git checkout main_2 && git merge --ff-only dev_2`). Push `main_2`. The user (not the skill) promotes `_2 → canonical` after their review.
- **`commit-tree` replay caveat.** When Strategy P-1 includes both feature-branch commits AND replay of original post-insertion commits via `git commit-tree` + `git update-ref`, the replay does NOT update the working tree. Before any subsequent `cp` / file op on `dev_2`, `git reset --hard dev_2` to sync the worktree to the replayed tip. Symptom of forgetting: `cp: <dir>: No such file or directory`. See [[feedback_commit_tree_replay_needs_worktree_sync]].
- **`force-with-lease` push idiom for `_2` branches.** Each push of `dev_2` / `main_2` during the rebuild rewrites prior pushed state. Use `--force-with-lease=<branch>:<expected_remote_sha>` with `expected_remote_sha` sourced from a fresh `git ls-remote` — the bare `--force-with-lease` form bounces with "stale info" when the remote-tracking ref is out of sync (common when pushing via one-off auth URL rather than the configured remote). See [[feedback_force_with_lease_explicit_sha]].
- **Under Strategy P-2 (direct mainline, only with verbatim grant)**: merge `dev` into `main` with `--no-ff` per [[feedback_main_merge_per_zip]]. Tag the main merge per [[feedback_tag_every_main_merge]] (`git tag -a vX.Y.Z` AFTER every audit passes). Push main + tag.
- **Under Strategy P-3 (archival)**: no dev/main writes at all; the archival branch is pushed standalone and never merges.
- Tag the main merge per [[feedback_tag_every_main_merge]]: `git tag -a vX.Y.Z -m "..."` AFTER every audit (strategy, commit, merge, runtime, compile) has passed. Push the tag.

If push policy = yes, every action above pushes within seconds — never batch.

### Step G — Verify

Per [[git-coverage-audit]] (post-merge): diff the dev/main working tree against the snapshot's content. Should be byte-identical excluding the banned-file list.

Per [[git-compile-audit]] (if the target is a Node service or a Qt project the repo type matrix recognizes): build and check.

Per [[git-runtime-audit]] (Node services only): launch and confirm init markers.

If any verify step fails: halt, surface the failure, and either ask the user how to proceed OR revert the just-added commits via the mirror backup. Never bypass the audit.

## Multi-snapshot succession

When multiple snapshots target the SAME repo (e.g., earlier snapshot `Apr-26` and later snapshot `Jun-10` both rebuild into the same target):

1. Walk in chronological order by snapshot folder mtime (or by user-provided ordering in the preamble).
2. Complete Steps A–G for snapshot N (commits land on main + tag pushed).
3. For snapshot N+1, the content-match in Step C runs against the now-updated target repo — including the commits just added by snapshot N. The parent C* for N+1 is most often (but not always) the tag we just pushed for N.

## Output

Every run writes a single REPORT.md to `<run-dir>/REPORT.md`:

- Per snapshot: parent C*, file count by category (NEW/MODIFIED/DELETED), feature branches created, commits with their SHAs, merge SHAs, tag, push status.
- Per snapshot: `clean=true` if 100% matched (no rebuild needed).
- Per target repo: final dev SHA + main SHA + tag.
- Any user grants captured in the preamble, verbatim.
- Any halts that required user intervention mid-run (credential issues, low-match ambiguity, audit failures).

Deliver the REPORT.md + each snapshot's plan.md, parent.txt, ledger.md to the workspace's outbound shuttle via [[deliver]].

## State directory

All bookkeeping lives at `<workspace>/.ag-git-shuttle/runs/<run-id>/`:

```
.ag-git-shuttle/runs/<run-id>/
├── BACKUP.manifest.json       # verbatim user grants + blast radius + identity
├── BACKUP/
│   ├── source-snapshots/      # cp -pR of every scanned snapshot folder
│   └── target-repos/          # git clone --mirror per target repo, pre-touch
├── snapshots/<name>/
│   ├── coverage.txt           # in-scope file list (Step B)
│   ├── content-match.tsv      # full content-match output (Step C)
│   ├── parent.txt             # chosen C* + reasoning
│   ├── integration.tsv        # per-file INTEGRATED/NEW classification (Step C.5)
│   ├── integration-summary.md # counts + lineage notes (Step C.5)
│   ├── diff.txt               # NEW / MODIFIED / DELETED file lists (Step D)
│   ├── judgment.md            # per-orphan mainline/archival/skip + reasoning (Step D.5)
│   ├── plan.md                # full atomization plan (Step D.6)
│   └── ledger.md              # outcome summary
├── log/
│   └── orchestrator.log
├── tools/                     # symlink or copy of skill's tools/ (content-match.sh, integration-check.sh)
└── REPORT.md
```

The `BACKUP/` layer is the only safety net for rollback. If the user rejects the run, restore each target repo from its mirror via `git fetch --all --prune` from the mirror remote and `git update-ref` per branch.

## Banned operations

Inherits the workspace-wide bans from `~/.claude/CLAUDE.md` and the workspace's own `CLAUDE.md`. Additionally:

- **Touching user-authored commits** — never amend, rebase, or filter-branch existing history. See [[git-history-preservation]]. If the user-authored history must be rewritten, escalate to the user first; mechanics in [[git-history-rewrite]] are gated behind explicit grant.
- **`git add -A` or `git add .`** — stage by name only.
- **`Co-Authored-By: Claude` trailer.**
- **Hardcoding scope** — every path, identity, and grant comes from the preamble or the workspace's `CLAUDE.md`. The skill itself ships zero hardcoded paths.
- **Skipping a single grant** — if a snapshot needs `dev`/`main` writes and the user hasn't granted it in Step 5, halt and ask. Inferring grants is forbidden per [[feedback_sym9_never_touches_dev_or_main]].
- **Force-push without `--with-lease`** on any previously-pushed ref. Never force-push `main` regardless.
- **Push without credential preflight.** If Step 4 returned "credentials unresolved" and the user hasn't fixed it, the rebuild cannot start — halt and surface the exact command.

## When to use git-shuttle vs git-snapshots

| Source shape | Use |
|---|---|
| Chain of `BAK *.zip` files with mtimes for chronology | [[git-snapshots]] |
| Loose working-tree folder(s) — dropped in shuttle.i or named by the user | **git-shuttle** |
| A single folder + the rebuild is the entire scope | **git-shuttle** |
| Repo doesn't exist yet (init / clone / attach needed) | **git-shuttle** |
| Multi-source archeological rebuild with both zips and folders | run [[git-snapshots]] for the zip chain, then **git-shuttle** for the folders |

Both share the underlying sub-skill stack (commit-audit, merge-audit, strategy-audit, coverage-audit, compile-audit, runtime-audit). The difference is the source shape, the preamble flow, and the no-repo fallbacks.

## See also

- [[git-snapshots]] — zip-chain variant; the parent generalization of this skill
- [[git-snapshot-preflight]] — pre-write security backup discipline
- [[git-coverage-audit]] — file-set verification
- [[git-strategy-audit]] — branching strategy
- [[git-commit-audit]] — per-commit audit lens
- [[git-merge-audit]] — per-merge audit lens
- [[git-compile-audit]] — compile verification
- [[git-runtime-audit]] — boot/launch verification
- [[git-history-preservation]] — gate against rewriting user-authored history
- [[git-history-rewrite]] — mechanics for date-preserving rewrite (when explicitly granted)
- [[git-token-discovery]] — credential discovery for GitHub/GitLab
- [[feedback_user_authors_when_rebuilding_history]] — the author identity rule
- [[feedback_sym9_push_preflight]] — credential preflight gate
- [[feedback_sym9_never_touches_dev_or_main]] — dev/main grant rule
- [[feedback_bootstrap_follows_strategy]] — bootstrap commit on a brand-new repo
- [[deliver]], [[request]] — shuttle siblings for file artifacts
- [[voice-ask]] — mandatory call-during-halt per user-global Meta-rule 7
