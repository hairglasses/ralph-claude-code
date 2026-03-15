#!/bin/bash
# Cost Governor for Ralph Loop
# Tracks estimated API costs and enforces budget limits
# Three-layer defense against runaway spend:
#   1. Hard budget cap (RALPH_SESSION_BUDGET)
#   2. Unproductive streak detector (3 consecutive zero-task loops)
#   3. Cost velocity alarm (rolling 5-loop average)

# Source date utilities for timestamps
source "$(dirname "${BASH_SOURCE[0]}")/date_utils.sh"

# State files
RALPH_DIR="${RALPH_DIR:-.ralph}"
COST_LEDGER_FILE="$RALPH_DIR/cost_ledger.jsonl"
COST_SUMMARY_FILE="$RALPH_DIR/cost_summary.json"

# Cost estimates per minute by model (based on typical token throughput at published pricing)
# opus: ~$0.60/min, sonnet: ~$0.10/min
_cost_per_minute() {
    case "$1" in
        opus)   echo "0.60" ;;
        sonnet) echo "0.10" ;;
        *)      echo "0.60" ;;
    esac
}

# Initialize cost tracking state files
init_cost_tracking() {
    mkdir -p "$RALPH_DIR"

    if [[ ! -f "$COST_LEDGER_FILE" ]]; then
        touch "$COST_LEDGER_FILE"
    fi

    if [[ ! -f "$COST_SUMMARY_FILE" ]]; then
        cat > "$COST_SUMMARY_FILE" << 'EOF'
{
    "session_spend": 0,
    "loop_count": 0,
    "opus_loops": 0,
    "sonnet_loops": 0,
    "productive_loops": 0,
    "unproductive_streak": 0
}
EOF
    fi
}

# Estimate cost for a model and duration
# Usage: estimate_cost "opus" 900
# Returns: cost in USD (e.g., "9.00")
estimate_cost() {
    local model=$1
    local duration_secs=$2

    local rate
    rate=$(_cost_per_minute "$model")
    local minutes
    minutes=$(awk "BEGIN {printf \"%.2f\", $duration_secs / 60}")
    awk "BEGIN {printf \"%.2f\", $minutes * $rate}"
}

# Record cost for a completed loop
# Usage: record_loop_cost "opus" 900 true 3
record_loop_cost() {
    local model=$1
    local duration_secs=$2
    local productive=$3
    local tasks_done=${4:-0}

    init_cost_tracking

    local cost
    cost=$(estimate_cost "$model" "$duration_secs")
    local ts
    ts=$(get_iso_timestamp)

    # Read current summary
    local summary
    summary=$(cat "$COST_SUMMARY_FILE")
    local loop_count
    loop_count=$(echo "$summary" | jq -r '.loop_count // 0')
    loop_count=$((loop_count + 1))

    # Append to ledger
    local entry
    entry=$(jq -n \
        --arg ts "$ts" \
        --argjson loop "$loop_count" \
        --arg model "$model" \
        --argjson duration_s "$duration_secs" \
        --argjson cost_usd "$cost" \
        --argjson productive "$productive" \
        --argjson tasks_done "$tasks_done" \
        '{ts: $ts, loop: $loop, model: $model, duration_s: $duration_s, cost_usd: $cost_usd, productive: $productive, tasks_done: $tasks_done}')
    echo "$entry" >> "$COST_LEDGER_FILE"

    # Update summary
    local session_spend opus_loops sonnet_loops productive_loops unproductive_streak
    session_spend=$(echo "$summary" | jq -r '.session_spend // 0')
    opus_loops=$(echo "$summary" | jq -r '.opus_loops // 0')
    sonnet_loops=$(echo "$summary" | jq -r '.sonnet_loops // 0')
    productive_loops=$(echo "$summary" | jq -r '.productive_loops // 0')
    unproductive_streak=$(echo "$summary" | jq -r '.unproductive_streak // 0')

    session_spend=$(awk "BEGIN {printf \"%.2f\", $session_spend + $cost}")

    if [[ "$model" == "opus" ]]; then
        opus_loops=$((opus_loops + 1))
    else
        sonnet_loops=$((sonnet_loops + 1))
    fi

    if [[ "$productive" == "true" ]]; then
        productive_loops=$((productive_loops + 1))
        unproductive_streak=0
    else
        unproductive_streak=$((unproductive_streak + 1))
    fi

    cat > "$COST_SUMMARY_FILE" << EOF
{
    "session_spend": $session_spend,
    "loop_count": $loop_count,
    "opus_loops": $opus_loops,
    "sonnet_loops": $sonnet_loops,
    "productive_loops": $productive_loops,
    "unproductive_streak": $unproductive_streak
}
EOF
}

