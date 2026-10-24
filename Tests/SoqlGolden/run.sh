#!/bin/sh
# Builds the SOQL golden-file tests and runs them. Exits non-zero if any file differs.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../SwiftSoql"
out="$(mktemp -d)"
swiftc -O -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature MemberImportVisibility \
    "$src/Salesforce/JSONValue.swift" "$src/Salesforce/DescribeModels.swift" "$src"/Soql/*.swift \
    "$here/main.swift" -o "$out/soql-golden"
"$out/soql-golden" "$here/golden" "$out"
