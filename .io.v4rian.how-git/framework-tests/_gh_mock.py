#!/usr/bin/env python3
"""Mock gh CLI for offline e2e tests.

Implements just enough of the gh surface area to exercise the v4rian
template's GitHub-touching code paths (claim-main-release's Release
creation, auto-rebase-pools' PR list/create/edit/close/comment, build-
on-tag's release create/upload). State persists in a JSON file at
$GH_MOCK_STATE so multiple invocations within a test see consistent
state.

Supported commands:
  gh pr list [--state open|closed|all] [--base X] [--json ...]
  gh pr create --title T --body B --base BASE --head HEAD [--repo R]
  gh pr edit NUM --title T [--body B]
  gh pr close NUM [--comment C]
  gh pr view NUM [--json ...]
  gh pr comment NUM --body B
  gh release create TAG [--title T] [--generate-notes] [--notes N]
  gh release view TAG
  gh release upload TAG FILE...
  gh auth token
  gh --version
  gh api ...  (records the call, returns {})
"""

import json
import os
import sys

STATE = os.environ.get('GH_MOCK_STATE', '/tmp/.gh-mock-state.json')


def load():
    if not os.path.exists(STATE):
        return {'prs': [], 'releases': [], 'comments': [], 'next_pr': 1, 'api_calls': []}
    with open(STATE) as f:
        return json.load(f)


def save(s):
    with open(STATE, 'w') as f:
        json.dump(s, f, indent=2)


def parse_kv(args):
    """Pull --flag value pairs out of an arg list; positional args returned separately."""
    flags = {}
    pos = []
    i = 0
    while i < len(args):
        a = args[i]
        if a.startswith('--'):
            key = a[2:]
            if i + 1 < len(args) and not args[i + 1].startswith('--'):
                flags[key] = args[i + 1]
                i += 2
            else:
                flags[key] = True
                i += 1
        else:
            pos.append(a)
            i += 1
    return flags, pos


def cmd_pr_list(flags):
    state = load()
    target_state = flags.get('state', 'open')
    base_filter = flags.get('base')
    out = []
    for p in state['prs']:
        if target_state != 'all' and p['state'] != target_state:
            continue
        if base_filter and p['base'] != base_filter:
            continue
        out.append({
            'number': p['number'],
            'title': p['title'],
            'headRefName': p['head'],
            'baseRefName': p['base'],
            'mergeable': p.get('mergeable', 'MERGEABLE'),
            'body': p.get('body', ''),
        })
    print(json.dumps(out))
    return 0


def cmd_pr_create(flags):
    state = load()
    n = state['next_pr']
    state['next_pr'] += 1
    state['prs'].append({
        'number': n,
        'title': flags.get('title', ''),
        'body': flags.get('body', ''),
        'head': flags.get('head', ''),
        'base': flags.get('base', ''),
        'state': 'open',
        'mergeable': 'MERGEABLE',
    })
    save(state)
    repo = flags.get('repo', 'mock/repo')
    print(f'https://github.com/{repo}/pull/{n}')
    return 0


def cmd_pr_edit(flags, pos):
    if not pos:
        return 1
    n = int(pos[0])
    state = load()
    for p in state['prs']:
        if p['number'] == n:
            if 'title' in flags:
                p['title'] = flags['title']
            if 'body' in flags:
                p['body'] = flags['body']
            save(state)
            print(f'edited PR #{n}')
            return 0
    return 1


def cmd_pr_close(flags, pos):
    if not pos:
        return 1
    n = int(pos[0])
    state = load()
    for p in state['prs']:
        if p['number'] == n:
            p['state'] = 'closed'
            if 'comment' in flags:
                state['comments'].append({'pr': n, 'body': flags['comment']})
            save(state)
            print(f'closed PR #{n}')
            return 0
    return 1


