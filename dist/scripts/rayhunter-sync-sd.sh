#!/bin/sh
#
# rayhunter-sync-sd.sh
#
# Router-side script that syncs QMDL files from the EP06 modem
# to an SD card via ADB. Intended to run periodically via cron.
#
# Usage:
#   rayhunter-sync-sd.sh [sd_mount_point]
#
# Arguments:
#   sd_mount_point  - Where the SD card is mounted (default: /mnt/sda1)

SD_MOUNT="${1:-/mnt/sda1}"
REMOTE_DIR="/data/rayhunter/qmdl"
LOCAL_DIR="$SD_MOUNT/rayhunter"
LOCK_FILE="/tmp/rayhunter-sync.lock"
RAYHUNTER_API="http://127.0.0.1:8080"

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

# Check if SD card is mounted
if ! mount | grep -q "$SD_MOUNT"; then
    logger -t rayhunter-sync "SD card not mounted at $SD_MOUNT, skipping sync"
    exit 0
fi

# Check if ADB device is available
if ! adb devices 2>/dev/null | grep -q "device$"; then
    logger -t rayhunter-sync "No ADB device available, skipping sync"
    exit 0
fi

# Simple lock to prevent concurrent runs
if [ -f "$LOCK_FILE" ]; then
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        logger -t rayhunter-sync "Another sync is running (pid $lock_pid), skipping"
        exit 0
    fi
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# Create destination directory
mkdir -p "$LOCAL_DIR"

# Pull entire qmdl directory. adb pull will skip files that already
# exist with the same size, and will overwrite files that have changed.
output=$(adb pull "$REMOTE_DIR" "$LOCAL_DIR/" 2>&1)
result=$?

if [ $result -eq 0 ]; then
    # Count pulled files from adb output (lines like "path: 1 file pulled")
    pulled=$(echo "$output" | grep -c "pulled" 2>/dev/null || echo 0)
    pulled=$((pulled + 0))
    if [ "$pulled" -gt 0 ]; then
        logger -t rayhunter-sync "Synced files to $LOCAL_DIR ($output)"
    fi

    # Clean up synced recordings from modem (except the active one)
    manifest=$(api_get "$RAYHUNTER_API/api/qmdl-manifest")
    if [ -n "$manifest" ]; then
        # Extract entry names from the entries array
        entry_names=""
        if command -v jsonfilter >/dev/null 2>&1; then
            entry_names=$(echo "$manifest" | jsonfilter -e '@.entries[*].name' 2>/dev/null)
        else
            # Fallback: extract name fields from entries array
            entry_names=$(echo "$manifest" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//')
        fi

        if [ -n "$entry_names" ]; then
            echo "$entry_names" | while IFS= read -r name; do
                [ -z "$name" ] && continue
                logger -t rayhunter-sync "Deleting synced recording from modem: $name"
                api_post "$RAYHUNTER_API/api/delete-recording/$name"
            done
        fi
    fi
else
    logger -t rayhunter-sync "adb pull failed (exit $result): $output"
fi
