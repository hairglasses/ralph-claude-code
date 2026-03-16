#!/usr/bin/env bats
# Unit tests for budget tracking (--max-cost) and runtime limits (--max-hours)
# Also covers stale call counter detection improvement

load '../helpers/test_helper'
load '../helpers/fixtures'

# Path to ralph_loop.sh
RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize git repo
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Set up environment with .ralph/ subfolder structure
    export RALPH_DIR=".ralph"
    export PROMPT_FILE="$RALPH_DIR/PROMPT.md"
    export LOG_DIR="$RALPH_DIR/logs"
    export DOCS_DIR="$RALPH_DIR/docs/generated"
    export STATUS_FILE="$RALPH_DIR/status.json"
    export EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
    export CALL_COUNT_FILE="$RALPH_DIR/.call_count"
    export TIMESTAMP_FILE="$RALPH_DIR/.last_reset"
    export TOTAL_COST_FILE="$RALPH_DIR/.total_cost"
    export START_TIME_FILE="$RALPH_DIR/.start_time"
    export MAX_COST="0"
    export MAX_HOURS="0"

    mkdir -p "$LOG_DIR" "$DOCS_DIR"
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Create minimal required files
    echo "# Test Prompt" > "$PROMPT_FILE"

    # Source library components
    source "${BATS_TEST_DIRNAME}/../../lib/date_utils.sh"

    # Define color variables and log_status for tests
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    NC='\033[0m'

    log_status() {
        local level=$1
        local message=$2
        echo "[$level] $message" >&2
    }

    # ==========================================================================
    # INLINE FUNCTION DEFINITIONS (from ralph_loop.sh)
    # ==========================================================================

    extract_and_accumulate_cost() {
        local output_file=$1

        if [[ ! -f "$output_file" ]]; then
            echo "0"
            return
        fi

        local cost="0"

        if jq -e 'type == "array"' "$output_file" >/dev/null 2>&1; then
            cost=$(jq -r '[.[] | select(.type == "result")] | .[-1].costUsd // 0' "$output_file" 2>/dev/null || echo "0")
        else
            cost=$(jq -r '.costUsd // 0' "$output_file" 2>/dev/null || echo "0")
        fi

        if ! echo "$cost" | grep -qE '^[0-9]+\.?[0-9]*$'; then
            cost="0"
        fi

        local current_total="0"
        if [[ -f "$TOTAL_COST_FILE" ]]; then
            current_total=$(cat "$TOTAL_COST_FILE" 2>/dev/null || echo "0")
        fi

        local new_total
        new_total=$(echo "$current_total + $cost" | bc 2>/dev/null || echo "$current_total")
        echo "$new_total" > "$TOTAL_COST_FILE"
        echo "$cost"
    }

    get_total_cost() {
        if [[ -f "$TOTAL_COST_FILE" ]]; then
            cat "$TOTAL_COST_FILE" 2>/dev/null || echo "0"
        else
            echo "0"
        fi
    }

    is_budget_exceeded() {
        if [[ "$MAX_COST" == "0" ]]; then
            return 1
        fi

        local total_cost
        total_cost=$(get_total_cost)

        local exceeded
        exceeded=$(echo "$total_cost >= $MAX_COST" | bc 2>/dev/null || echo "0")

        if [[ "$exceeded" == "1" ]]; then
            return 0
        fi
        return 1
    }

    init_start_time() {
        if [[ ! -f "$START_TIME_FILE" ]]; then
            get_epoch_seconds > "$START_TIME_FILE"
        fi
    }

    is_max_hours_exceeded() {
        if [[ "$MAX_HOURS" == "0" ]]; then
            return 1
        fi

        if [[ ! -f "$START_TIME_FILE" ]]; then
            return 1
        fi

        local start_epoch
        start_epoch=$(cat "$START_TIME_FILE" 2>/dev/null || echo "0")
        local current_epoch
        current_epoch=$(get_epoch_seconds)
        local elapsed_seconds=$((current_epoch - start_epoch))
        local max_seconds
        max_seconds=$(echo "$MAX_HOURS * 3600" | bc 2>/dev/null | cut -d. -f1)

        if [[ $elapsed_seconds -ge $max_seconds ]]; then
            return 0
        fi
        return 1
    }

    get_elapsed_runtime() {
        if [[ ! -f "$START_TIME_FILE" ]]; then
            echo "0h 0m"
            return
        fi

        local start_epoch
        start_epoch=$(cat "$START_TIME_FILE" 2>/dev/null || echo "0")
        local current_epoch
        current_epoch=$(get_epoch_seconds)
        local elapsed=$((current_epoch - start_epoch))
        local hours=$((elapsed / 3600))
        local minutes=$(((elapsed % 3600) / 60))
        echo "${hours}h ${minutes}m"
    }

    init_call_tracking() {
        local current_hour=$(date +%Y%m%d%H)
        local last_reset_hour=""

        if [[ -f "$TIMESTAMP_FILE" ]]; then
            last_reset_hour=$(cat "$TIMESTAMP_FILE")
        fi

        local should_reset=false
        if [[ "$current_hour" != "$last_reset_hour" ]]; then
            should_reset=true
        elif [[ -f "$TIMESTAMP_FILE" ]]; then
            local file_epoch
            file_epoch=$(stat -c %Y "$TIMESTAMP_FILE" 2>/dev/null || stat -f %m "$TIMESTAMP_FILE" 2>/dev/null || echo "0")
            local current_epoch
            current_epoch=$(get_epoch_seconds)
            local age=$((current_epoch - file_epoch))
            if [[ $age -gt 3600 ]]; then
                should_reset=true
                log_status "INFO" "Call counter stale (${age}s old), resetting"
            fi
        fi

        if [[ "$should_reset" == "true" ]]; then
            echo "0" > "$CALL_COUNT_FILE"
            echo "$current_hour" > "$TIMESTAMP_FILE"
            log_status "INFO" "Call counter reset for new hour: $current_hour"
        fi

        if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
            echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
        fi
    }
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# CLI FLAG PARSING TESTS (6 tests)
# =============================================================================

