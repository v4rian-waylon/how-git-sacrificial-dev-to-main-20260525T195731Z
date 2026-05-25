#!/usr/bin/env bash
# auto-fix-commit-message.sh - shared smart auto-fix layer for commit messages.
#
# Sourced (not executed) by the prepare-commit-msg hook AND by any PR-stage
# validator that wants to apply the same shape rewrites to a PR body. The
# Step 2 lifecycle redesign moved the heavy commit auditing out of
# synchronous claude calls into deterministic local auto-fix plus async CI;
# this file is the deterministic local auto-fix half. It rewrites what it
# can and surfaces what it cannot, never blocking on a difference it knows
# how to repair.
#
# Public entry points:
#
#   auto_fix_message <msg-file>            Aggressively rewrites the message
#                                          file in place. Always exits 0;
#                                          rewrite is best-effort. Use when
#                                          you want the cleanest possible
#                                          message and accept idempotent
#                                          edits.
#
#   audit_message    <msg-file>            Runs the rejection checks against
#                                          the message file plus the staged
#                                          diff. Exits 0 on pass, 1 on a
#                                          condition the auto-fix cannot
#                                          reconcile, with a WHAT / WHY /
#                                          DECIDE block printed to stderr.
#
#   derive_tag_from_diff                   Inspects the staged diff and
#                                          prints one of [FIX] [NEW]
#                                          [REFACTOR] [DOCS] [TEST]
#                                          [REVERT] [MERGE]. Returns empty
#                                          on uncertain shapes (caller may
#                                          fall back to the user's tag).
#
# Public knobs (env):
#
#   AUTO_FIX_MAX_SENTENCES   default 3     Sentence cap on the description
#                                          paragraph.
#   AUTO_FIX_BANNED_WORDS    default "plus"
#                                          Comma-separated list of words to
#                                          scrub from prose (case-insensitive,
#                                          whole-word). Replacement is "and".
#
# All transforms are bash + standard POSIX tools (sed, awk, grep, python3).
# No claude calls, no network. Idempotent: running auto_fix_message twice
# on the same input produces the same output.

set -uo pipefail

# Approved tag set (matches git-commit-audit Section B).
_AUTO_FIX_TAGS='[FIX]|[NEW]|[REFACTOR]|[DOCS]|[TEST]|[REVERT]|[HOTFIX]|[MERGE]'

# Resolve repo root once. Falls back to current dir if not inside a repo.
_auto_fix_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# Print the body of the message file with comment lines (^#) stripped, so
# downstream transforms only see the author's prose.
_auto_fix_strip_comments() {
  local msg_file="$1"
  grep -v '^#' "$msg_file" 2>/dev/null || true
}

# Detect whether the message is empty or pure boilerplate (the git editor's
# default skeleton when the user saved without typing anything substantive).
_auto_fix_is_empty_or_boilerplate() {
  local msg_file="$1"
  local body
  body=$(_auto_fix_strip_comments "$msg_file" | tr -d '[:space:]')
  [ -z "$body" ]
}

# Count distinct top-level directories touched by the staged diff. Used as
# a cheap atomicity smell-test: 4+ top-level dirs is the signal that the
# diff likely spans multiple logical changes.
_auto_fix_count_top_dirs() {
  git diff --cached --name-only 2>/dev/null \
    | awk -F/ 'NF>1{print $1} NF==1{print "."}' \
    | sort -u \
    | wc -l \
    | tr -d ' '
}

