#!/usr/bin/env bash
# Thin wrapper kept for muscle memory. The real installer is claude_patch.py,
# which is cross-platform (macOS / Linux / Windows, x64+arm64, glibc+musl).
#
#   bash patch-claude-routing.sh                 # patch the active installation
#   bash patch-claude-routing.sh /path/to/binary # patch a specific binary
#   bash patch-claude-routing.sh --update [VER]  # download from npm + install + patch
#
# On Windows use the Python entrypoint directly:
#   python claude_patch.py --update
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/claude_patch.py" "$@"