@test "--max-cost flag is accepted with valid value" {
    run bash "$RALPH_SCRIPT" --max-cost 10 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--max-cost flag accepts decimal values" {
    run bash "$RALPH_SCRIPT" --max-cost 5.50 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--max-cost rejects zero" {
    run bash "$RALPH_SCRIPT" --max-cost 0
    assert_failure
    [[ "$output" == *"positive number"* ]]
}

@test "--max-cost rejects non-numeric input" {
    run bash "$RALPH_SCRIPT" --max-cost abc
    assert_failure
    [[ "$output" == *"positive number"* ]]
}

@test "--max-hours flag is accepted with valid value" {
    run bash "$RALPH_SCRIPT" --max-hours 8 --help
    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--max-hours rejects zero" {
    run bash "$RALPH_SCRIPT" --max-hours 0
    assert_failure
    [[ "$output" == *"positive number"* ]]
}

# =============================================================================
# HELP TEXT TESTS (2 tests)
# =============================================================================

@test "--help shows --max-cost option" {
    run bash "$RALPH_SCRIPT" --help
    assert_success
    [[ "$output" == *"--max-cost"* ]]
    [[ "$output" == *"Budget"* ]] || [[ "$output" == *"budget"* ]] || [[ "$output" == *"USD"* ]]
}

@test "--help shows --max-hours option" {
    run bash "$RALPH_SCRIPT" --help
    assert_success
    [[ "$output" == *"--max-hours"* ]]
    [[ "$output" == *"Runtime"* ]] || [[ "$output" == *"runtime"* ]] || [[ "$output" == *"hours"* ]]
}

# =============================================================================
# COST EXTRACTION TESTS (6 tests)
# =============================================================================

@test "extract_and_accumulate_cost extracts costUsd from flat JSON" {
    local output_file="$TEST_DIR/output.json"
    echo '{"result": "done", "costUsd": 0.42, "sessionId": "abc"}' > "$output_file"

    run extract_and_accumulate_cost "$output_file"
    assert_success
    [[ "$output" == *"0.42"* ]] || [[ "$output" == *".42"* ]]
}

@test "extract_and_accumulate_cost extracts costUsd from array format" {
    local output_file="$TEST_DIR/output.json"
    cat > "$output_file" << 'EOF'
[{"type": "system", "subtype": "init", "session_id": "abc"}, {"type": "result", "result": "done", "costUsd": 1.23, "sessionId": "abc"}]
EOF

    run extract_and_accumulate_cost "$output_file"
    assert_success
    [[ "$output" == *"1.23"* ]]
}

@test "extract_and_accumulate_cost returns 0 when no costUsd field" {
    local output_file="$TEST_DIR/output.json"
    echo '{"result": "done", "sessionId": "abc"}' > "$output_file"

    run extract_and_accumulate_cost "$output_file"
    assert_success
    [[ "$output" == "0" ]]
}

@test "extract_and_accumulate_cost accumulates across calls" {
    local output_file="$TEST_DIR/output.json"

    # First call
    echo '{"costUsd": 0.50}' > "$output_file"
    extract_and_accumulate_cost "$output_file" > /dev/null

    # Second call
    echo '{"costUsd": 0.30}' > "$output_file"
    extract_and_accumulate_cost "$output_file" > /dev/null

    run get_total_cost
    assert_success
    # Total should be 0.80
    [[ "$output" == *".80"* ]] || [[ "$output" == *"0.80"* ]]
}

@test "extract_and_accumulate_cost handles missing file" {
    run extract_and_accumulate_cost "/nonexistent/file.json"
    assert_success
    [[ "$output" == "0" ]]
}