# Inspect the staged diff and emit a best-guess tag. Heuristics, in order:
#   - Only test/ files staged -> [TEST]
#   - Only docs / .md files staged -> [DOCS]
#   - Diff adds a brand-new top-level file or directory -> [NEW]
#   - Diff is a pure revert (sha trailer present) -> [REVERT]
#   - Diff includes both adds + deletes across mixed files -> [REFACTOR]
#   - Otherwise empty (caller falls back to user's tag).
derive_tag_from_diff() {
  local files added deleted modified
  files=$(git diff --cached --name-only 2>/dev/null)
  if [ -z "$files" ]; then
    echo ""
    return 0
  fi

  # Test-only diff.
  if echo "$files" | grep -qE '^(.*/)?test(s)?/' \
     && ! echo "$files" | grep -qvE '^(.*/)?test(s)?/'; then
    echo "[TEST]"
    return 0
  fi

  # Docs-only diff (md / rst / txt under docs/ or at root).
  if ! echo "$files" | grep -qvE '(\.md|\.rst|\.txt|CHANGELOG|RUNBOOK|README|CONTRIBUTING)'; then
    echo "[DOCS]"
    return 0
  fi

  # Detect a pure file addition (file mode created in diff).
  added=$(git diff --cached --diff-filter=A --name-only 2>/dev/null | wc -l | tr -d ' ')
  deleted=$(git diff --cached --diff-filter=D --name-only 2>/dev/null | wc -l | tr -d ' ')
  modified=$(git diff --cached --diff-filter=M --name-only 2>/dev/null | wc -l | tr -d ' ')

  # All-add, no modify: clearly something new.
  if [ "$added" -gt 0 ] && [ "$modified" -eq 0 ] && [ "$deleted" -eq 0 ]; then
    echo "[NEW]"
    return 0
  fi

  # Mix of add + delete with no modify across multiple files: a refactor move.
  if [ "$added" -gt 0 ] && [ "$deleted" -gt 0 ] && [ "$modified" -eq 0 ]; then
    echo "[REFACTOR]"
    return 0
  fi

  # Only modifications: refactor (or fix - we cannot tell from shape alone).
  if [ "$modified" -gt 0 ] && [ "$added" -eq 0 ] && [ "$deleted" -eq 0 ]; then
    echo "[REFACTOR]"
    return 0
  fi

  # Anything else: refactor as the safe default (covers mixed shapes).
  echo "[REFACTOR]"
}

