#!/bin/sh
set -eu
vsix=${1:-vsix/agent-tool.vsix}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
unzip -q "$vsix" -d "$tmp"
cli="$tmp/extension/bin/agent-tool-core"
test -x "$cli"
result=$(printf '{}' | "$cli" version)
printf '%s' "$result" | grep -q '"protocolVersion":"1"'
printf '%s\n' "✓ VSIX同梱CLIのversion応答を確認"
