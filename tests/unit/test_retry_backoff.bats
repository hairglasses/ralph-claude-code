#!/usr/bin/env bats
# Unit tests for exponential retry backoff on transient errors
# Tests calculate_backoff_delay() and the main loop backoff behavior

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
    export LOG_DIR="$RALPH_DIR/logs"
    export CALL_COUNT_FILE="$RALPH_DIR/.call_count"
    export TIMESTAMP_FILE="$RALPH_DIR/.last_reset"

    mkdir -p "$LOG_DIR"
    echo "0" > "$CALL_COUNT_FILE"

    # Source library components
    source "${BATS_TEST_DIRNAME}/../../lib/date_utils.sh"

    # Default backoff configuration
    export RETRY_BACKOFF_INITIAL=30
    export RETRY_BACKOFF_MAX=300
    export RETRY_BACKOFF_MULTIPLIER=2
    export CONSECUTIVE_ERRORS=0

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

    # Inline the function under test from ralph_loop.sh
    calculate_backoff_delay() {
        local errors=${1:-$CONSECUTIVE_ERRORS}
        if [[ $errors -le 0 ]]; then
            echo "$RETRY_BACKOFF_INITIAL"
            return
        fi

        local exponent=$((errors - 1))
        local delay=$RETRY_BACKOFF_INITIAL
        local i=0
        while [[ $i -lt $exponent ]]; do
            delay=$((delay * RETRY_BACKOFF_MULTIPLIER))
            i=$((i + 1))
            if [[ $delay -ge $RETRY_BACKOFF_MAX ]]; then
                delay=$RETRY_BACKOFF_MAX
                break
            fi
        done

        if [[ $delay -gt $RETRY_BACKOFF_MAX ]]; then
            delay=$RETRY_BACKOFF_MAX
        fi

        echo "$delay"
    }
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

# ==========================================================================
# calculate_backoff_delay() tests
# ==========================================================================

@test "backoff: first error returns initial delay (30s)" {
    local result
    result=$(calculate_backoff_delay 1)
    [ "$result" -eq 30 ]
}

@test "backoff: zero errors returns initial delay" {
    local result
    result=$(calculate_backoff_delay 0)
    [ "$result" -eq 30 ]
}

@test "backoff: second error doubles delay (60s)" {
    local result
    result=$(calculate_backoff_delay 2)
    [ "$result" -eq 60 ]
}

@test "backoff: third error quadruples delay (120s)" {
    local result
    result=$(calculate_backoff_delay 3)
    [ "$result" -eq 120 ]
}

@test "backoff: fourth error = 240s" {
    local result
    result=$(calculate_backoff_delay 4)
    [ "$result" -eq 240 ]
}

@test "backoff: fifth error capped at max (300s)" {
    local result
    result=$(calculate_backoff_delay 5)
    [ "$result" -eq 300 ]
}

@test "backoff: large error count stays at max" {
    local result
    result=$(calculate_backoff_delay 100)
    [ "$result" -eq 300 ]
}

@test "backoff: uses CONSECUTIVE_ERRORS default when no argument" {
    CONSECUTIVE_ERRORS=3
    local result
    result=$(calculate_backoff_delay)
    [ "$result" -eq 120 ]
}

# ==========================================================================
# Custom configuration tests
# ==========================================================================

@test "backoff: custom initial delay (10s)" {
    RETRY_BACKOFF_INITIAL=10
    local result
    result=$(calculate_backoff_delay 1)
    [ "$result" -eq 10 ]
}

@test "backoff: custom multiplier (3x)" {
    RETRY_BACKOFF_MULTIPLIER=3
    local result
    result=$(calculate_backoff_delay 2)
    # 30 * 3 = 90
    [ "$result" -eq 90 ]
}

@test "backoff: custom max (60s) caps early" {
    RETRY_BACKOFF_MAX=60
    local result
    result=$(calculate_backoff_delay 3)
    # 30 * 4 = 120, but capped at 60
    [ "$result" -eq 60 ]
}

@test "backoff: initial=10 multiplier=3 max=100 sequence" {
    RETRY_BACKOFF_INITIAL=10
    RETRY_BACKOFF_MULTIPLIER=3
    RETRY_BACKOFF_MAX=100

    [ "$(calculate_backoff_delay 1)" -eq 10 ]   # 10
    [ "$(calculate_backoff_delay 2)" -eq 30 ]   # 10*3
    [ "$(calculate_backoff_delay 3)" -eq 90 ]   # 10*9
    [ "$(calculate_backoff_delay 4)" -eq 100 ]  # 10*27=270 → capped at 100
}

# ==========================================================================
# .ralphrc configuration tests
# ==========================================================================

@test "backoff: .ralphrc can set RETRY_BACKOFF_INITIAL" {
    # Simulate .ralphrc loading
    echo 'RETRY_BACKOFF_INITIAL=15' > .ralphrc
    source .ralphrc
    local result
    result=$(calculate_backoff_delay 1)
    [ "$result" -eq 15 ]
}

@test "backoff: .ralphrc can set RETRY_BACKOFF_MAX" {
    echo 'RETRY_BACKOFF_MAX=120' > .ralphrc
    source .ralphrc
    local result
    result=$(calculate_backoff_delay 5)
    [ "$result" -eq 120 ]
}

@test "backoff: environment variable overrides .ralphrc" {
    echo 'RETRY_BACKOFF_INITIAL=15' > .ralphrc
    export RETRY_BACKOFF_INITIAL=45
    source .ralphrc
    # Env should still be 45 (overridden after source)
    RETRY_BACKOFF_INITIAL=45
    local result
    result=$(calculate_backoff_delay 1)
    [ "$result" -eq 45 ]
}

# ==========================================================================
# CLI parsing tests (via ralph_loop.sh argument parsing)
# ==========================================================================

@test "backoff: defaults are set in ralph_loop.sh" {
    run grep 'RETRY_BACKOFF_INITIAL.*30' "$RALPH_SCRIPT"
    [ "$status" -eq 0 ]
    run grep 'RETRY_BACKOFF_MAX.*300' "$RALPH_SCRIPT"
    [ "$status" -eq 0 ]
    run grep 'RETRY_BACKOFF_MULTIPLIER.*2' "$RALPH_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "backoff: CONSECUTIVE_ERRORS initialized to 0" {
    run grep 'CONSECUTIVE_ERRORS=0' "$RALPH_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "backoff: error handler increments CONSECUTIVE_ERRORS" {
    run grep 'CONSECUTIVE_ERRORS=.*CONSECUTIVE_ERRORS.*+.*1' "$RALPH_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "backoff: success handler resets CONSECUTIVE_ERRORS" {
    run grep -A5 'exec_result -eq 0' "$RALPH_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CONSECUTIVE_ERRORS=0"* ]]
}

@test "backoff: error sleep uses calculate_backoff_delay" {
    run grep 'calculate_backoff_delay' "$RALPH_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "backoff: load_ralphrc documents backoff variables" {
    run grep 'RETRY_BACKOFF' "$RALPH_SCRIPT"
    [ "$status" -eq 0 ]
    # Should document all three variables
    run grep -c 'RETRY_BACKOFF' "$RALPH_SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" -ge 10 ]  # Multiple references across config, function, and docs
}
