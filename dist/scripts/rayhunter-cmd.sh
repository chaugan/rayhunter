#!/bin/sh
#
# rayhunter-cmd.sh
#
# Router-side command listener for Rayhunter on GL-X750 (EP06).
# Subscribes to an ntfy "command" topic, executes commands against
# the rayhunter daemon/modem, and posts results back on a "status" topic.
#
# Usage:
#   rayhunter-cmd.sh <ntfy_url>
#
# Topic derivation:
#   <ntfy_url>       - warnings only (unchanged, used by rayhunter-notify.sh)
#   <ntfy_url>-cmd   - inbound commands (user publishes here)
#   <ntfy_url>-status - outbound responses (router publishes here)
#
# Supported commands: status, start, stop, restart, warnings

RAYHUNTER_API="http://127.0.0.1:8080"
NTFY_URL="${1:-}"
POLL_INTERVAL=10

if [ -z "$NTFY_URL" ]; then
    echo "Usage: $0 <ntfy_url>" >&2
    exit 1
fi

CMD_URL="${NTFY_URL}-cmd"
STATUS_URL="${NTFY_URL}-status"

logger -t rayhunter-cmd "Starting command listener (cmd=$CMD_URL, status=$STATUS_URL)"

# --- Helper: post a response to the status topic ---
send_response() {
    local title="$1"
    local message="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -s -o /dev/null \
            -H "Title: $title" \
            -H "Priority: low" \
            -d "$message" \
            "$STATUS_URL"
    elif command -v wget >/dev/null 2>&1; then
        echo "$message" | wget -q -O /dev/null \
            --header="Title: $title" \
            --header="Priority: low" \
            --post-file=- \
            "$STATUS_URL"
    else
        logger -t rayhunter-cmd "ERROR: neither curl nor wget available"
        return 1
    fi
}

# --- Helper: fetch a URL and return the body ---
api_get() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -s --max-time 15 "$url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O - --timeout=15 "$url" 2>/dev/null
    fi
}

# --- Helper: POST to a URL and return the body ---
api_post() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -s --max-time 10 -X POST "$url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O - --timeout=10 --post-data="" "$url" 2>/dev/null
    fi
}

# --- Command handlers ---

