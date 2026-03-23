#!/bin/bash
# Model Selector for Ralph Loop
# Chooses between opus and sonnet based on task complexity,
# budget status, and rate limits

# Source date utilities for timestamps
source "$(dirname "${BASH_SOURCE[0]}")/date_utils.sh"

# State files
RALPH_DIR="${RALPH_DIR:-.ralph}"
CURRENT_MODEL_FILE="$RALPH_DIR/.current_model"
OPUS_WINDOW_FILE="$RALPH_DIR/.opus_window_count"

# Simple task patterns — these don't need opus
SIMPLE_TASK_PATTERNS=(
    "docs"
    "markdown"
    "README"
    "config"
    "typo"
    "rename"
    "strategy"
    "comment"
    "documentation"
    "update.*md"
    "\.md"
    "fix_plan"
    "PROMPT"
    "ralphrc"
    "report"
)

# Check if the next task in fix_plan.md is simple
# Returns 0 if simple, 1 if complex
is_simple_task() {
    local fix_plan="$RALPH_DIR/fix_plan.md"
    if [[ ! -f "$fix_plan" ]]; then
        return 1  # No plan found, assume complex
    fi

    # Get the first unchecked task
    local next_task
    next_task=$(grep -m1 -E "^[[:space:]]*- \[ \]" "$fix_plan" 2>/dev/null || true)

    if [[ -z "$next_task" ]]; then
        return 1  # No tasks, assume complex
    fi

    # Check against simple patterns
    local pattern
    for pattern in "${SIMPLE_TASK_PATTERNS[@]}"; do
        if echo "$next_task" | grep -qiE "$pattern"; then
            return 0  # Simple task
        fi
    done

    return 1  # Complex task
}

# Check opus usage window for Max mode
# Tracks opus calls within a rolling window
check_opus_window() {
    local max_calls=${RALPH_MAX_OPUS_CALLS_PER_WINDOW:-30}
    local window_hours=${RALPH_OPUS_WINDOW_HOURS:-5}

    mkdir -p "$RALPH_DIR"

    if [[ ! -f "$OPUS_WINDOW_FILE" ]]; then
        echo '{"window_start": "", "count": 0}' > "$OPUS_WINDOW_FILE"
    fi

    local window_data
    window_data=$(cat "$OPUS_WINDOW_FILE")
    local window_start count
    window_start=$(echo "$window_data" | jq -r '.window_start // ""')
    count=$(echo "$window_data" | jq -r '.count // 0')
    count=$((count + 0))

    local now_epoch
    now_epoch=$(date +%s)

    # Check if window has expired
    if [[ -n "$window_start" && "$window_start" != "" ]]; then
        local start_epoch
        start_epoch=$(parse_iso_to_epoch "$window_start")
        local elapsed_hours
        elapsed_hours=$(( (now_epoch - start_epoch) / 3600 ))

        if [[ $elapsed_hours -ge $window_hours ]]; then
            # Window expired, reset
            count=0
            window_start=""
        fi
    fi

    # Start new window if needed
    if [[ -z "$window_start" || "$window_start" == "" ]]; then
        window_start=$(get_iso_timestamp)
        count=0
    fi

    # Check if at limit
    if [[ $count -ge $max_calls ]]; then
        # Save state
        jq -n --arg ws "$window_start" --argjson c "$count" \
            '{window_start: $ws, count: $c}' > "$OPUS_WINDOW_FILE"
        return 1  # At limit
    fi

    return 0  # Under limit
}

# Increment opus window counter
increment_opus_window() {
    if [[ ! -f "$OPUS_WINDOW_FILE" ]]; then
        local ts
        ts=$(get_iso_timestamp)
        jq -n --arg ws "$ts" '{window_start: $ws, count: 1}' > "$OPUS_WINDOW_FILE"
        return
    fi

    local window_data
    window_data=$(cat "$OPUS_WINDOW_FILE")
    local window_start count
    window_start=$(echo "$window_data" | jq -r '.window_start // ""')
    count=$(echo "$window_data" | jq -r '.count // 0')
    count=$((count + 1))

    if [[ -z "$window_start" || "$window_start" == "" ]]; then
        window_start=$(get_iso_timestamp)
    fi

    jq -n --arg ws "$window_start" --argjson c "$count" \
        '{window_start: $ws, count: $c}' > "$OPUS_WINDOW_FILE"
}

# Phase patterns that benefit from deep thinking (standard mode)
ANALYSIS_PHASE_PATTERNS=(
    "analyz"
    "architect"
    "debug"
    "refactor"
    "design"
    "plan"
    "investig"
    "review"
    "audit"
    "security"
    "diagnos"
)

