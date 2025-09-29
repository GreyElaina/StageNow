#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Toggle Stage Manager (Current Space)
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 🪄
# @raycast.packageName Stage Manager
# @raycast.description Toggle Stage Manager for the currently active macOS space

# Documentation:
# @raycast.author Stage Manager
# @raycast.authorURL https://github.com/GreyElaina

set -euo pipefail

STAGE_MANAGER_BIN="${STAGE_MANAGER_BIN:-StageManager}"

if command -v "$STAGE_MANAGER_BIN" >/dev/null 2>&1; then
  "$STAGE_MANAGER_BIN" --toggle
  exit $?
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ -x "$REPO_ROOT/.build/release/StageManager" ]; then
  "$REPO_ROOT/.build/release/StageManager" --toggle
  exit $?
fi

if [ -x "$REPO_ROOT/.build/debug/StageManager" ]; then
  "$REPO_ROOT/.build/debug/StageManager" --toggle
  exit $?
fi

if command -v swift >/dev/null 2>&1; then
  (cd "$REPO_ROOT" && swift run StageManager --toggle)
  exit $?
fi

echo "StageManager CLI not found. Set STAGE_MANAGER_BIN or build the project (swift build)." >&2
exit 1
