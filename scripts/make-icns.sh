#!/bin/bash
# Regenerate Resources/AgentIsland.icns from the five-blade mark PNGs
# (Resources/agentisland_logo.png + agentisland_logo_small.png) via the
# composer in scripts/compose-appicon.swift. Run after either mark changes.
#
# The pre-2026-08-09 flow that sourced Assets/agentisland-app-icon-*.png is
# retired with the old brand — the icon is composed, not hand-painted.

set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
ICONSET="$TMP/AgentIsland.iconset"
mkdir "$ICONSET"

swift scripts/compose-appicon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o Resources/AgentIsland.icns
rm -rf "$TMP"

echo "✓ Resources/AgentIsland.icns  ($(du -h Resources/AgentIsland.icns | cut -f1))"
