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
#
# The script only copies files that are new or have changed size,
# to avoid redundant transfers.

SD_MOUNT="${1:-/mnt/sda1}"
REMOTE_DIR="/data/rayhunter/qmdl"
LOCAL_DIR="$SD_MOUNT/rayhunter/qmdl"
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
    # Stale lock file
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# Create destination directory
mkdir -p "$LOCAL_DIR"

# Get list of files on the modem
remote_files=$(adb shell "ls -la $REMOTE_DIR/ 2>/dev/null" 2>/dev/null)
if [ -z "$remote_files" ]; then
    logger -t rayhunter-sync "No files found on modem at $REMOTE_DIR"
    rm -f "$LOCK_FILE"
    exit 0
fi

# Sync each file individually, checking if it needs updating
synced=0
skipped=0

# Get list of filenames from the modem
file_list=$(adb shell "ls $REMOTE_DIR/ 2>/dev/null" 2>/dev/null | tr -d '\r')

for filename in $file_list; do
    # Skip directories and manifest files during active recording
    case "$filename" in
        .|..) continue ;;
    esac

    local_file="$LOCAL_DIR/$filename"
    remote_file="$REMOTE_DIR/$filename"

    # Get remote file size
    remote_size=$(adb shell "stat -c %s '$remote_file' 2>/dev/null || wc -c < '$remote_file'" 2>/dev/null | tr -d '\r')
    [ -z "$remote_size" ] && continue

    # Check if local file exists and has the same size
    if [ -f "$local_file" ]; then
        local_size=$(stat -c %s "$local_file" 2>/dev/null || wc -c < "$local_file")
        if [ "$local_size" = "$remote_size" ]; then
            skipped=$((skipped + 1))
            continue
        fi
    fi

    # Pull the file
    if adb pull "$remote_file" "$local_file" >/dev/null 2>&1; then
        synced=$((synced + 1))
    else
        logger -t rayhunter-sync "Failed to pull $filename"
    fi
done

if [ "$synced" -gt 0 ]; then
    logger -t rayhunter-sync "Synced $synced file(s) to $LOCAL_DIR ($skipped unchanged)"
fi
