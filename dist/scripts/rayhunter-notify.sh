#!/bin/sh
#
# rayhunter-notify.sh
#
# Router-side notification script for Rayhunter on GL-X750 (EP06).
# Polls the Rayhunter API via the ADB-forwarded port and sends
# ntfy notifications when new warnings are detected.
#
# Usage:
#   rayhunter-notify.sh <ntfy_url> [poll_interval]
#
# Arguments:
#   ntfy_url        - Full ntfy topic URL (e.g. https://ntfy.sh/my-rayhunter)
#   poll_interval   - Seconds between polls (default: 30)
#
# The script is intended to run as a background service on the router.

RAYHUNTER_API="http://127.0.0.1:8080"
NTFY_URL="${1:-}"
POLL_INTERVAL="${2:-30}"
STATE_FILE="/tmp/rayhunter-notify.state"

if [ -z "$NTFY_URL" ]; then
    echo "Usage: $0 <ntfy_url> [poll_interval]" >&2
    exit 1
fi

logger -t rayhunter-notify "Starting notification monitor (ntfy=$NTFY_URL, interval=${POLL_INTERVAL}s)"

# Track the last warning count so we only notify on new warnings
last_warning_count=0
if [ -f "$STATE_FILE" ]; then
    last_warning_count=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
fi

send_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"

    if command -v curl >/dev/null 2>&1; then
        curl -s -o /dev/null \
            -H "Title: $title" \
            -H "Priority: $priority" \
            -d "$message" \
            "$NTFY_URL"
    elif command -v wget >/dev/null 2>&1; then
        echo "$message" | wget -q -O /dev/null \
            --header="Title: $title" \
            --header="Priority: $priority" \
            --post-file=- \
            "$NTFY_URL"
    else
        logger -t rayhunter-notify "ERROR: neither curl nor wget available"
        return 1
    fi
}

while true; do
    # Fetch the live analysis report (NDJSON)
    report=""
    if command -v curl >/dev/null 2>&1; then
        report=$(curl -s --max-time 10 "$RAYHUNTER_API/api/analysis-report/live" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        report=$(wget -q -O - --timeout=10 "$RAYHUNTER_API/api/analysis-report/live" 2>/dev/null)
    fi

    if [ -n "$report" ]; then
        # Count lines containing warning-level events (Low, Medium, High)
        warning_count=$(echo "$report" | grep -e '"Low"' -e '"Medium"' -e '"High"' 2>/dev/null | wc -l)
        warning_count=$((warning_count + 0))

        if [ "$warning_count" -gt "$last_warning_count" ]; then
            new_warnings=$((warning_count - last_warning_count))
            logger -t rayhunter-notify "Detected $new_warnings new warning(s) (total: $warning_count)"

            send_notification \
                "Rayhunter Alert" \
                "Rayhunter detected $new_warnings new warning event(s). Total warnings: $warning_count. Check the web UI for details." \
                "high"

            last_warning_count=$warning_count
            echo "$last_warning_count" > "$STATE_FILE"
        fi
    fi

    sleep "$POLL_INTERVAL"
done
