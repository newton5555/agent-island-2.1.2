#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

swiftc \
    Sources/Model/ReminderDeliveryKey.swift \
    Tests/ReminderDeliveryKeyTests.swift \
    -o "$tmpdir/reminder-delivery-key-tests"

"$tmpdir/reminder-delivery-key-tests"
