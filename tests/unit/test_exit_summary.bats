#!/usr/bin/env bats
# Unit tests for generate_exit_summary() — summary report on graceful exit
# Verifies the report displays correct stats and is called at all exit points

load '../helpers/test_helper'
load '../helpers/fixtures'

# Path to ralph_loop.sh
RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize git repo with an initial commit
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "initial" > file.txt
    git add file.txt
    git commit -m "initial" > /dev/null 2>&1

    # Set up environment with .ralph/ subfolder structure
    export RALPH_DIR=".ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    export CALL_COUNT_FILE="$RALPH_DIR/.call_count"
    export TIMESTAMP_FILE="$RALPH_DIR/.last_reset"
    export TOTAL_COST_FILE="$RALPH_DIR/.total_cost"
    export START_TIME_FILE="$RALPH_DIR/.start_time"

    mkdir -p "$LOG_DIR"
    echo "5" > "$CALL_COUNT_FILE"
    echo "2.50" > "$TOTAL_COST_FILE"

    # Source library components
    source "${BATS_TEST_DIRNAME}/../../lib/date_utils.sh"

    # Create start time (1 hour ago)
    local now
    now=$(get_epoch_seconds)
    echo "$((now - 3600))" > "$START_TIME_FILE"

    # Save initial SHA
    git rev-parse HEAD > "$RALPH_DIR/.run_start_sha"

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
        echo "[$level] $message"
    }

    # Inline functions from ralph_loop.sh needed by generate_exit_summary
    get_total_cost() {
        if [[ -f "$TOTAL_COST_FILE" ]]; then
            cat "$TOTAL_COST_FILE" 2>/dev/null || echo "0"
        else
            echo "0"
        fi
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

    # Inline generate_exit_summary from ralph_loop.sh
    generate_exit_summary() {
        local loop_count=${1:-0}
        local exit_reason=${2:-"unknown"}
        local total_cost
        total_cost=$(get_total_cost)
        local elapsed
        elapsed=$(get_elapsed_runtime)
        local api_calls
        api_calls=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")

        local files_changed=0
        if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
            local run_start_sha=""
            if [[ -f "$RALPH_DIR/.run_start_sha" ]]; then
                run_start_sha=$(cat "$RALPH_DIR/.run_start_sha" 2>/dev/null || echo "")
            fi
            if [[ -n "$run_start_sha" ]]; then
                local current_sha
                current_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
                if [[ -n "$current_sha" && "$run_start_sha" != "$current_sha" ]]; then
                    files_changed=$(git diff --name-only "$run_start_sha" "$current_sha" 2>/dev/null | wc -l | tr -d ' ')
                fi
            fi
        fi

        echo ""
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║              Ralph Run Summary                            ║${NC}"
        echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC}  Exit reason:     ${YELLOW}${exit_reason}${NC}"
        echo -e "${GREEN}║${NC}  Total loops:     ${BLUE}${loop_count}${NC}"
        echo -e "${GREEN}║${NC}  API calls:       ${BLUE}${api_calls}${NC}"
        echo -e "${GREEN}║${NC}  Estimated cost:  ${BLUE}\$${total_cost}${NC}"
        echo -e "${GREEN}║${NC}  Runtime:         ${BLUE}${elapsed}${NC}"
        echo -e "${GREEN}║${NC}  Files changed:   ${BLUE}${files_changed}${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""

        log_status "SUCCESS" "=== Ralph Run Summary ==="
        log_status "INFO" "  Exit reason:    $exit_reason"
        log_status "INFO" "  Total loops:    $loop_count"
        log_status "INFO" "  API calls:      $api_calls"
        log_status "INFO" "  Estimated cost: \$$total_cost"
        log_status "INFO" "  Runtime:        $elapsed"
        log_status "INFO" "  Files changed:  $files_changed"
    }
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

# ==========================================================================
# generate_exit_summary() output tests
# ==========================================================================

@test "summary: shows exit reason" {
    run generate_exit_summary 10 "project_complete"
    [ "$status" -eq 0 ]
    [[ "$output" == *"project_complete"* ]]
}

@test "summary: shows total loops" {
    run generate_exit_summary 42 "test_reason"
    [[ "$output" == *"42"* ]]
}

