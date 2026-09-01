#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

swiftc \
    Sources/Model/DisplayProvider.swift \
    Tests/ProviderSelectionTests.swift \
    -o "$test_dir/provider-selection-tests"

"$test_dir/provider-selection-tests"