def cmd_pr_merge(flags, pos):
    if not pos:
        return 1
    n = int(pos[0])
    state = load()
    for p in state['prs']:
        if p['number'] == n:
            p['state'] = 'merged'
            save(state)
            print(f'merged PR #{n}')
            return 0
    return 1


def cmd_pr_ready(flags, pos):
    if not pos:
        return 1
    n = int(pos[0])
    state = load()
    for p in state['prs']:
        if p['number'] == n:
            p['draft'] = False
            save(state)
            return 0
    return 1


def cmd_pr_view(flags, pos):
    if not pos:
        return 1
    n = int(pos[0])
    state = load()
    for p in state['prs']:
        if p['number'] == n:
            # Output in gh's standard shape: head -> headRefName, base -> baseRefName
            out = {
                'number': p['number'],
                'title': p['title'],
                'body': p.get('body', ''),
                'headRefName': p['head'],
                'baseRefName': p['base'],
                'state': p['state'],
                'mergeable': p.get('mergeable', 'MERGEABLE'),
            }
            print(json.dumps(out))
            return 0
    return 1


def cmd_pr_comment(flags, pos):
    if not pos:
        return 1
    n = int(pos[0])
    state = load()
    state['comments'].append({'pr': n, 'body': flags.get('body', '')})
    save(state)
    return 0


def cmd_release_create(flags, pos):
    if not pos:
        return 1
    tag = pos[0]
    state = load()
    state['releases'].append({
        'tag': tag,
        'title': flags.get('title', tag),
        'notes': flags.get('notes', ''),
        'generated_notes': flags.get('generate-notes', False),
        'assets': [],
    })
    save(state)
    print(f'release {tag} created')
    return 0


def cmd_release_view(flags, pos):
    if not pos:
        return 1
    tag = pos[0]
    state = load()
    for r in state['releases']:
        if r['tag'] == tag:
            print(json.dumps(r))
            return 0
    return 1


def cmd_release_upload(flags, pos):
    if not pos:
        return 1
    tag = pos[0]
    files = pos[1:]
    state = load()
    for r in state['releases']:
        if r['tag'] == tag:
            r['assets'].extend(files)
            save(state)
            return 0
    return 1


def cmd_auth_token():
    print('mock-token-xxxxx')
    return 0


def cmd_api(args):
    state = load()
    state['api_calls'].append({'args': args})
    save(state)
    print('{}')
    return 0


def main():
    args = sys.argv[1:]
    if not args:
        print('mock-gh: missing command', file=sys.stderr)
        return 1
    if args == ['--version']:
        print('gh version mock 1.0.0')
        return 0
    if args[0] == 'api':
        return cmd_api(args[1:])

    if len(args) < 2:
        print(f'mock-gh: incomplete: {args}', file=sys.stderr)
        return 1

    cmd, sub = args[0], args[1]
    flags, pos = parse_kv(args[2:])
    key = f'{cmd}-{sub}'

    dispatch = {
        'pr-list': lambda: cmd_pr_list(flags),
        'pr-create': lambda: cmd_pr_create(flags),
        'pr-edit': lambda: cmd_pr_edit(flags, pos),
        'pr-close': lambda: cmd_pr_close(flags, pos),
        'pr-merge': lambda: cmd_pr_merge(flags, pos),
        'pr-ready': lambda: cmd_pr_ready(flags, pos),
        'pr-view': lambda: cmd_pr_view(flags, pos),
        'pr-comment': lambda: cmd_pr_comment(flags, pos),
        'release-create': lambda: cmd_release_create(flags, pos),
        'release-view': lambda: cmd_release_view(flags, pos),
        'release-upload': lambda: cmd_release_upload(flags, pos),
        'auth-token': cmd_auth_token,
    }

    fn = dispatch.get(key)
    if fn is None:
        print(f'mock-gh: unsupported: {cmd} {sub}', file=sys.stderr)
        return 1
    return fn()


if __name__ == '__main__':
    sys.exit(main())
