#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

swiftc \
    Sources/Usage/ClaudeKeychainDiscovery.swift \
    Tests/ClaudeKeychainDiscoveryTests.swift \
    -o "$tmpdir/claude-keychain-discovery-tests"

"$tmpdir/claude-keychain-discovery-tests"
