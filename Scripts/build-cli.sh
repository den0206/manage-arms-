#!/bin/sh
set -eu
swift build -c release --product AgentToolCoreCLI
mkdir -p bin
cp .build/release/AgentToolCoreCLI bin/agent-tool-core
chmod +x bin/agent-tool-core