# Get current session spend
get_session_spend() {
    init_cost_tracking
    jq -r '.session_spend // 0' "$COST_SUMMARY_FILE" 2>/dev/null || echo "0"
}

# Check budget status
# Returns: "ok", "downgrade" (>60% spent), or "exceeded"
check_budget() {
    local budget=${RALPH_SESSION_BUDGET:-50}
    local downgrade_pct=${RALPH_BUDGET_DOWNGRADE_PCT:-60}

    local spend
    spend=$(get_session_spend)

    local pct_spent
    pct_spent=$(awk "BEGIN {printf \"%.0f\", ($spend / $budget) * 100}")

    if [[ $pct_spent -ge 100 ]]; then
        echo "exceeded"
    elif [[ $pct_spent -ge $downgrade_pct ]]; then
        echo "downgrade"
    else
        echo "ok"
    fi
}

# Check cost velocity — halt if rolling 5-loop average exceeds alarm threshold
# Returns 0 if ok, 1 if alarm triggered
check_cost_velocity() {
    local alarm_per_loop=${RALPH_COST_ALARM_PER_LOOP:-5}

    init_cost_tracking

    local loop_count
    loop_count=$(jq -r '.loop_count // 0' "$COST_SUMMARY_FILE" 2>/dev/null || echo "0")

    # Need at least 5 loops for rolling average
    if [[ $loop_count -lt 5 ]]; then
        return 0
    fi

    # Get last 5 entries from ledger
    local last5_cost
    last5_cost=$(tail -5 "$COST_LEDGER_FILE" | jq -s '[.[].cost_usd] | add // 0')
    local avg_cost
    avg_cost=$(awk "BEGIN {printf \"%.2f\", $last5_cost / 5}")

    local exceeds
    exceeds=$(awk "BEGIN {print ($avg_cost > $alarm_per_loop) ? 1 : 0}")

    if [[ "$exceeds" == "1" ]]; then
        echo "COST VELOCITY ALARM: Rolling 5-loop avg \$$avg_cost exceeds \$$alarm_per_loop/loop" >&2
        return 1
    fi

    return 0
}

# Check for unproductive streak — halt if 3 consecutive loops with zero tasks
# Returns 0 if ok, 1 if streak detected
check_unproductive_streak() {
    init_cost_tracking

    local streak
    streak=$(jq -r '.unproductive_streak // 0' "$COST_SUMMARY_FILE" 2>/dev/null || echo "0")

    if [[ $streak -ge 3 ]]; then
        echo "UNPRODUCTIVE STREAK: $streak consecutive loops with zero task completions" >&2
        return 1
    fi

    return 0
}

# Show cost status summary
show_cost_status() {
    init_cost_tracking

    local summary
    summary=$(cat "$COST_SUMMARY_FILE")
    local budget=${RALPH_SESSION_BUDGET:-50}

    local spend loop_count opus_loops sonnet_loops productive_loops unproductive_streak
    spend=$(echo "$summary" | jq -r '.session_spend // 0')
    loop_count=$(echo "$summary" | jq -r '.loop_count // 0')
    opus_loops=$(echo "$summary" | jq -r '.opus_loops // 0')
    sonnet_loops=$(echo "$summary" | jq -r '.sonnet_loops // 0')
    productive_loops=$(echo "$summary" | jq -r '.productive_loops // 0')
    unproductive_streak=$(echo "$summary" | jq -r '.unproductive_streak // 0')

    local pct_spent
    pct_spent=$(awk "BEGIN {printf \"%.0f\", ($spend / $budget) * 100}")
    local remaining
    remaining=$(awk "BEGIN {printf \"%.2f\", $budget - $spend}")

    local status_color budget_status
    if [[ $pct_spent -ge 100 ]]; then
        status_color='\033[0;31m'
        budget_status="EXCEEDED"
    elif [[ $pct_spent -ge 60 ]]; then
        status_color='\033[1;33m'
        budget_status="WARNING"
    else
        status_color='\033[0;32m'
        budget_status="OK"
    fi

    local NC='\033[0m'
    echo -e "${status_color}Cost Governor Status${NC}"
    echo -e "${status_color}════════════════════${NC}"
    echo -e "Budget:              \$$budget"
    echo -e "Spent:               \$$spend ($pct_spent%)"
    echo -e "Remaining:           \$$remaining"
    echo -e "Status:              $budget_status"
    echo -e "Loops:               $loop_count (opus: $opus_loops, sonnet: $sonnet_loops)"
    echo -e "Productive:          $productive_loops / $loop_count"
    echo -e "Unproductive streak: $unproductive_streak"
    echo ""
}

# Export functions
export -f init_cost_tracking
export -f estimate_cost
export -f record_loop_cost
export -f get_session_spend
export -f check_budget
export -f check_cost_velocity
export -f check_unproductive_streak
export -f show_cost_status
