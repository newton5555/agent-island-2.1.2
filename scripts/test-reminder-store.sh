#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmpdir="$(mktemp -d)"
# The unbundled test binary gets a process-name UserDefaults domain; delete
# it afterwards so test runs leave no plist behind.
trap 'rm -rf "$tmpdir"; defaults delete agentisland-reminder-store-tests >/dev/null 2>&1 || true' EXIT

swiftc \
    Sources/Model/AgentReminderStore.swift \
    Sources/Localization/L10n.swift \
    Sources/Model/AppLanguageStore.swift \
    Tests/AgentReminderStoreTests.swift \
    -o "$tmpdir/agentisland-reminder-store-tests"

"$tmpdir/agentisland-reminder-store-tests"
