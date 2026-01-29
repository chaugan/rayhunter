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
else
    logger -t rayhunter-sync "adb pull failed (exit $result): $output"
fi
