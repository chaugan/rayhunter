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

# Track last counts so we only notify on new events
last_warning_count=0
last_info_count=0
# Temperature state machine
temp_state="clear"          # clear | alerting | recovery
last_alert_sent=0           # epoch when last alert was sent
recovery_entered=0          # epoch when recovery state was entered
alert_repeat_count=0        # repeat alerts sent this breach (max ALERT_REPEAT_MAX)
ALERT_REPEAT_INTERVAL=1800  # 30 min between repeat alerts while in danger zone
ALERT_REPEAT_MAX=5          # stop repeating after 5 alerts per breach
RECOVERY_HOLD=300           # must stay normal 5 min before re-arming
TEMP_HIGH=75                # high threshold (Celsius)
TEMP_LOW=5                  # low threshold (Celsius)
if [ -f "$STATE_FILE" ]; then
    last_warning_count=$(sed -n '1p' "$STATE_FILE" 2>/dev/null || echo 0)
    last_info_count=$(sed -n '2p' "$STATE_FILE" 2>/dev/null || echo 0)
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
    # Fetch analysis counts (lightweight JSON instead of full report)
    counts=""
    if command -v curl >/dev/null 2>&1; then
        counts=$(curl -s --max-time 10 "$RAYHUNTER_API/api/analysis-counts/live" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        counts=$(wget -q -O - --timeout=10 "$RAYHUNTER_API/api/analysis-counts/live" 2>/dev/null)
    fi

    if [ -n "$counts" ]; then
        # Parse JSON counts
        high=0; medium=0; low=0; informational=0
        if command -v jsonfilter >/dev/null 2>&1; then
            high=$(echo "$counts" | jsonfilter -e '@.high' 2>/dev/null || echo 0)
            medium=$(echo "$counts" | jsonfilter -e '@.medium' 2>/dev/null || echo 0)
            low=$(echo "$counts" | jsonfilter -e '@.low' 2>/dev/null || echo 0)
            informational=$(echo "$counts" | jsonfilter -e '@.informational' 2>/dev/null || echo 0)
        else
            # Fallback: grep extraction from JSON
            high=$(echo "$counts" | grep -o '"high":[0-9]*' | grep -o '[0-9]*$' || echo 0)
            medium=$(echo "$counts" | grep -o '"medium":[0-9]*' | grep -o '[0-9]*$' || echo 0)
            low=$(echo "$counts" | grep -o '"low":[0-9]*' | grep -o '[0-9]*$' || echo 0)
            informational=$(echo "$counts" | grep -o '"informational":[0-9]*' | grep -o '[0-9]*$' || echo 0)
        fi
        warning_count=$((high + medium + low))
        info_count=$((informational + 0))

        # Reset counters if a new recording session started (counts dropped)
        if [ "$warning_count" -lt "$last_warning_count" ] || [ "$info_count" -lt "$last_info_count" ]; then
            logger -t rayhunter-notify "New recording session detected, resetting counters"
            last_warning_count=0
            last_info_count=0
        fi

        if [ "$warning_count" -gt "$last_warning_count" ]; then
            new_warnings=$((warning_count - last_warning_count))
            logger -t rayhunter-notify "Detected $new_warnings new warning(s) (total: $warning_count)"

            send_notification \
                "Rayhunter Alert" \
                "Rayhunter detected $new_warnings new warning event(s). Total warnings: $warning_count. Check the web UI for details." \
                "high"

            last_warning_count=$warning_count
        fi

        if [ "$info_count" -gt "$last_info_count" ]; then
            new_infos=$((info_count - last_info_count))
            logger -t rayhunter-notify "Detected $new_infos new info event(s) (total: $info_count)"

            send_notification \
                "Rayhunter Info" \
                "Rayhunter test notification received. The notification pipeline is working correctly." \
                "low"

            last_info_count=$info_count
        fi

        # Save both counts
        printf '%s\n%s\n' "$last_warning_count" "$last_info_count" > "$STATE_FILE"
    fi

    # Temperature alerts (state machine: clear -> alerting -> recovery -> clear)
    temp_json=""
    if command -v curl >/dev/null 2>&1; then
        temp_json=$(curl -s --max-time 5 "$RAYHUNTER_API/api/temperature" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        temp_json=$(wget -q -O - --timeout=5 "$RAYHUNTER_API/api/temperature" 2>/dev/null)
    fi

    if [ -n "$temp_json" ]; then
        max_temp=""
        if command -v jsonfilter >/dev/null 2>&1; then
            max_temp=$(echo "$temp_json" | jsonfilter -e '@.max_temp' 2>/dev/null)
        else
            max_temp=$(echo "$temp_json" | grep -o '"max_temp":[0-9-]*' | grep -o '[0-9-]*$')
        fi

        if [ -n "$max_temp" ]; then
            now=$(date +%s)
            temp_abnormal=0
            temp_label=""
            if [ "$max_temp" -gt "$TEMP_HIGH" ]; then
                temp_abnormal=1
                temp_label="HIGH"
            elif [ "$max_temp" -lt "$TEMP_LOW" ]; then
                temp_abnormal=1
                temp_label="LOW"
            fi

            if [ "$temp_state" = "clear" ]; then
                if [ "$temp_abnormal" -eq 1 ]; then
                    send_notification \
                        "Temperature Alert: $temp_label" \
                        "Modem temperature is ${max_temp}C (threshold: ${TEMP_HIGH}C high / ${TEMP_LOW}C low). Check ventilation." \
                        "high"
                    last_alert_sent=$now
                    alert_repeat_count=0
                    temp_state="alerting"
                    logger -t rayhunter-notify "Temperature $temp_label alert: ${max_temp}C [clear -> alerting]"
                fi

            elif [ "$temp_state" = "alerting" ]; then
                if [ "$temp_abnormal" -eq 0 ]; then
                    send_notification \
                        "Temperature Recovered" \
                        "Modem temperature back to normal at ${max_temp}C." \
                        "low"
                    recovery_entered=$now
                    temp_state="recovery"
                    logger -t rayhunter-notify "Temperature recovered: ${max_temp}C [alerting -> recovery]"
                else
                    elapsed_since_alert=$((now - last_alert_sent))
                    if [ "$alert_repeat_count" -lt "$ALERT_REPEAT_MAX" ] && [ "$elapsed_since_alert" -ge "$ALERT_REPEAT_INTERVAL" ]; then
                        alert_repeat_count=$((alert_repeat_count + 1))
                        send_notification \
                            "Temperature Still $temp_label" \
                            "Modem still at ${max_temp}C for ${ALERT_REPEAT_INTERVAL}+ sec (repeat ${alert_repeat_count}/${ALERT_REPEAT_MAX})." \
                            "default"
                        last_alert_sent=$now
                        logger -t rayhunter-notify "Temperature repeat alert ${alert_repeat_count}/${ALERT_REPEAT_MAX}: ${max_temp}C"
                    fi
                fi

            elif [ "$temp_state" = "recovery" ]; then
                if [ "$temp_abnormal" -eq 1 ]; then
                    elapsed_since_alert=$((now - last_alert_sent))
                    if [ "$alert_repeat_count" -lt "$ALERT_REPEAT_MAX" ] && [ "$elapsed_since_alert" -ge "$ALERT_REPEAT_INTERVAL" ]; then
                        alert_repeat_count=$((alert_repeat_count + 1))
                        send_notification \
                            "Temperature Relapsed: $temp_label" \
                            "Modem temperature back to ${max_temp}C (repeat ${alert_repeat_count}/${ALERT_REPEAT_MAX})." \
                            "high"
                        last_alert_sent=$now
                        logger -t rayhunter-notify "Temperature relapse alert ${alert_repeat_count}/${ALERT_REPEAT_MAX}: ${max_temp}C [recovery -> alerting]"
                    else
                        logger -t rayhunter-notify "Temperature relapsed: ${max_temp}C [recovery -> alerting] (repeat suppressed)"
                    fi
                    temp_state="alerting"
                else
                    elapsed_in_recovery=$((now - recovery_entered))
                    if [ "$elapsed_in_recovery" -ge "$RECOVERY_HOLD" ]; then
                        temp_state="clear"
                        alert_repeat_count=0
                        logger -t rayhunter-notify "Temperature stable for ${RECOVERY_HOLD}s, re-armed [recovery -> clear]"
                    fi
                fi
            fi
        fi
    fi

    sleep "$POLL_INTERVAL"
done
