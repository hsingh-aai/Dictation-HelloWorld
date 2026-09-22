#!/bin/bash
# The definition of green: the package builds with no warnings and every test passes.
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
output="$(swift build 2>&1)" || { echo "$output"; exit 1; }
if grep -q "warning:" <<<"$output"; then echo "$output" | grep "warning:"; echo "✘ warnings"; exit 1; fi
swift test
