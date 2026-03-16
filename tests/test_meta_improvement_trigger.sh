#!/usr/bin/env bash
# test_meta_improvement_trigger.sh
# Phase 22.2 — verify meta-improvement fires on loop 10 (and multiples thereof)
set -euo pipefail

# ── Setup ────────────────────────────────────────────────────────────────────
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

RALPH_DIR="$TMPDIR_TEST/.ralph"
mkdir -p "$RALPH_DIR"

# Stub out the files that improvement_journal.sh references
IMPROVEMENT_JOURNAL_FILE="$RALPH_DIR/improvement_journal.jsonl"
SUCCESSFUL_LOOP_COUNT_FILE="$RALPH_DIR/.successful_loop_count"
touch "$IMPROVEMENT_JOURNAL_FILE"
echo "0" > "$SUCCESSFUL_LOOP_COUNT_FILE"

# Source the library (disable errexit for sourcing — some funcs may have non-zero returns)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set +e
# shellcheck source=../lib/improvement_journal.sh
source "$SCRIPT_DIR/lib/improvement_journal.sh"
set -e

# ── Helpers ──────────────────────────────────────────────────────────────────
PASS=0
FAIL=0

assert_true() {
    local desc="$1"
    shift
    if "$@"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected true)"
        FAIL=$((FAIL + 1))
    fi
}

assert_false() {
    local desc="$1"
    shift
    if ! "$@"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected false)"
        FAIL=$((FAIL + 1))
    fi
}

# ── Tests ─────────────────────────────────────────────────────────────────────
echo ""
echo "=== Test: should_run_meta_improvement ==="
echo ""

RALPH_META_IMPROVEMENT_INTERVAL=10

# At count=0 — should NOT fire
echo "0" > "$SUCCESSFUL_LOOP_COUNT_FILE"
assert_false "should NOT fire at count=0" should_run_meta_improvement

# At count=5 — should NOT fire
echo "5" > "$SUCCESSFUL_LOOP_COUNT_FILE"
assert_false "should NOT fire at count=5" should_run_meta_improvement

# At count=9 — should NOT fire
echo "9" > "$SUCCESSFUL_LOOP_COUNT_FILE"
assert_false "should NOT fire at count=9" should_run_meta_improvement

# At count=10 — SHOULD fire
echo "10" > "$SUCCESSFUL_LOOP_COUNT_FILE"
assert_true "SHOULD fire at count=10" should_run_meta_improvement

# At count=11 — should NOT fire
echo "11" > "$SUCCESSFUL_LOOP_COUNT_FILE"
assert_false "should NOT fire at count=11" should_run_meta_improvement

# At count=20 — SHOULD fire (second multiple)
echo "20" > "$SUCCESSFUL_LOOP_COUNT_FILE"
assert_true "SHOULD fire at count=20" should_run_meta_improvement

# At count=30 — SHOULD fire (third multiple)
echo "30" > "$SUCCESSFUL_LOOP_COUNT_FILE"
assert_true "SHOULD fire at count=30" should_run_meta_improvement

echo ""
echo "=== Test: increment_successful_loops ==="
echo ""

echo "0" > "$SUCCESSFUL_LOOP_COUNT_FILE"
result=$(increment_successful_loops)
if [[ "$result" == "1" ]]; then
    echo "  PASS: increment from 0 returns 1"
    ((PASS++))
else
    echo "  FAIL: increment from 0 expected 1, got $result"
    ((FAIL++))
fi

# Increment 9 more times to reach 10
for i in 2 3 4 5 6 7 8 9 10; do
    increment_successful_loops > /dev/null
done

# Now should fire
assert_true "SHOULD fire after 10 increments" should_run_meta_improvement

# Verify file was updated
count_on_disk=$(cat "$SUCCESSFUL_LOOP_COUNT_FILE")
if [[ "$count_on_disk" == "10" ]]; then
    echo "  PASS: count file shows 10 after 10 increments"
    ((PASS++))
else
    echo "  FAIL: count file shows $count_on_disk, expected 10"
    ((FAIL++))
fi

# ── Custom interval test ──────────────────────────────────────────────────────
echo ""
echo "=== Test: custom interval (RALPH_META_IMPROVEMENT_INTERVAL=5) ==="
echo ""

RALPH_META_IMPROVEMENT_INTERVAL=5
echo "5" > "$SUCCESSFUL_LOOP_COUNT_FILE"
assert_true "SHOULD fire at count=5 with interval=5" should_run_meta_improvement

echo "6" > "$SUCCESSFUL_LOOP_COUNT_FILE"
assert_false "should NOT fire at count=6 with interval=5" should_run_meta_improvement

echo "10" > "$SUCCESSFUL_LOOP_COUNT_FILE"
assert_true "SHOULD fire at count=10 with interval=5" should_run_meta_improvement

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