cmd_status() {
    local router_uptime modem_uptime daemon_pid free_mem manifest report
    local warning_count info_count rec_status modem_disk sd_disk

    router_uptime=$(uptime 2>/dev/null | sed 's/^ *//')
    modem_uptime=$(adb shell uptime 2>/dev/null | tr -d '\r' | sed 's/^ *//')
    daemon_pid=$(adb shell pidof rayhunter-daemon 2>/dev/null | tr -d '\r')
    free_mem=$(free 2>/dev/null | awk '/^Mem:/ {printf "%dM/%dM used", ($3)/1024, ($2)/1024}')

    # Get current recording state from manifest
    manifest=$(api_get "$RAYHUNTER_API/api/qmdl-manifest")
    rec_status="unknown"
    if [ -n "$manifest" ]; then
        local current_entry=""
        if command -v jsonfilter >/dev/null 2>&1; then
            current_entry=$(echo "$manifest" | jsonfilter -e '@.current_entry.name' 2>/dev/null)
        else
            # Fallback: extract name from current_entry object
            current_entry=$(echo "$manifest" | grep -o '"current_entry":{[^}]*}' | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//')
        fi
        if [ -n "$current_entry" ] && [ "$current_entry" != "null" ]; then
            rec_status="ACTIVE ($current_entry)"
        else
            rec_status="stopped"
        fi
    fi

    # Get disk usage
    modem_disk=$(adb shell df /data 2>/dev/null | tr -d '\r' | awk 'NR==2 {print $5}')
    sd_disk=$(df /mnt/sda1 2>/dev/null | awk 'NR==2 {print $5}')

    # Get warning counts from lightweight counts endpoint
    local counts high med low
    counts=$(api_get "$RAYHUNTER_API/api/analysis-counts/live")
    warning_count=0
    info_count=0
    if [ -n "$counts" ]; then
        if command -v jsonfilter >/dev/null 2>&1; then
            high=$(echo "$counts" | jsonfilter -e '@.high' 2>/dev/null || echo 0)
            med=$(echo "$counts" | jsonfilter -e '@.medium' 2>/dev/null || echo 0)
            low=$(echo "$counts" | jsonfilter -e '@.low' 2>/dev/null || echo 0)
            info_count=$(echo "$counts" | jsonfilter -e '@.informational' 2>/dev/null || echo 0)
        else
            high=$(echo "$counts" | grep -o '"high":[0-9]*' | grep -o '[0-9]*$' || echo 0)
            med=$(echo "$counts" | grep -o '"medium":[0-9]*' | grep -o '[0-9]*$' || echo 0)
            low=$(echo "$counts" | grep -o '"low":[0-9]*' | grep -o '[0-9]*$' || echo 0)
            info_count=$(echo "$counts" | grep -o '"informational":[0-9]*' | grep -o '[0-9]*$' || echo 0)
        fi
        warning_count=$((high + med + low))
    fi

    send_response "Rayhunter Status" "Router: $router_uptime
Modem: ${modem_uptime:-unavailable}
Daemon PID: ${daemon_pid:-not running}
Memory: ${free_mem:-unknown}
Recording: $rec_status
Modem disk: ${modem_disk:-unknown}
SD card: ${sd_disk:-not mounted}
Warnings: $warning_count (info: $info_count)"
}

cmd_start() {
    local result
    result=$(api_post "$RAYHUNTER_API/api/start-recording")
    if [ $? -eq 0 ]; then
        send_response "Recording Started" "Start recording command sent successfully.${result:+ Response: $result}"
    else
        send_response "Recording Start Failed" "Failed to start recording.${result:+ Error: $result}"
    fi
}

cmd_stop() {
    local result
    result=$(api_post "$RAYHUNTER_API/api/stop-recording")
    if [ $? -eq 0 ]; then
        send_response "Recording Stopped" "Stop recording command sent successfully.${result:+ Response: $result}"
    else
        send_response "Recording Stop Failed" "Failed to stop recording.${result:+ Error: $result}"
    fi
}

cmd_restart() {
    send_response "Restarting Daemon" "Stopping rayhunter-daemon..."
    adb shell '/etc/init.d/rayhunter_daemon stop' 2>/dev/null
    sleep 2
    adb shell '/etc/init.d/rayhunter_daemon start' 2>/dev/null
    sleep 3

    local new_pid
    new_pid=$(adb shell pidof rayhunter-daemon 2>/dev/null | tr -d '\r')
    if [ -n "$new_pid" ]; then
        send_response "Daemon Restarted" "rayhunter-daemon restarted successfully. New PID: $new_pid"
    else
        send_response "Daemon Restart Failed" "rayhunter-daemon may not have restarted. Check modem logs."
    fi
}

cmd_warnings() {
    local counts
    counts=$(api_get "$RAYHUNTER_API/api/analysis-counts/live")

    if [ -z "$counts" ]; then
        send_response "Warnings" "Could not fetch analysis counts from daemon API."
        return
    fi

    local high_count med_count low_count info_count total
    if command -v jsonfilter >/dev/null 2>&1; then
        high_count=$(echo "$counts" | jsonfilter -e '@.high' 2>/dev/null || echo 0)
        med_count=$(echo "$counts" | jsonfilter -e '@.medium' 2>/dev/null || echo 0)
        low_count=$(echo "$counts" | jsonfilter -e '@.low' 2>/dev/null || echo 0)
        info_count=$(echo "$counts" | jsonfilter -e '@.informational' 2>/dev/null || echo 0)
    else
        high_count=$(echo "$counts" | grep -o '"high":[0-9]*' | grep -o '[0-9]*$' || echo 0)
        med_count=$(echo "$counts" | grep -o '"medium":[0-9]*' | grep -o '[0-9]*$' || echo 0)
        low_count=$(echo "$counts" | grep -o '"low":[0-9]*' | grep -o '[0-9]*$' || echo 0)
        info_count=$(echo "$counts" | grep -o '"informational":[0-9]*' | grep -o '[0-9]*$' || echo 0)
    fi
    total=$((high_count + med_count + low_count))

    if [ "$total" -eq 0 ] && [ "$info_count" -eq 0 ]; then
        send_response "Warning Summary" "No warnings detected. All clear."
    else
        send_response "Warning Summary" "Total warnings: $total
  High: $high_count
  Medium: $med_count
  Low: $low_count
  Informational: $info_count"
    fi
}

# --- Main poll loop ---
# Track last seen message ID to avoid gaps between polls.
# First poll uses a time window; subsequent polls use the last ID.
last_id=""

while true; do
    if [ -n "$last_id" ]; then
        since_param="since=$last_id"
    else
        since_param="since=30s"
    fi

    messages=""
    if command -v curl >/dev/null 2>&1; then
        messages=$(curl -s --max-time 15 "$CMD_URL/json?poll=1&$since_param" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        messages=$(wget -q -O - --timeout=15 "$CMD_URL/json?poll=1&$since_param" 2>/dev/null)
    fi

    if [ -n "$messages" ]; then
        # Update last_id from the final message to avoid gaps on next poll
        new_last_id=""
        if command -v jsonfilter >/dev/null 2>&1; then
            new_last_id=$(echo "$messages" | tail -1 | jsonfilter -e '@.id' 2>/dev/null)
        else
            new_last_id=$(echo "$messages" | tail -1 | grep -o '"id":"[^"]*"' | sed 's/"id":"//;s/"$//')
        fi
        [ -n "$new_last_id" ] && last_id="$new_last_id"

        echo "$messages" | while IFS= read -r line; do
            [ -z "$line" ] && continue

            # Extract the message field from JSON
            cmd=""
            if command -v jsonfilter >/dev/null 2>&1; then
                cmd=$(echo "$line" | jsonfilter -e '@.message' 2>/dev/null)
            else
                # Fallback: simple grep extraction
                cmd=$(echo "$line" | grep -o '"message":"[^"]*"' | sed 's/"message":"//;s/"$//')
            fi

            [ -z "$cmd" ] && continue

            # Normalize: lowercase and trim whitespace
            cmd=$(echo "$cmd" | tr 'A-Z' 'a-z' | sed 's/^[ \t]*//;s/[ \t]*$//')

            logger -t rayhunter-cmd "Received command: $cmd"

            case "$cmd" in
                status)   cmd_status ;;
                start)    cmd_start ;;
                stop)     cmd_stop ;;
                restart)  cmd_restart ;;
                warnings) cmd_warnings ;;
                *)
                    send_response "Unknown Command" "Unknown command: $cmd. Supported commands: status, start, stop, restart, warnings"
                    ;;
            esac
        done
    fi

    sleep "$POLL_INTERVAL"
done
