#!/usr/bin/env bats
# Unit tests for circuit breaker output token trend tracking
# Tests that output_lengths are tracked and output decline triggers circuit breaker

load '../helpers/test_helper'

SCRIPT_DIR="${BATS_TEST_DIRNAME}/../../lib"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-output-trends.XXXXXX)"
    cd "$TEST_TEMP_DIR"

    export RALPH_DIR=".ralph"
    export CB_STATE_FILE="$RALPH_DIR/.circuit_breaker_state"
    export CB_HISTORY_FILE="$RALPH_DIR/.circuit_breaker_history"
    export RESPONSE_ANALYSIS_FILE="$RALPH_DIR/.response_analysis"
    mkdir -p "$RALPH_DIR"

    # Source the actual library files
    source "$SCRIPT_DIR/date_utils.sh"
    source "$SCRIPT_DIR/circuit_breaker.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Helper: Create a CLOSED state with output_lengths history
create_state_with_history() {
    local output_lengths_json="${1:-[]}"
    local no_progress="${2:-0}"
    cat > "$CB_STATE_FILE" << EOF
{
    "state": "CLOSED",
    "last_change": "$(get_iso_timestamp)",
    "consecutive_no_progress": $no_progress,
    "consecutive_same_error": 0,
    "consecutive_permission_denials": 0,
    "last_progress_loop": 0,
    "total_opens": 0,
    "output_lengths": $output_lengths_json,
    "reason": ""
}
EOF
    echo '[]' > "$CB_HISTORY_FILE"
}

# ==========================================================================
# output_lengths tracking tests
# ==========================================================================

@test "output trend: init_circuit_breaker creates state with output_lengths" {
    init_circuit_breaker
    local output_lengths
    output_lengths=$(jq -r '.output_lengths' "$CB_STATE_FILE")
    [ "$output_lengths" = "[]" ]
}

@test "output trend: record_loop_result stores output_length in history" {
    init_circuit_breaker
    # Simulate a loop with 1000 bytes output and file changes (progress)
    echo '{}' > "$RESPONSE_ANALYSIS_FILE"
    record_loop_result 1 1 false 1000

    local output_lengths
    output_lengths=$(jq '.output_lengths' "$CB_STATE_FILE")
    [ "$(echo "$output_lengths" | jq 'length')" -eq 1 ]
    [ "$(echo "$output_lengths" | jq '.[0]')" -eq 1000 ]
}

@test "output trend: accumulates multiple output lengths" {
    init_circuit_breaker
    echo '{}' > "$RESPONSE_ANALYSIS_FILE"
    record_loop_result 1 1 false 1000
    record_loop_result 2 1 false 900
    record_loop_result 3 1 false 800

    local count
    count=$(jq '.output_lengths | length' "$CB_STATE_FILE")
    [ "$count" -eq 3 ]
}

@test "output trend: keeps only last 5 entries" {
    create_state_with_history '[100, 200, 300, 400, 500]'
    echo '{}' > "$RESPONSE_ANALYSIS_FILE"
    record_loop_result 6 1 false 600

    local count
    count=$(jq '.output_lengths | length' "$CB_STATE_FILE")
    [ "$count" -eq 5 ]
    # Oldest entry (100) should be dropped, newest (600) added
    [ "$(jq '.output_lengths[0]' "$CB_STATE_FILE")" -eq 200 ]
    [ "$(jq '.output_lengths[4]' "$CB_STATE_FILE")" -eq 600 ]
}

@test "output trend: handles zero output_length gracefully" {
    init_circuit_breaker
    echo '{}' > "$RESPONSE_ANALYSIS_FILE"
    record_loop_result 1 1 false 0

    # Zero output should not be added to history
    local count
    count=$(jq '.output_lengths | length' "$CB_STATE_FILE")
    [ "$count" -eq 0 ]
}

@test "output trend: handles missing output_lengths field in old state" {
    # Simulate old state file without output_lengths
    cat > "$CB_STATE_FILE" << EOF
{
    "state": "CLOSED",
    "last_change": "$(get_iso_timestamp)",
    "consecutive_no_progress": 0,
    "consecutive_same_error": 0,
    "consecutive_permission_denials": 0,
    "last_progress_loop": 0,
    "total_opens": 0,
    "reason": ""
}
EOF
    echo '[]' > "$CB_HISTORY_FILE"
    echo '{}' > "$RESPONSE_ANALYSIS_FILE"

    # Should not crash, should add output_length
    record_loop_result 1 1 false 500
    local count
    count=$(jq '.output_lengths | length' "$CB_STATE_FILE")
    [ "$count" -eq 1 ]
}

