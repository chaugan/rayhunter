#!/bin/sh
#
# rayhunter-temperature.sh
#
# Polls EP06 modem thermal zones via adb and writes JSON to the modem
# filesystem for the rayhunter daemon to serve via API.
#
# Usage: rayhunter-temperature.sh
# Designed to run as a child of rayhunter-ntfy-manager.sh
#

POLL_INTERVAL=10
TEMP_FILE="/tmp/rayhunter-temperature.json"
TAG="rayhunter-temperature"

cleanup() {
    logger -t "$TAG" "Shutting down"
    exit 0
}

trap cleanup TERM INT

logger -t "$TAG" "Temperature poller started (interval=${POLL_INTERVAL}s)"

while true; do
    # Read all thermal zone temperatures from the modem
    raw=$(adb shell "cat /sys/class/thermal/thermal_zone*/temp" 2>/dev/null | tr -d '\r')

    if [ -z "$raw" ]; then
        logger -t "$TAG" "No thermal data from modem, retrying..."
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Build JSON array of zone temps and find max
    zones=""
    max_temp=-999
    sep=""

    for temp in $raw; do
        # Validate numeric
        case "$temp" in
            *[!0-9-]*) continue ;;
        esac
        zones="${zones}${sep}${temp}"
        sep=","
        if [ "$temp" -gt "$max_temp" ]; then
            max_temp=$temp
        fi
    done

    if [ -z "$zones" ] || [ "$max_temp" = "-999" ]; then
        logger -t "$TAG" "Failed to parse thermal data, retrying..."
        sleep "$POLL_INTERVAL"
        continue
    fi

    timestamp=$(date +%s)
    json="{\"timestamp\":${timestamp},\"zones\":[${zones}],\"max_temp\":${max_temp}}"

    # Write to local temp file, then push to modem via adb
    local_tmp="/tmp/rayhunter-temperature-tmp.json"
    echo "$json" > "$local_tmp"
    adb push "$local_tmp" "$TEMP_FILE" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        logger -t "$TAG" "Failed to write temperature data to modem"
    fi

    sleep "$POLL_INTERVAL"
done
