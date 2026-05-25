#!/usr/bin/env python3
# ci-dispatch-matrix-build.py
#
# Reads TAB-separated tuples from stdin (one per discovered script,
# as emitted by ci-dispatch.sh --list) and prints a JSON
# {"include": [...]} value suitable for a GitHub Actions strategy.matrix.
#
# Pulled out of ci-dispatch.yml's inline run block because YAML block
# scalars terminate at the first line that dedents below the block
# indent, and a Python heredoc with unindented top-level statements
# kills the block early. Keeping the script in its own file sidesteps
# the YAML / Python indentation collision entirely.

import json
import sys


def main() -> int:
    out = []
    for line in sys.stdin.read().splitlines():
        if not line.strip():
            continue
        parts = line.split('\t')
        if len(parts) < 6:
            continue
        layer, kind, path, name, req, bn = parts[:6]
        out.append({
            'layer': layer,
            'kind': kind,
            'script': path,
            'check': name,
            'required': req,
            'basename': bn,
        })
    print(json.dumps({'include': out}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
