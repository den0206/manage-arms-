#!/bin/bash
# Install the requested CLI into a disposable prefix, then exercise it in a separate fake home.
# Usage: ./scripts/check-agent-compatibility.sh claude|codex|gemini [version]
set -euo pipefail
cd "$(dirname "$0")/.."
agent="${1:?Specify claude, codex or gemini}"
version="${2:-latest}"
case "$agent" in
  claude) package='@anthropic-ai/claude-code' ;;
  codex) package='@openai/codex' ;;
  gemini) package='@google/gemini-cli' ;;
  *) echo "Unknown agent: $agent" >&2; exit 1 ;;
esac
compat_dir="$(mktemp -d)"
trap 'rm -rf "$compat_dir"' EXIT
npm install --prefix "$compat_dir" --cache "$compat_dir/npm-cache" --no-audit --no-fund "$package@$version"
COMPAT_AGENT="$agent" PATH="$compat_dir/node_modules/.bin:$PATH" swift test --filter AgentCompatibilityTests