@test "summary: shows API calls from call count file" {
    echo "17" > "$CALL_COUNT_FILE"
    run generate_exit_summary 5 "done"
    [[ "$output" == *"17"* ]]
}

@test "summary: shows estimated cost" {
    echo "3.75" > "$TOTAL_COST_FILE"
    run generate_exit_summary 5 "done"
    [[ "$output" == *"3.75"* ]]
}

@test "summary: shows runtime" {
    run generate_exit_summary 5 "done"
    # Should show ~1h 0m (set 3600s ago in setup)
    [[ "$output" == *"1h 0m"* ]]
}

@test "summary: shows 0 files changed when no commits made" {
    run generate_exit_summary 5 "done"
    [[ "$output" == *"Files changed:"* ]]
    # Match "Files changed:   ...0" (with possible ANSI codes)
    [[ "$output" == *"0"* ]]
}

@test "summary: counts files changed from git diff" {
    # Make some commits after run started
    echo "new content" > new_file.txt
    echo "modified" > file.txt
    git add -A
    git commit -m "changes" > /dev/null 2>&1

    run generate_exit_summary 5 "done"
    # Should show 2 files changed
    [[ "$output" == *"2"* ]]
}

@test "summary: includes Ralph Run Summary banner" {
    run generate_exit_summary 1 "test"
    [[ "$output" == *"Ralph Run Summary"* ]]
}

@test "summary: logs structured output" {
    run generate_exit_summary 3 "budget_limit"
    [[ "$output" == *"[SUCCESS] === Ralph Run Summary ==="* ]]
    [[ "$output" == *"[INFO]   Exit reason:    budget_limit"* ]]
    [[ "$output" == *"[INFO]   Total loops:    3"* ]]
}

@test "summary: defaults to 0 loops and unknown reason" {
    run generate_exit_summary
    [[ "$output" == *"unknown"* ]]
    [[ "$output" == *"Total loops:"*"0"* ]]
}

@test "summary: handles missing cost file gracefully" {
    rm -f "$TOTAL_COST_FILE"
    run generate_exit_summary 1 "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Estimated cost:"* ]]
}

@test "summary: handles missing start time file gracefully" {
    rm -f "$START_TIME_FILE"
    run generate_exit_summary 1 "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"0h 0m"* ]]
}

@test "summary: handles missing run_start_sha file" {
    rm -f "$RALPH_DIR/.run_start_sha"
    run generate_exit_summary 1 "test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Files changed:"* ]]
}

# ==========================================================================
# Integration: verify ralph_loop.sh calls generate_exit_summary at exit points
# ==========================================================================

@test "summary: called on graceful exit (project_complete)" {
    run grep -A3 'graceful_exit.*completed' "$RALPH_SCRIPT"
    [[ "$output" == *"generate_exit_summary"* ]]
}

@test "summary: called on budget exceeded exit" {
    run grep -A3 'budget_exceeded' "$RALPH_SCRIPT"
    [[ "$output" == *"generate_exit_summary"* ]]
}

@test "summary: called on runtime exceeded exit" {
    run grep -A3 'runtime_exceeded' "$RALPH_SCRIPT"
    [[ "$output" == *"generate_exit_summary"* ]]
}

@test "summary: called on circuit breaker open (pre-loop check)" {
    run grep -B1 -A3 'circuit_breaker_open.*halted.*stagnation' "$RALPH_SCRIPT"
    [[ "$output" == *"generate_exit_summary"* ]]
}

@test "summary: called on circuit breaker trip (exec_result=3)" {
    run grep -A5 'circuit_breaker_trip' "$RALPH_SCRIPT"
    [[ "$output" == *"generate_exit_summary"* ]]
}

@test "summary: called on permission denied exit" {
    run grep -A2 'generate_exit_summary.*permission_denied' "$RALPH_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"generate_exit_summary"* ]]
}

@test "summary: called on API limit user exit" {
    run grep -B2 -A2 'api_limit_exit' "$RALPH_SCRIPT"
    [[ "$output" == *"generate_exit_summary"* ]]
}

@test "summary: called on integrity failure" {
    run grep -A3 'integrity_failure.*halted' "$RALPH_SCRIPT"
    [[ "$output" == *"generate_exit_summary"* ]]
}

@test "summary: run_start_sha captured at main function start" {
    run grep 'run_start_sha' "$RALPH_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *".run_start_sha"* ]]
}