# Rewrite the message in place. Order of transforms matters:
#   1. Drop banned trailers (Co-Authored-By: Claude).
#   2. Scrub em-dashes and en-dashes (banned per the commit conventions).
#   3. Scrub the word "plus" as a conjunction.
#   4. Drop "+" joiners from the title line.
#   5. Auto-derive [TAG] when the title lacks one entirely.
#   6. Condense the description paragraph to <= AUTO_FIX_MAX_SENTENCES.
#   7. Rewrite bullets to third-person present (best effort).
#   8. Trim top-level bullets that lead with a path to lead with the basename.
auto_fix_message() {
  local msg_file="$1"
  [ -f "$msg_file" ] || return 0

  local max_sentences="${AUTO_FIX_MAX_SENTENCES:-3}"
  local banned_words="${AUTO_FIX_BANNED_WORDS:-plus}"

  python3 - "$msg_file" "$max_sentences" "$banned_words" <<'PY'
import io, os, re, sys

msg_path, max_sentences_str, banned_words_csv = sys.argv[1], sys.argv[2], sys.argv[3]
max_sentences = max(1, int(max_sentences_str))
banned_words = [w.strip() for w in banned_words_csv.split(',') if w.strip()]

with open(msg_path, 'r', encoding='utf-8') as f:
    raw = f.read()

# Split body from git-style comment lines so we never rewrite scissor or
# diff lines that git appends. Anything starting with "#" is left as-is.
lines = raw.splitlines()
body_lines = []
tail_comment_block = []
in_tail = False
for line in lines:
    if line.startswith('#'):
        in_tail = True
        tail_comment_block.append(line)
    else:
        if in_tail:
            # Body-after-comment is unusual; treat as still-comment for safety.
            tail_comment_block.append(line)
        else:
            body_lines.append(line)

body = "\n".join(body_lines)

# 1. Drop banned trailers.
body = re.sub(r'(?im)^co-authored-by:\s*claude.*\n?', '', body)

# 2. Scrub em-dashes and en-dashes. Em-dash with surrounding spaces becomes
#    a comma-space (most natural English replacement); em-dash without
#    surrounding spaces becomes a hyphen. En-dash always becomes a hyphen.
body = re.sub(r'\s+—\s+', ', ', body)
body = body.replace('—', '-')
body = body.replace('–', '-')

# 3. Scrub banned words as conjunctions (whole-word, case-insensitive).
for word in banned_words:
    pattern = re.compile(r'\b' + re.escape(word) + r'\b', re.IGNORECASE)
    body = pattern.sub('and', body)

# Split into title + remainder so the title-only transforms only touch line 1.
parts = body.split('\n', 1)
title = parts[0] if parts else ''
rest = parts[1] if len(parts) > 1 else ''

# 4. Drop "+" joiners from the title. Inside identifier-like tokens
#    (with no surrounding space, e.g. C++ or Objective-C++), leave alone.
title = re.sub(r'\s+\+\s+', ' and ', title)

# 5. Auto-derive [TAG] when the title has no approved tag.
APPROVED = {'[FIX]', '[NEW]', '[REFACTOR]', '[DOCS]', '[TEST]', '[REVERT]', '[HOTFIX]', '[MERGE]'}
has_tag = any(title.lstrip().startswith(t) for t in APPROVED)
if not has_tag:
    derived = os.environ.get('AUTO_FIX_DERIVED_TAG', '').strip()
    if derived and derived in APPROVED:
        # Prepend derived tag, preserving existing title text after.
        title = f"{derived} {title.lstrip()}"

# Sentence-cap the description paragraph (first paragraph of rest).
def cap_paragraph(p, n):
    # Naive sentence split on '. ', '! ', '? '. Keep separators intact.
    sentences = re.split(r'(?<=[.!?])\s+', p.strip())
    if len(sentences) <= n:
        return p
    return ' '.join(sentences[:n])

if rest.strip():
    paragraphs = re.split(r'\n\s*\n', rest, maxsplit=1)
    first = paragraphs[0].strip()
    remainder = paragraphs[1] if len(paragraphs) > 1 else ''
    if first:
        first = cap_paragraph(first, max_sentences)
    rest = first + ('\n\n' + remainder if remainder else '')

# 7. Rewrite bullet imperative verbs to third-person present (best effort).
#    Covers the common verbs that appear in commit bodies. Skip lines that
#    are not bullets (lines not starting with '- ' or '* ' after leading
#    whitespace) and skip nested-quotation contexts.
VERB_MAP = {
    'add':     'Adds',
    'adds':    'Adds',
    'remove':  'Removes',
    'removes': 'Removes',
    'update':  'Updates',
    'updates': 'Updates',
    'fix':     'Fixes',
    'fixes':   'Fixes',
    'rename':  'Renames',
    'renames': 'Renames',
    'replace': 'Replaces',
    'replaces':'Replaces',
    'drop':    'Drops',
    'drops':   'Drops',
    'expose':  'Exposes',
    'exposes': 'Exposes',
    'introduce':'Introduces',
    'introduces':'Introduces',
    'wire':    'Wires',
    'wires':   'Wires',
    'move':    'Moves',
    'moves':   'Moves',
    'split':   'Splits',
    'splits':  'Splits',
    'merge':   'Merges',
    'merges':  'Merges',
    'tighten': 'Tightens',
    'tightens':'Tightens',
    'document':'Documents',
    'documents':'Documents',
    'land':    'Lands',
    'lands':   'Lands',
}

def rewrite_bullet_line(line):
    m = re.match(r'^(\s*[-*]\s+)(.*)$', line)
    if not m:
        return line
    prefix, content = m.group(1), m.group(2)
    # Detect the "path verb rest" anti-shape produced by lazy bullets.
    # Lift the path to its module name and promote the verb to third-
    # person present, producing a "Module: Verbs rest" line. This is a
    # best-effort fix; users can refine afterwards.
    path_verb = re.match(r'^([^\s:]+/[^\s:]+)\s+(\w+)\s+(.*)$', content)
    if path_verb:
        path, verb, rest_words = path_verb.group(1), path_verb.group(2), path_verb.group(3)
        basename = os.path.basename(path)
        if '.' not in basename:
            segs = [s for s in path.split('/') if s]
            if segs:
                basename = segs[-1]
        rewritten = VERB_MAP.get(verb.lower().strip(',.:;'), verb)
        return f"{prefix}{basename}: {rewritten} {rest_words}".rstrip()
    # Split at the first colon to preserve the "Symbol: description" shape.
    if ':' in content:
        head, _, tail = content.partition(':')
        # Don't touch the head (symbol name); rewrite the first word of tail.
        tail = tail.strip()
        words = tail.split(' ', 1)
        if words:
            first = words[0].lower().strip(',.:;')
            if first in VERB_MAP:
                rest_words = words[1] if len(words) > 1 else ''
                tail = f"{VERB_MAP[first]} {rest_words}".rstrip()
        return f"{prefix}{head}: {tail}"
    # No colon: rewrite the first word of the bullet itself.
    words = content.split(' ', 1)
    if words:
        first = words[0].lower().strip(',.:;')
        if first in VERB_MAP:
            rest_words = words[1] if len(words) > 1 else ''
            content = f"{VERB_MAP[first]} {rest_words}".rstrip()
    return f"{prefix}{content}"

new_rest_lines = []
for line in rest.split('\n'):
    new_rest_lines.append(rewrite_bullet_line(line))
rest = '\n'.join(new_rest_lines)

# 8. Trim top-level bullets that lead with a path. Heuristic: bullet text
#    starts with "src/" or "lib/" or includes "/" before the first space.
def trim_path_top_bullet(line):
    m = re.match(r'^(- )([^\s:]+/[^\s:]+)(.*)$', line)
    if not m:
        return line
    prefix, path, tail = m.group(1), m.group(2), m.group(3)
    basename = os.path.basename(path)
    # If the basename has no extension, prefer the parent dir name (module).
    if '.' not in basename:
        # Pick the deepest non-empty path segment.
        segs = [s for s in path.split('/') if s]
        if segs:
            basename = segs[-1]
    return f"{prefix}{basename}{tail}"

new_rest_lines = []
for line in rest.split('\n'):
    new_rest_lines.append(trim_path_top_bullet(line))
rest = '\n'.join(new_rest_lines)

# Reassemble. Always insert the blank-line separator between title and
# body when a body exists, so git stripspace + git log --format=%s
# recognize the subject line as separate from the description. Without
# the blank line, git treats the entire run-on as one subject and
# every downstream consumer (PR titles auto-derived from %s, release
# notes generators) inherits the corruption.
rest_stripped = rest.strip('\n')
new_body = title + ('\n\n' + rest_stripped if rest_stripped else '')

# Drop trailing whitespace on each line and trailing blank lines.
new_body = '\n'.join(line.rstrip() for line in new_body.split('\n')).rstrip() + '\n'

# Re-append the git-style comment block at the bottom (untouched).
if tail_comment_block:
    new_body += '\n' + '\n'.join(tail_comment_block) + '\n'

with open(msg_path, 'w', encoding='utf-8') as f:
    f.write(new_body)
PY
}

