#!/bin/sh
#
# rayhunter-ntfy-manager.sh
#
# Consolidated service manager for ntfy-based services (notify, cmd, disk-monitor).
# Polls /api/config for ntfy_url changes and manages child service lifecycles.
#
# Usage: rayhunter-ntfy-manager.sh &
#

POLL_INTERVAL=30
API_URL="http://127.0.0.1:8080/api/config"
TAG="rayhunter-mgr"

# Sentinel value: API unreachable (distinct from empty ntfy_url)
API_UNREACHABLE="__API_UNREACHABLE__"

current_ntfy_url=""
notify_pid=""
cmd_pid=""
disk_pid=""

cleanup() {
    logger -t "$TAG" "Shutting down, killing child services..."
    kill_children
    exit 0
}

trap cleanup TERM INT

fetch_ntfy_url() {
    local config_json=""
    if command -v curl >/dev/null 2>&1; then
        config_json=$(curl -s --max-time 5 "$API_URL" 2>/dev/null)
    else
        config_json=$(wget -q -O - "$API_URL" 2>/dev/null)
    fi

    if [ -z "$config_json" ]; then
        echo "$API_UNREACHABLE"
        return
    fi

    local url=""
    if command -v jsonfilter >/dev/null 2>&1; then
        url=$(echo "$config_json" | jsonfilter -e '@.ntfy_url' 2>/dev/null)
    else
        url=$(echo "$config_json" | grep '"ntfy_url"' | grep -o 'https*://[^"]*')
    fi

    echo "$url"
}

kill_children() {
    for pid in $notify_pid $cmd_pid $disk_pid; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    notify_pid=""
    cmd_pid=""
    disk_pid=""
}

start_children() {
    local url="$1"
    logger -t "$TAG" "Starting child services (ntfy_url=$url)"

    if [ -x /usr/local/bin/rayhunter-notify.sh ]; then
        /usr/local/bin/rayhunter-notify.sh "$url" 30 &
        notify_pid=$!
        logger -t "$TAG" "Started rayhunter-notify.sh (pid=$notify_pid)"
    fi

    if [ -x /usr/local/bin/rayhunter-cmd.sh ]; then
        /usr/local/bin/rayhunter-cmd.sh "$url" &
        cmd_pid=$!
        logger -t "$TAG" "Started rayhunter-cmd.sh (pid=$cmd_pid)"
    fi

    if [ -x /usr/local/bin/rayhunter-disk-monitor.sh ]; then
        /usr/local/bin/rayhunter-disk-monitor.sh "$url" &
        disk_pid=$!
        logger -t "$TAG" "Started rayhunter-disk-monitor.sh (pid=$disk_pid)"
    fi

    # Send boot/config-change notification
    if command -v curl >/dev/null 2>&1; then
        curl -s -o /dev/null \
            -H "Title: Rayhunter Online" \
            -H "Priority: low" \
            -H "Tags: white_check_mark" \
            -d "Rayhunter has started and is monitoring for IMSI catchers." \
            "$url" 2>/dev/null || true
    fi
}

children_alive() {
    # Returns 0 (true) if all started children are still running
    if [ -n "$notify_pid" ] && ! kill -0 "$notify_pid" 2>/dev/null; then
        return 1
    fi
    if [ -n "$cmd_pid" ] && ! kill -0 "$cmd_pid" 2>/dev/null; then
        return 1
    fi
    if [ -n "$disk_pid" ] && ! kill -0 "$disk_pid" 2>/dev/null; then
        return 1
    fi
    return 0
}

logger -t "$TAG" "Service manager started, polling every ${POLL_INTERVAL}s"

while true; do
    new_url=$(fetch_ntfy_url)

    if [ "$new_url" = "$API_UNREACHABLE" ]; then
        # API temporarily down (e.g. daemon restarting) - don't touch children
        logger -t "$TAG" "API unreachable, keeping current state"
    elif [ -z "$new_url" ]; then
        # ntfy_url is empty/cleared
        if [ -n "$current_ntfy_url" ]; then
            logger -t "$TAG" "ntfy_url cleared, stopping child services"
            kill_children
            current_ntfy_url=""
        fi
    elif [ "$new_url" != "$current_ntfy_url" ]; then
        # URL appeared or changed
        if [ -n "$current_ntfy_url" ]; then
            logger -t "$TAG" "ntfy_url changed, restarting child services"
        else
            logger -t "$TAG" "ntfy_url detected: $new_url"
        fi
        kill_children
        start_children "$new_url"
        current_ntfy_url="$new_url"
    else
        # URL unchanged - health check children
        if [ -n "$current_ntfy_url" ] && ! children_alive; then
            logger -t "$TAG" "Child process died, restarting all services"
            kill_children
            start_children "$current_ntfy_url"
        fi
    fi

    sleep "$POLL_INTERVAL" &
    wait $!
done
