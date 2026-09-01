#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmpdir="$(mktemp -d)"
# The store tests write only to their own suite; delete it afterwards so
# test runs leave no plist behind.
trap 'rm -rf "$tmpdir"; defaults delete agentisland-browser-profile-tests >/dev/null 2>&1 || true' EXIT

swiftc \
    Sources/Usage/BrowserProfileResolver.swift \
    Sources/Model/ClaudeLoginTargetStore.swift \
    Tests/BrowserProfileResolverTests.swift \
    -o "$tmpdir/browser-profile-tests"

"$tmpdir/browser-profile-tests"
