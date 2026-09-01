#!/bin/bash
# Build and smoke-launch the app for 1 second, then kill it.
# Used after every commit to confirm the binary launches without crashing.
# (AgentIsland is a forever-running background overlay, so we can't just `./binary`.)

set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/test-usage-cache.sh
./scripts/test-session-turn-state.sh
./scripts/test-reminder-delivery-key.sh
./scripts/test-report-slice.sh
./scripts/test-grok-parsing.sh
./scripts/test-antigravity-parsing.sh
./scripts/test-cursor-parsing.sh
./scripts/test-provider-selection.sh
./scripts/test-reminder-store.sh
./scripts/test-browser-profiles.sh
./scripts/test-claude-keychain-discovery.sh
./build.sh

BIN="./build/AgentIsland.app/Contents/MacOS/AgentIsland"
# Demo mode: the smoke instance shares the real user's defaults/keychain, so a
# plain launch can catch-up-fire a real `--dangerously-skip-permissions`
# resume or interrupt a Claude refresh-token rotation mid-write. Demo skips
# network/keychain work and TriggerEngine refuses to fire outside normal mode,
# while the binary under test stays the same release build.
AGENTISLAND_DEMO=1 "$BIN" >/dev/null 2>&1 &
PID=$!
sleep 1
if kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    echo "✓ launched cleanly"
else
    wait "$PID" 2>/dev/null || true
    echo "✗ binary exited before 1s — likely a crash"
    exit 1
fi
