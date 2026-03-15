#!/bin/bash

# hgmux_bridge.sh - Bridge between Ralph loop and hgmux native UI
#
# Maps Ralph state to cmux CLI calls for sidebar status, progress bars,
# and notifications. Auto-detected via $CMUX_SOCKET_PATH env var.
#
# Requires: cmux CLI on PATH, running inside hgmux terminal

# Guard against double-sourcing
[[ -n "${_HGMUX_BRIDGE_LOADED:-}" ]] && return 0
_HGMUX_BRIDGE_LOADED=1

# Internal state
_HGMUX_ACTIVE=false
_HGMUX_WORKSPACE_REF=""

# is_hgmux - Detect if running inside hgmux
#
# Returns 0 if hgmux is detected (CMUX_SOCKET_PATH set and cmux on PATH)
# Caches result in _HGMUX_ACTIVE for performance
is_hgmux() {
    if [[ "$_HGMUX_ACTIVE" == "true" ]]; then
        return 0
    fi

    if [[ -n "${CMUX_SOCKET_PATH:-}" ]] && command -v cmux &>/dev/null; then
        _HGMUX_ACTIVE=true
        return 0
    fi

    return 1
}

# hgmux_report_status - Push a key/value status entry to the sidebar
#
# Args:
#   $1 - key (e.g., "ralph_loop", "ralph_calls", "ralph_status")
#   $2 - value (e.g., "#5", "12/100", "running")
#   $3 - icon (optional, e.g., "repeat", "zap", "check")
hgmux_report_status() {
    local key="$1"
    local value="$2"
    local icon="${3:-}"

    if ! is_hgmux; then
        return 0
    fi

    if [[ -n "$icon" ]]; then
        cmux set-status "$key" "$value" --icon "$icon" 2>/dev/null || true
    else
        cmux set-status "$key" "$value" 2>/dev/null || true
    fi
}

# hgmux_set_progress - Update the workspace progress bar
#
# Args:
#   $1 - fraction (0.0 to 1.0)
#   $2 - label (optional, e.g., "12/100 calls")
hgmux_set_progress() {
    local fraction="$1"
    local label="${2:-}"

    if ! is_hgmux; then
        return 0
    fi

    if [[ -n "$label" ]]; then
        cmux set-progress "$fraction" --label "$label" 2>/dev/null || true
    else
        cmux set-progress "$fraction" 2>/dev/null || true
    fi
}

# hgmux_notify - Send a notification via hgmux
#
# Args:
#   $1 - title
#   $2 - body
hgmux_notify() {
    local title="$1"
    local body="$2"

    if ! is_hgmux; then
        return 0
    fi

    cmux notify --title "$title" --body "$body" 2>/dev/null || true
}

# hgmux_log - Write a log entry to sidebar (via report_meta logEntries)
#
# Args:
#   $1 - level (INFO, WARN, ERROR, SUCCESS, LOOP)
#   $2 - message
hgmux_log() {
    local level="$1"
    local message="$2"

    if ! is_hgmux; then
        return 0
    fi

    local icon=""
    case "$level" in
        "INFO")    icon="info" ;;
        "WARN")    icon="warning" ;;
        "ERROR")   icon="xmark" ;;
        "SUCCESS") icon="checkmark" ;;
        "LOOP")    icon="repeat" ;;
    esac

    hgmux_report_status "ralph_log" "[$level] $message" "$icon"
}

