#!/bin/sh
#
# rayhunter-disk-monitor.sh
#
# Background service that monitors modem and SD card disk usage.
# Rotates recordings when size or disk thresholds are hit, and
# cleans up old files on the SD card when it fills up.
#
# Usage:
#   rayhunter-disk-monitor.sh <ntfy_url>

RAYHUNTER_API="http://127.0.0.1:8080"
NTFY_URL="${1:-}"
CHECK_INTERVAL=60
MODEM_THRESHOLD=80
SD_THRESHOLD=90
ROTATION_SIZE_MB=30
SD_QMDL_DIR="/mnt/sda1/rayhunter/qmdl"

if [ -z "$NTFY_URL" ]; then
    echo "Usage: $0 <ntfy_url>" >&2
    exit 1
fi

STATUS_URL="${NTFY_URL}-status"

logger -t rayhunter-disk "Starting disk monitor (modem=${MODEM_THRESHOLD}%, sd=${SD_THRESHOLD}%, rotate=${ROTATION_SIZE_MB}MB)"

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

# --- Get current recording QMDL size in bytes ---
get_current_recording_size() {
    local manifest size_bytes
    manifest=$(api_get "$RAYHUNTER_API/api/qmdl-manifest")
    if [ -z "$manifest" ]; then
        echo 0
        return
    fi
    if command -v jsonfilter >/dev/null 2>&1; then
        size_bytes=$(echo "$manifest" | jsonfilter -e '@.current_entry.qmdl_size_bytes' 2>/dev/null)
    else
        size_bytes=$(echo "$manifest" | grep -o '"qmdl_size_bytes":[0-9]*' | head -1 | grep -o '[0-9]*$')
    fi
    echo "${size_bytes:-0}"
}

# --- Rotate recording: stop, sync, delete, restart ---
rotate_recording() {
    local reason="$1"
    logger -t rayhunter-disk "Rotating recording: $reason"

    # Stop recording so current becomes a completed entry
    api_post "$RAYHUNTER_API/api/stop-recording"
    sleep 5

    # Trigger sync to copy files to SD card
    if [ -x /usr/local/bin/rayhunter-sync-sd.sh ]; then
        /usr/local/bin/rayhunter-sync-sd.sh
    fi

    # Delete all recordings via API
    api_post "$RAYHUNTER_API/api/delete-all-recordings"
    sleep 2

    # Resume recording
    api_post "$RAYHUNTER_API/api/start-recording"

    local new_pct
    new_pct=$(get_modem_disk_pct)
    logger -t rayhunter-disk "Rotation complete ($reason), modem disk now ${new_pct:-unknown}%"
    send_status "Recording Rotated" "Reason: $reason. Modem storage after cleanup: ${new_pct:-unknown}%" "low"
}

# --- Clean up oldest files on SD card ---
cleanup_sd_card() {
    local target_pct deleted_count sd_pct
    target_pct=$((SD_THRESHOLD - 10))
    deleted_count=0

    logger -t rayhunter-disk "SD cleanup starting (target: ${target_pct}%)"

    # List .qmdl files oldest-first
    for qmdl_file in $(ls -1tr "$SD_QMDL_DIR"/*.qmdl 2>/dev/null); do
        sd_pct=$(get_sd_disk_pct)
        if [ -n "$sd_pct" ] && [ "$sd_pct" -le "$target_pct" ] 2>/dev/null; then
            break
        fi

        # Delete .qmdl and matching .ndjson
        local base_name
        base_name=$(echo "$qmdl_file" | sed 's/\.qmdl$//')
        logger -t rayhunter-disk "Deleting old SD file: $(basename "$qmdl_file")"
        rm -f "$qmdl_file" "${base_name}.ndjson"
        deleted_count=$((deleted_count + 1))
    done

    sd_pct=$(get_sd_disk_pct)
    logger -t rayhunter-disk "SD cleanup done: deleted $deleted_count file(s), now ${sd_pct:-unknown}%"
    if [ "$deleted_count" -gt 0 ]; then
        send_status "SD Cleanup" "Deleted $deleted_count old recording(s). SD now ${sd_pct:-unknown}%." "low"
    fi
}

# --- Main loop ---
while true; do
    # 1. Size-based rotation: if current recording > ROTATION_SIZE_MB
    rec_size=$(get_current_recording_size)
    rec_size_mb=$((rec_size / 1048576))
    if [ "$rec_size_mb" -ge "$ROTATION_SIZE_MB" ] 2>/dev/null; then
        rotate_recording "recording size ${rec_size_mb}MB >= ${ROTATION_SIZE_MB}MB"
    fi

    # 2. Modem disk threshold: safety net
    modem_pct=$(get_modem_disk_pct)
    if [ -n "$modem_pct" ] && [ "$modem_pct" -ge "$MODEM_THRESHOLD" ] 2>/dev/null; then
        rotate_recording "modem disk ${modem_pct}% >= ${MODEM_THRESHOLD}%"
    fi

    # 3. SD card threshold: clean up old files
    sd_pct=$(get_sd_disk_pct)
    if [ -n "$sd_pct" ] && [ "$sd_pct" -ge "$SD_THRESHOLD" ] 2>/dev/null; then
        cleanup_sd_card
    fi

    sleep "$CHECK_INTERVAL"
done
