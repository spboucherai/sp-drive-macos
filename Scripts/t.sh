#!/usr/bin/env bash
# Author: Simon-Pierre Boucher — contact@spboucher.ai
# File: Scripts/t.sh
# Description: Runs `swift test` with an optional filter and a time limit, printing only verdict lines.
#
# Usage: Scripts/t.sh [filter] [seconds] [lines]     (integration tests need Scripts/backend-dev.sh start)
cd "$(dirname "$0")/.."
LIMIT="${2:-300}"; LOG=/tmp/spdrive-test.log
perl -e 'alarm shift; exec @ARGV' "$LIMIT" swift test ${1:+--filter "$1"} > "$LOG" 2>&1
STATUS=$?
if [ $STATUS -eq 142 ]; then echo "TIMEOUT after ${LIMIT}s" >> "$LOG"; fi
sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -E "error|failed|Executed .* tests|TIMEOUT|Fatal|passed \(" | grep -vE "Test Suite|^error: Process|SwiftCompile|' passed" | sed -E "s#$PWD/##" | cut -c1-400 | awk '!seen[$0]++' | tail -${3:-40}
exit $STATUS