# hgmux_setup_session - Create hgmux workspace + split pane layout for Ralph
#
# Creates a new workspace for the ralph loop with a right-side split pane
# tailing the live log. This replaces the tmux session setup.
#
# Args:
#   $1 - project_dir (working directory for the workspace)
hgmux_setup_session() {
    local project_dir="$1"

    if ! is_hgmux; then
        return 1
    fi

    local project_name
    project_name=$(basename "$project_dir")

    # Create a new workspace for ralph
    local create_output
    create_output=$(cmux new-workspace --cwd "$project_dir" 2>/dev/null) || true

    # Extract workspace ref if returned (format: "OK workspace:N")
    if [[ -n "$create_output" ]]; then
        _HGMUX_WORKSPACE_REF=$(echo "$create_output" | grep -o 'workspace:[0-9]*' | head -1)
    fi

    # Rename the workspace
    if [[ -n "$_HGMUX_WORKSPACE_REF" ]]; then
        cmux rename-workspace --workspace "$_HGMUX_WORKSPACE_REF" "Ralph: $project_name" 2>/dev/null || true
    fi

    # Split pane for live log viewing
    cmux new-split right 2>/dev/null || true

    # Start tailing the log in the right pane
    local live_log="$project_dir/.ralph/live.log"
    if [[ -f "$live_log" ]]; then
        cmux send "tail -f '$live_log'\\n" 2>/dev/null || true
    fi

    # Push initial status
    hgmux_report_status "ralph_status" "starting" "play"
    hgmux_report_status "ralph_project" "$project_name" "folder"
    hgmux_set_progress "0" "Initializing..."

    return 0
}

# hgmux_update_loop_status - Push current loop state to sidebar
#
# Called from the main loop to keep sidebar status current.
#
# Args:
#   $1 - loop_count
#   $2 - calls_made
#   $3 - max_calls
#   $4 - status (running, paused, halted, completed)
hgmux_update_loop_status() {
    local loop_count="$1"
    local calls_made="$2"
    local max_calls="$3"
    local status="${4:-running}"

    if ! is_hgmux; then
        return 0
    fi

    hgmux_report_status "ralph_loop" "#$loop_count" "repeat"
    hgmux_report_status "ralph_calls" "$calls_made/$max_calls" "bolt"
    hgmux_report_status "ralph_status" "$status" ""

    # Calculate and push progress
    if [[ "$max_calls" -gt 0 ]]; then
        local fraction
        fraction=$(echo "scale=2; $calls_made / $max_calls" | bc 2>/dev/null || echo "0")
        hgmux_set_progress "$fraction" "$calls_made/$max_calls API calls"
    fi
}

# hgmux_notify_circuit_breaker - Notify on circuit breaker state changes
#
# Args:
#   $1 - state (OPEN, HALF_OPEN, CLOSED)
#   $2 - reason (optional)
hgmux_notify_circuit_breaker() {
    local state="$1"
    local reason="${2:-}"

    if ! is_hgmux; then
        return 0
    fi

    local icon=""
    case "$state" in
        "OPEN")      icon="xmark.circle" ;;
        "HALF_OPEN") icon="exclamationmark.triangle" ;;
        "CLOSED")    icon="checkmark.circle" ;;
    esac

    hgmux_report_status "ralph_circuit" "$state" "$icon"

    if [[ "$state" == "OPEN" ]]; then
        hgmux_notify "Ralph: Circuit Breaker Open" "Loop halted: ${reason:-stagnation detected}"
    elif [[ "$state" == "HALF_OPEN" ]]; then
        hgmux_notify "Ralph: Circuit Breaker Recovery" "Attempting recovery after cooldown"
    fi
}

# hgmux_notify_completion - Notify on loop completion
#
# Args:
#   $1 - exit_reason
#   $2 - loop_count
#   $3 - calls_used
hgmux_notify_completion() {
    local exit_reason="$1"
    local loop_count="$2"
    local calls_used="$3"

    if ! is_hgmux; then
        return 0
    fi

    hgmux_report_status "ralph_status" "completed" "checkmark.circle"
    hgmux_set_progress "1.0" "Complete"
    hgmux_notify "Ralph: Project Complete" "Finished in $loop_count loops ($calls_used API calls). Reason: $exit_reason"
}

# hgmux_notify_error - Notify on critical errors
#
# Args:
#   $1 - error message
hgmux_notify_error() {
    local message="$1"

    if ! is_hgmux; then
        return 0
    fi

    hgmux_report_status "ralph_status" "error" "xmark.circle"
    hgmux_notify "Ralph: Error" "$message"
}
