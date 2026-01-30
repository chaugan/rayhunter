#!/bin/sh
#
# rayhunter-disk-monitor.sh
#
# Background service that monitors modem and SD card disk usage.
# When modem storage hits 95%, rotates the recording and triggers
# a sync+cleanup cycle. When SD card hits 95%, warns via ntfy.
#
# Usage:
#   rayhunter-disk-monitor.sh <ntfy_url>

RAYHUNTER_API="http://127.0.0.1:8080"
NTFY_URL="${1:-}"
CHECK_INTERVAL=60
MODEM_THRESHOLD=95
SD_THRESHOLD=95

if [ -z "$NTFY_URL" ]; then
    echo "Usage: $0 <ntfy_url>" >&2
    exit 1
fi

STATUS_URL="${NTFY_URL}-status"

logger -t rayhunter-disk "Starting disk monitor (status=$STATUS_URL)"

# --- Helper: post a notification to the status topic ---
send_status() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"

    if command -v curl >/dev/null 2>&1; then
        curl -s -o /dev/null \
            -H "Title: $title" \
            -H "Priority: $priority" \
            -d "$message" \
            "$STATUS_URL"
    elif command -v wget >/dev/null 2>&1; then
        echo "$message" | wget -q -O /dev/null \
            --header="Title: $title" \
            --header="Priority: $priority" \
            --post-file=- \
            "$STATUS_URL"
    fi
}

# --- Helper: fetch a URL and return the body ---
api_get() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -s --max-time 10 "$url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O - --timeout=10 "$url" 2>/dev/null
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

# --- Get disk usage percentage (numeric, no %) ---
get_modem_disk_pct() {
    adb shell df /data 2>/dev/null | tr -d '\r' | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

get_sd_disk_pct() {
    df /mnt/sda1 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

# --- Main loop ---
while true; do
    # Check modem storage
    modem_pct=$(get_modem_disk_pct)
    if [ -n "$modem_pct" ] && [ "$modem_pct" -ge "$MODEM_THRESHOLD" ] 2>/dev/null; then
        logger -t rayhunter-disk "Modem storage critical: ${modem_pct}%"
        send_status "Disk Warning" "Modem storage critical (${modem_pct}%), rotating recording" "high"

        # Stop recording so current becomes a completed entry
        api_post "$RAYHUNTER_API/api/stop-recording"
        sleep 5

        # Trigger sync to copy files to SD card
        if [ -x /usr/local/bin/rayhunter-sync-sd.sh ]; then
            /usr/local/bin/rayhunter-sync-sd.sh
        fi

        # Delete all completed entries via API
        manifest=$(api_get "$RAYHUNTER_API/api/qmdl-manifest")
        if [ -n "$manifest" ]; then
            entry_names=""
            if command -v jsonfilter >/dev/null 2>&1; then
                entry_names=$(echo "$manifest" | jsonfilter -e '@.entries[*].name' 2>/dev/null)
            else
                entry_names=$(echo "$manifest" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//')
            fi

            if [ -n "$entry_names" ]; then
                echo "$entry_names" | while IFS= read -r name; do
                    [ -z "$name" ] && continue
                    logger -t rayhunter-disk "Deleting recording: $name"
                    api_post "$RAYHUNTER_API/api/delete-recording/$name"
                done
            fi
        fi

        # Resume recording
        api_post "$RAYHUNTER_API/api/start-recording"

        new_pct=$(get_modem_disk_pct)
        logger -t rayhunter-disk "Rotation complete, modem disk now ${new_pct:-unknown}%"
        send_status "Disk Rotation Complete" "Modem storage after cleanup: ${new_pct:-unknown}%" "low"
    fi

    # Check SD card storage
    sd_pct=$(get_sd_disk_pct)
    if [ -n "$sd_pct" ] && [ "$sd_pct" -ge "$SD_THRESHOLD" ] 2>/dev/null; then
        logger -t rayhunter-disk "SD card nearly full: ${sd_pct}%"
        send_status "SD Card Warning" "SD card nearly full (${sd_pct}%). Consider freeing space manually." "high"
    fi

    sleep "$CHECK_INTERVAL"
done