@test "extract_and_accumulate_cost handles invalid costUsd" {
    local output_file="$TEST_DIR/output.json"
    echo '{"costUsd": "not_a_number"}' > "$output_file"

    run extract_and_accumulate_cost "$output_file"
    assert_success
    [[ "$output" == "0" ]]
}

# =============================================================================
# BUDGET CHECK TESTS (4 tests)
# =============================================================================

@test "is_budget_exceeded returns 1 when no budget set" {
    MAX_COST="0"
    run is_budget_exceeded
    assert_failure  # Return 1 = not exceeded
}

@test "is_budget_exceeded returns 1 when within budget" {
    MAX_COST="10"
    echo "5.00" > "$TOTAL_COST_FILE"
    run is_budget_exceeded
    assert_failure  # Return 1 = not exceeded
}

@test "is_budget_exceeded returns 0 when budget exceeded" {
    MAX_COST="10"
    echo "10.50" > "$TOTAL_COST_FILE"
    run is_budget_exceeded
    assert_success  # Return 0 = exceeded
}

@test "is_budget_exceeded returns 0 when exactly at budget" {
    MAX_COST="10"
    echo "10" > "$TOTAL_COST_FILE"
    run is_budget_exceeded
    assert_success  # Return 0 = exceeded (>= check)
}

# =============================================================================
# RUNTIME LIMIT TESTS (5 tests)
# =============================================================================

@test "is_max_hours_exceeded returns 1 when no limit set" {
    MAX_HOURS="0"
    run is_max_hours_exceeded
    assert_failure  # Return 1 = not exceeded
}

@test "is_max_hours_exceeded returns 1 when within limit" {
    MAX_HOURS="8"
    # Start time = now (0 seconds ago)
    get_epoch_seconds > "$START_TIME_FILE"
    run is_max_hours_exceeded
    assert_failure  # Return 1 = not exceeded
}

@test "is_max_hours_exceeded returns 0 when time exceeded" {
    MAX_HOURS="1"
    # Start time = 2 hours ago
    local two_hours_ago=$(($(get_epoch_seconds) - 7200))
    echo "$two_hours_ago" > "$START_TIME_FILE"
    run is_max_hours_exceeded
    assert_success  # Return 0 = exceeded
}

@test "is_max_hours_exceeded returns 1 when no start time file" {
    MAX_HOURS="8"
    rm -f "$START_TIME_FILE"
    run is_max_hours_exceeded
    assert_failure  # Return 1 = not exceeded (no start time)
}

@test "init_start_time creates start time file" {
    rm -f "$START_TIME_FILE"
    init_start_time
    [[ -f "$START_TIME_FILE" ]]
    local content
    content=$(cat "$START_TIME_FILE")
    [[ "$content" =~ ^[0-9]+$ ]]
}

# =============================================================================
# ELAPSED RUNTIME TESTS (2 tests)
# =============================================================================

@test "get_elapsed_runtime returns 0h 0m when no start file" {
    rm -f "$START_TIME_FILE"
    run get_elapsed_runtime
    assert_success
    [[ "$output" == "0h 0m" ]]
}

@test "get_elapsed_runtime shows correct elapsed time" {
    # Start time = 90 minutes ago
    local ninety_min_ago=$(($(get_epoch_seconds) - 5400))
    echo "$ninety_min_ago" > "$START_TIME_FILE"
    run get_elapsed_runtime
    assert_success
    [[ "$output" == "1h 30m" ]]
}

# =============================================================================
# STALE CALL COUNTER TESTS (3 tests)
# =============================================================================

@test "init_call_tracking resets when hour string changes" {
    # Set call count to 50
    echo "50" > "$CALL_COUNT_FILE"
    # Set timestamp to a different hour
    echo "2020010100" > "$TIMESTAMP_FILE"

    init_call_tracking

    local count
    count=$(cat "$CALL_COUNT_FILE")
    [[ "$count" == "0" ]]
}

@test "init_call_tracking does not reset within same hour" {
    # Set call count to 50 and current hour
    echo "50" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    # Touch the file to make it recent
    touch "$TIMESTAMP_FILE"

    init_call_tracking

    local count
    count=$(cat "$CALL_COUNT_FILE")
    [[ "$count" == "50" ]]
}

@test "init_call_tracking resets stale counter even if same hour string" {
    # Set call count to 50 with current hour string
    echo "50" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"

    # Make the file look old (>1 hour) by backdating it
    # Use touch -d on Linux or touch -t for cross-platform
    local old_time
    old_time=$(date -d '2 hours ago' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-2H '+%Y%m%d%H%M.%S' 2>/dev/null)
    if [[ -n "$old_time" ]]; then
        touch -t "$old_time" "$TIMESTAMP_FILE"

        init_call_tracking

        local count
        count=$(cat "$CALL_COUNT_FILE")
        [[ "$count" == "0" ]]
    else
        # Skip on platforms where we can't backdate
        skip "Cannot backdate files on this platform"
    fi
}
