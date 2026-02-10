#!/bin/sh
#
# rayhunter-signal.sh
#
# Polls EP06 modem AT commands for signal quality data and writes
# JSON to the modem filesystem via adb shell.
#
# Usage: rayhunter-signal.sh
# Designed to run as a child of rayhunter-ntfy-manager.sh
#

POLL_INTERVAL=5
AT_PORT="/dev/ttyUSB2"
SIGNAL_FILE="/tmp/rayhunter-signal.json"
TAG="rayhunter-signal"

cleanup() {
    logger -t "$TAG" "Shutting down"
    exit 0
}

trap cleanup TERM INT

# Send an AT command and capture the response
# Uses echo + timeout cat on the serial port at 9600 baud
at_cmd() {
    local cmd="$1"
    echo -ne "${cmd}\r" > "$AT_PORT"
    timeout 2 cat "$AT_PORT"
}

# Initialize serial port
init_port() {
    stty -F "$AT_PORT" 9600 2>/dev/null
}

# Parse +QENG: "servingcell" response for LTE FDD
# Actual response format observed:
# +QENG: "servingcell","NOCONN","LTE","FDD",242,02,1D60114,199,2850,7,5,5,AF7,-103,-17,-66,11,-
parse_serving_cell() {
    local line="$1"
    # Strip +QENG: prefix and quotes, extract CSV fields
    local data=$(echo "$line" | sed 's/+QENG: "servingcell",//;s/"//g')

    local state=$(echo "$data" | cut -d',' -f1)
    local tech=$(echo "$data" | cut -d',' -f2)
    local duplex=$(echo "$data" | cut -d',' -f3)
    local mcc=$(echo "$data" | cut -d',' -f4)
    local mnc=$(echo "$data" | cut -d',' -f5)
    local cell_id=$(echo "$data" | cut -d',' -f6)
    local pci=$(echo "$data" | cut -d',' -f7)
    local earfcn=$(echo "$data" | cut -d',' -f8)
    local band=$(echo "$data" | cut -d',' -f9)
    # fields 10,11 = ul_bw, dl_bw (skip)
    # field 12 = tac (skip)
    local rsrp=$(echo "$data" | cut -d',' -f13)
    local rsrq=$(echo "$data" | cut -d',' -f14)
    local rssi=$(echo "$data" | cut -d',' -f15)
    local sinr=$(echo "$data" | cut -d',' -f16)

    # Validate we got numeric signal values
    if [ -z "$rsrp" ] || [ "$rsrp" = "-" ]; then
        return 1
    fi

    printf '"serving_cell":{"state":"%s","tech":"%s","duplex":"%s","mcc":"%s","mnc":"%s","cell_id":"%s","pci":%s,"earfcn":%s,"band":%s,"rsrp":%s,"rsrq":%s,"rssi":%s,"sinr":%s}' \
        "$state" "$tech" "$duplex" "$mcc" "$mnc" "$cell_id" \
        "${pci:-0}" "${earfcn:-0}" "${band:-0}" "${rsrp:-0}" "${rsrq:-0}" "${rssi:-0}" "${sinr:-0}"
}

# Parse +QENG: "neighbourcell" responses
# Actual response format observed:
# +QENG: "neighbourcell intra","LTE",2850,199,-16,-103,-67,0,-,-,-,-,-
# +QENG: "neighbourcell inter","LTE",1650,220,-14,-89,-67,0,-,-,-,-
parse_neighbour_cells() {
    local response="$1"
    local result=""
    local sep=""

    # Process each line - avoid subshell by using a temp file
    local tmpfile="/tmp/rayhunter-nc-$$"
    echo "$response" | grep '+QENG: "neighbourcell' > "$tmpfile"

    while IFS= read -r line; do
        # Determine type (intra/inter)
        local nctype=""
        case "$line" in
            *"neighbourcell intra"*) nctype="intra" ;;
            *"neighbourcell inter"*) nctype="inter" ;;
            *) nctype="unknown" ;;
        esac

        # Strip prefix and quotes
        local data=$(echo "$line" | sed 's/+QENG: "neighbourcell [^"]*",//;s/"//g')
        # data now: LTE,<earfcn>,<pci>,<rsrq>,<rsrp>,<rssi>,...
        local earfcn=$(echo "$data" | cut -d',' -f2)
        local pci=$(echo "$data" | cut -d',' -f3)
        local rsrq=$(echo "$data" | cut -d',' -f4)
        local rsrp=$(echo "$data" | cut -d',' -f5)
        local rssi=$(echo "$data" | cut -d',' -f6)

        # Skip empty/invalid entries (PCI=0 and RSRP=0 means no real cell)
        if [ -z "$earfcn" ] || [ "$earfcn" = "-" ]; then
            continue
        fi
        if [ "$pci" = "0" ] && [ "$rsrp" = "0" ]; then
            continue
        fi

        result="${result}${sep}{\"type\":\"${nctype}\",\"earfcn\":${earfcn:-0},\"pci\":${pci:-0},\"rsrq\":${rsrq:-0},\"rsrp\":${rsrp:-0},\"rssi\":${rssi:-0}}"
        sep=","
    done < "$tmpfile"

    rm -f "$tmpfile"
    printf '"neighbour_cells":[%s]' "$result"
}

logger -t "$TAG" "Signal quality poller started (port=$AT_PORT, interval=${POLL_INTERVAL}s)"

# Verify AT port exists
if [ ! -e "$AT_PORT" ]; then
    logger -t "$TAG" "AT port $AT_PORT not found, exiting"
    exit 1
fi

# Initialize port settings
init_port

while true; do
    # Query serving cell
    serving_response=$(at_cmd 'AT+QENG="servingcell"')
    serving_line=$(echo "$serving_response" | grep '+QENG: "servingcell"')

    if [ -z "$serving_line" ]; then
        logger -t "$TAG" "No serving cell response, retrying..."
        sleep "$POLL_INTERVAL"
        continue
    fi

    serving_json=$(parse_serving_cell "$serving_line")
    if [ $? -ne 0 ] || [ -z "$serving_json" ]; then
        logger -t "$TAG" "Failed to parse serving cell, retrying..."
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Query neighbour cells
    neighbour_response=$(at_cmd 'AT+QENG="neighbourcell"')
    neighbour_json=$(parse_neighbour_cells "$neighbour_response")

    # Build final JSON
    timestamp=$(date +%s)
    json="{\"timestamp\":${timestamp},${serving_json},${neighbour_json}}"

    # Write to local temp file, then push to modem via adb
    local_tmp="/tmp/rayhunter-signal-tmp.json"
    echo "$json" > "$local_tmp"
    adb push "$local_tmp" "$SIGNAL_FILE" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        logger -t "$TAG" "Failed to write signal data to modem"
    fi

    sleep "$POLL_INTERVAL"
done
