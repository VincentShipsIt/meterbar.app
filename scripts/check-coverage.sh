#!/usr/bin/env bash
set -euo pipefail

THRESHOLD="${COVERAGE_THRESHOLD:-80}"

swift test --enable-code-coverage

BIN_PATH="$(swift build --show-bin-path)"
if [ -z "$BIN_PATH" ]; then
  echo "Failed to resolve Swift build output path." >&2
  exit 1
fi

PROFDATA="$BIN_PATH/codecov/default.profdata"
if [ ! -f "$PROFDATA" ]; then
  echo "Coverage data not found at $PROFDATA" >&2
  exit 1
fi

TEST_BUNDLE="$(find "$BIN_PATH" -maxdepth 2 -name "*Tests.xctest" -print -quit)"
if [ -z "$TEST_BUNDLE" ]; then
  echo "Test bundle not found under $BIN_PATH." >&2
  exit 1
fi

TEST_BINARY_NAME="$(basename "$TEST_BUNDLE" .xctest)"
TEST_BINARY="$TEST_BUNDLE/Contents/MacOS/$TEST_BINARY_NAME"
if [ ! -f "$TEST_BINARY" ]; then
  echo "Test binary not found at $TEST_BINARY" >&2
  exit 1
fi

# Parse the JSON summary rather than the text table: `llvm-cov report` column
# order varies between LLVM versions (a trailing branch-coverage column made
# `awk '{print $NF}'` read "-" and fail the gate with "Coverage: -%").
COVERAGE_PERCENT="$(xcrun llvm-cov export "$TEST_BINARY" \
  -instr-profile "$PROFDATA" \
  -summary-only \
  -ignore-filename-regex ".*Tests.*" \
  | python3 -c 'import json,sys; print(f'"'"'{json.load(sys.stdin)["data"][0]["totals"]["lines"]["percent"]:.1f}'"'"')')"
if [ -z "$COVERAGE_PERCENT" ]; then
  echo "Failed to parse coverage report." >&2
  exit 1
fi

printf "Coverage: %s%% (threshold: %s%%)\n" "$COVERAGE_PERCENT" "$THRESHOLD"

awk -v coverage="$COVERAGE_PERCENT" -v threshold="$THRESHOLD" 'BEGIN {exit !(coverage+0 >= threshold+0)}'
