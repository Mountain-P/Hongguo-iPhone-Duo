#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/hongguo-player-range.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
swiftc -module-cache-path "$test_dir/module-cache" \
  iOS/Hongguo/Player/MediaByteRange.swift scripts/test-player-range.swift \
  -o "$test_dir/range-checks"
"$test_dir/range-checks"
