#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

swiftc \
    Sources/Cost/TokenEvent.swift \
    Sources/Cost/Pricing.swift \
    Sources/Cost/CostUsage.swift \
    Sources/Cost/CostBucketing.swift \
    Sources/Cost/CostSummary.swift \
    Sources/Localization/L10n.swift \
    Sources/Model/AppLanguageStore.swift \
    Tests/CostReportSliceTests.swift \
    -o "$tmpdir/cost-report-slice-tests"

"$tmpdir/cost-report-slice-tests"
