#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# CursorUsageFetcher pulls in L10n for the transport error caption; the
# resolver files ride along to satisfy it.
swiftc \
    Sources/Usage/CursorCredentials.swift \
    Sources/Usage/CursorUsageFetcher.swift \
    Sources/Localization/L10n.swift \
    Sources/Model/AppLanguageStore.swift \
    Tests/CursorParsingTests.swift \
    -o "$tmpdir/cursor-parsing-tests"

"$tmpdir/cursor-parsing-tests"
