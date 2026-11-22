#!/bin/sh
# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT
#
# swift test with code coverage, writing under coverage/ (where the reusable CI
# uploads from): Swift Testing results as coverage/junit-swift-testing.xml
# (XCTest's, empty here, as coverage/junit.xml) and line coverage of Sources/
# as coverage/lcov.info, from the pinned toolchain's llvm-cov (or Xcode's).
#
# The toolchain's swift archetype script (.mise/archetypes/swift/scripts/
# test.sh) looks for a <Package>PackageTests.xctest bundle; SwiftPM 6.4's build
# backend names it after the test target (AutoDJKitTests.xctest), so this copy
# finds any *.xctest in the bin directory.
#
# SWIFT_TEST_FLAGS: extra `swift test` flags for one run, word-split on
# purpose (`SWIFT_TEST_FLAGS="--filter Alignment" mise run test`).
set -eu

mkdir -p coverage
# shellcheck disable=SC2086 # SWIFT_TEST_FLAGS is a flag list
swift test --enable-code-coverage --xunit-output coverage/junit.xml ${SWIFT_TEST_FLAGS:-}

bin="$(swift build --show-bin-path)"
profdata="$bin/codecov/default.profdata"
set --
for bundle in "$bin"/*.xctest; do
  if [ -d "$bundle" ]; then
    set -- "$@" -object "$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"
  fi
done

if [ "$#" -eq 0 ] || [ ! -f "$profdata" ]; then
  echo "test: no test bundle or coverage profile produced" >&2
  exit 1
fi

# llvm-cov sits beside swift in the toolchain; fall back to Xcode's.
llvm_cov=$(command -v llvm-cov || true)
if [ -z "$llvm_cov" ]; then
  swift_path=$(command -v swift)
  real_swift=$(readlink -f "$swift_path" 2>/dev/null || printf '%s' "$swift_path")
  if [ -x "$(dirname "$real_swift")/llvm-cov" ]; then
    llvm_cov="$(dirname "$real_swift")/llvm-cov"
  else
    llvm_cov=$(xcrun --find llvm-cov)
  fi
fi

"$llvm_cov" export -format=lcov -instr-profile="$profdata" \
  -ignore-filename-regex='\.build/|/Tests/' "$@" >coverage/lcov.info
echo "test: coverage written to coverage/lcov.info"
