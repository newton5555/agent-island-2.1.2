#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

swiftc \
    Sources/Usage/GrokBilling.swift \
    Sources/Usage/AntigravityCredentials.swift \
    Sources/Usage/AntigravityQuota.swift \
    Sources/Trigger/SessionTurnState.swift \
    Tests/SessionScannerStubs.swift \
    Sources/Trigger/SessionScanner.swift \
    Tests/AntigravityParsingTests.swift \
    -o "$tmpdir/gemini-parsing-tests"

"$tmpdir/gemini-parsing-tests"
