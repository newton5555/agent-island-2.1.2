#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

swiftc \
    Sources/Usage/GrokBilling.swift \
    Sources/Usage/GrokAuthFile.swift \
    Tests/GrokParsingTests.swift \
    -o "$tmpdir/grok-parsing-tests"

"$tmpdir/grok-parsing-tests"
