#!/usr/bin/env bash
# Source from a test to enable the gh mock. Creates a tmp dir with a
# `gh` shim that delegates to _gh_mock.py, prepends to PATH, sets
# GH_MOCK_STATE to a fresh empty state file.
#
# Usage in a test:
#   . "$TEMPLATE_ROOT/.io.v4rian.how-git/framework-tests/_gh_mock_enable.sh"
#
# Cleans up automatically via a trap on EXIT.

GH_MOCK_DIR=$(mktemp -d -t v4rian-gh-mock-XXXXXX)
GH_MOCK_STATE="$GH_MOCK_DIR/state.json"
export GH_MOCK_STATE

echo '{"prs":[],"releases":[],"comments":[],"next_pr":1,"api_calls":[]}' > "$GH_MOCK_STATE"

cat > "$GH_MOCK_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
exec python3 "$(dirname "$0")/_gh_mock.py" "$@"
SHIM
chmod +x "$GH_MOCK_DIR/gh"
cp "$TEMPLATE_ROOT/.io.v4rian.how-git/framework-tests/_gh_mock.py" "$GH_MOCK_DIR/_gh_mock.py"

export PATH="$GH_MOCK_DIR:$PATH"

trap 'rm -rf "$GH_MOCK_DIR" 2>/dev/null' EXIT