# Phase patterns that benefit from speed (fast mode)
EXECUTION_PHASE_PATTERNS=(
    "implement"
    "add.*tool"
    "create.*module"
    "expand.*test"
    "write.*test"
    "fix.*typo"
    "update.*docs"
    "mechanical"
    "migrate"
    "rename"
    "format"
    "sweep"
)

# Speed tier selection based on phase and task context
# Returns "fast" or "standard"
select_speed_tier() {
    local fast_enabled=${FAST_MODE_ENABLED:-false}
    if [[ "$fast_enabled" != "true" ]]; then
        echo "standard"
        return 0
    fi

    # Check current phase from .ralphrc
    local current_phase
    current_phase=$(grep 'CURRENT_PHASE=' .ralphrc 2>/dev/null | head -1 | sed 's/.*CURRENT_PHASE=//;s/"//g;s/#.*//' | tr -d '[:space:]')

    # Check next task from fix_plan.md
    local next_task
    next_task=$(grep -m1 -E "^[[:space:]]*- \[ \]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || true)

    local combined="$current_phase $next_task"

    # Check execution patterns first (fast mode)
    local pattern
    for pattern in "${EXECUTION_PHASE_PATTERNS[@]}"; do
        if echo "$combined" | grep -qiE "$pattern"; then
            echo "fast"
            return 0
        fi
    done

    # Check analysis patterns (standard mode)
    for pattern in "${ANALYSIS_PHASE_PATTERNS[@]}"; do
        if echo "$combined" | grep -qiE "$pattern"; then
            echo "standard"
            return 0
        fi
    done

    # Default when phase is unknown
    if [[ "${FAST_MODE_DEFAULT:-false}" == "true" ]]; then
        echo "fast"
    else
        echo "standard"
    fi
}

# Global speed tier — set by select_model(), read by build_claude_command()
CURRENT_SPEED_TIER="standard"

# Main model selection function
# Usage: select_model [loop_count]
# Prints "opus" or "sonnet" to stdout
# Returns exit code 4 if budget exceeded (should halt)
select_model() {
    local loop_count=${1:-0}
    local mode=${RALPH_USAGE_MODE:-api}

    # Layer 1: Simple tasks always use sonnet
    if is_simple_task; then
        echo "sonnet"
        echo "sonnet" > "$CURRENT_MODEL_FILE"
        # Simple tasks benefit from speed — always fast
        CURRENT_SPEED_TIER="fast"
        echo "$CURRENT_SPEED_TIER" > "$RALPH_DIR/.current_speed_tier"
        return 0
    fi

    # Layer 2: Budget checks (API mode)
    if [[ "$mode" == "api" ]]; then
        local budget_status
        budget_status=$(check_budget)

        if [[ "$budget_status" == "exceeded" ]]; then
            echo "BUDGET EXCEEDED — halting loop" >&2
            return 4
        fi

        if [[ "$budget_status" == "downgrade" ]]; then
            echo "sonnet"
            echo "sonnet" > "$CURRENT_MODEL_FILE"
            CURRENT_SPEED_TIER=$(select_speed_tier)
            echo "$CURRENT_SPEED_TIER" > "$RALPH_DIR/.current_speed_tier"
            return 0
        fi
    fi

    # Layer 3: Rate limit checks (Max mode)
    if [[ "$mode" == "max" ]]; then
        if ! check_opus_window; then
            echo "sonnet"
            echo "sonnet" > "$CURRENT_MODEL_FILE"
            CURRENT_SPEED_TIER=$(select_speed_tier)
            echo "$CURRENT_SPEED_TIER" > "$RALPH_DIR/.current_speed_tier"
            return 0
        fi
    fi

    # Default: opus for complex tasks within budget
    echo "opus"
    echo "opus" > "$CURRENT_MODEL_FILE"

    # NOTE: opus window increment moved to success path in ralph_loop.sh
    # so that timeouts don't consume window slots

    # Determine speed tier (orthogonal to model selection)
    CURRENT_SPEED_TIER=$(select_speed_tier)
    echo "$CURRENT_SPEED_TIER" > "$RALPH_DIR/.current_speed_tier"

    return 0
}

# Get the current model (for display purposes)
get_current_model() {
    if [[ -f "$CURRENT_MODEL_FILE" ]]; then
        cat "$CURRENT_MODEL_FILE"
    else
        echo "opus"
    fi
}

# Export functions
export -f is_simple_task
export -f check_opus_window
export -f increment_opus_window
export -f select_speed_tier
export -f select_model
export -f get_current_model