# Audit the message + diff against the unreconcilable-condition set. Returns
# 0 on pass, 1 on rejection. Prints a structured WHAT / WHY / DECIDE block
# to stderr on rejection so the developer sees exactly which fork to take.
audit_message() {
  local msg_file="$1"
  [ -f "$msg_file" ] || return 0

  local body
  body=$(_auto_fix_strip_comments "$msg_file")

  # Condition 1: empty or pure-boilerplate message.
  if _auto_fix_is_empty_or_boilerplate "$msg_file"; then
    cat >&2 <<EOF
X commit-msg auto-fix cannot reconcile this message.

WHAT:    The commit message is empty or contains only whitespace and
         comments. There is no prose to audit, scrub, or rewrite.

WHY:     The auto-fix layer needs at least a title and a 1-3 sentence
         description paragraph to produce a meaningful commit. It will
         not fabricate either; the description is the only signal of
         WHY the change was made.

DECIDE:  Rewrite the message with a title in the form '[TAG] Subject'
         and a 1-3 sentence description below it explaining the why.
         Then re-run 'git commit'.
EOF
    return 1
  fi

  # Condition 2: diff spans many top-level directories (non-atomicity smell).
  local top_dirs
  top_dirs=$(_auto_fix_count_top_dirs)
  if [ "$top_dirs" -ge 5 ]; then
    cat >&2 <<EOF
X commit-msg auto-fix cannot reconcile this commit.

WHAT:    The staged diff touches $top_dirs distinct top-level directories.
         A single atomic commit usually concentrates on one subsystem.

WHY:     The auto-fix layer can rewrite prose but cannot split a diff into
         separate commits. The git-commit-audit Section A rule (one logical
         change per commit) is the lens; only the developer can decide
         where the natural split lines are.

DECIDE:  Inspect 'git diff --cached --name-only', then either:
           (a) 'git reset HEAD <files>' to drop the unrelated parts and
               commit them in a separate follow-up, OR
           (b) confirm the change really is one logical refactor that
               spans these directories, then bypass this check by
               splitting the message into multiple paragraphs that
               explicitly call out each subsystem.
EOF
    return 1
  fi

  return 0
}