# ==========================================================================
# Output decline detection tests
# ==========================================================================

@test "output trend: no decline with stable output" {
    # Average of [1000, 1000] = 1000, current = 1000 → 0% decline
    create_state_with_history '[1000, 1000]'
    echo '{}' > "$RESPONSE_ANALYSIS_FILE"
    record_loop_result 3 0 false 1000

    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    # No progress (0 files) but only 1 consecutive no progress, should stay CLOSED
    [ "$state" = "CLOSED" ]
}

@test "output trend: decline below threshold does not trigger output decline reason" {
    # Average of [1000, 1000] = 1000, current = 500 → 50% decline (< 70%)
    # 3 consecutive no-progress → OPEN via no_progress threshold, not output decline
    create_state_with_history '[1000, 1000]' 2
    echo '{}' > "$RESPONSE_ANALYSIS_FILE"
    record_loop_result 3 0 false 500 || true  # Expect OPEN → return 1

    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [ "$state" = "OPEN" ]
    # The reason should mention no progress, not output decline
    local reason
    reason=$(jq -r '.reason' "$CB_STATE_FILE")
    [[ "$reason" == *"No progress"* ]]
}

@test "output trend: decline at threshold triggers with no-progress" {
    # Average of [1000, 1000] = 1000, current = 200 → 80% decline (>= 70%)
    # Plus 2 consecutive no-progress → should open circuit via output decline
    # Note: output decline check fires before the standard no_progress>=3 threshold
    # because it only requires no_progress>=2 combined with decline
    create_state_with_history '[1000, 1000]' 1
    echo '{}' > "$RESPONSE_ANALYSIS_FILE"
    record_loop_result 3 0 false 200 || true  # Expect OPEN → return 1

    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [ "$state" = "OPEN" ]
    local reason
    reason=$(jq -r '.reason' "$CB_STATE_FILE")
    [[ "$reason" == *"Output declined"* ]]
}

@test "output trend: decline does NOT trigger without no-progress" {
    # 80% decline but files were changed (progress), so no trigger
    create_state_with_history '[1000, 1000]' 0
    echo '{}' > "$RESPONSE_ANALYSIS_FILE"
    record_loop_result 3 5 false 200  # 5 files changed = progress

    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [ "$state" = "CLOSED" ]
}

@test "output trend: needs at least 2 history entries for decline check" {
    # Only 1 history entry → no decline check, but 3 consecutive no-progress → OPEN
    create_state_with_history '[1000]' 2
    echo '{}' > "$RESPONSE_ANALYSIS_FILE"
    record_loop_result 3 0 false 100 || true  # Expect OPEN → return 1

    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [ "$state" = "OPEN" ]
    local reason
    reason=$(jq -r '.reason' "$CB_STATE_FILE")
    # With only 1 history entry, output decline is skipped → should be standard no-progress
    [[ "$reason" == *"No progress"* ]]
}

# ==========================================================================
# Reset and display tests
# ==========================================================================

@test "output trend: reset_circuit_breaker clears output_lengths" {
    create_state_with_history '[100, 200, 300]'
    reset_circuit_breaker "test reset"

    local count
    count=$(jq '.output_lengths | length' "$CB_STATE_FILE")
    [ "$count" -eq 0 ]
}

@test "output trend: show_circuit_status displays output trend" {
    create_state_with_history '[1000, 800, 600]'
    run show_circuit_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Output trend"* ]]
    [[ "$output" == *"1000"* ]]
}

@test "output trend: show_circuit_status shows 'no data' when empty" {
    init_circuit_breaker
    run show_circuit_status
    [[ "$output" == *"no data"* ]]
}

@test "output trend: CB_OUTPUT_DECLINE_THRESHOLD is configurable" {
    # Set a very low threshold (10%)
    export CB_OUTPUT_DECLINE_THRESHOLD=10
    # Average of [1000, 1000] = 1000, current = 800 → 20% decline (>= 10%)
    # Set no_progress=1 so it reaches 2 after increment, which is the minimum for decline trigger
    create_state_with_history '[1000, 1000]' 1
    echo '{}' > "$RESPONSE_ANALYSIS_FILE"
    record_loop_result 3 0 false 800 || true  # Expect OPEN → return 1

    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [ "$state" = "OPEN" ]
    local reason
    reason=$(jq -r '.reason' "$CB_STATE_FILE")
    [[ "$reason" == *"Output declined"* ]]
}
