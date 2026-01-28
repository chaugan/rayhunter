#!/bin/sh
#
# install-from-openwrt.sh
#
# Installs Rayhunter onto a Quectel EP06 modem from an OpenWrt router
# (e.g. GL-X750). Run this script on the router via SSH.
#
# Usage:
#   scp install-from-openwrt.sh root@192.168.8.1:/tmp/
#   ssh root@192.168.8.1
#   sh /tmp/install-from-openwrt.sh [/path/to/rayhunter-daemon]
#
# Prerequisites (installed automatically if missing):
#   - android-tools (provides adb)
#   - openssl-util (provides openssl)

set -e

RAYHUNTER_BINARY="${1:-}"
RAYHUNTER_RELEASE_URL="https://github.com/EFForg/rayhunter/releases/latest/download/rayhunter-daemon"

# EP06 USB identifiers
EP06_VID="0x2C7C"
EP06_PID="0x0306"

# ---------- helper functions ----------

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo ">>> $*"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root"
    fi
}

# Send an AT command to the modem and capture the response.
# Usage: response=$(send_at "$port" "AT+CMD")
send_at() {
    local port="$1"
    local cmd="$2"
    local timeout="${3:-2}"

    # Configure serial port
    stty -F "$port" 115200 raw -echo -echoe -echok -echoctl -echoke 2>/dev/null || true

    # Flush input
    cat "$port" > /dev/null 2>&1 &
    local flush_pid=$!
    sleep 0.1
    kill "$flush_pid" 2>/dev/null || true
    wait "$flush_pid" 2>/dev/null || true

    # Send command
    printf '%s\r\n' "$cmd" > "$port"

    # Read response with timeout
    local response=""
    response=$(timeout "$timeout" cat "$port" 2>/dev/null) || true
    echo "$response"
}

# ---------- step 0: check prerequisites ----------

check_prerequisites() {
    log "Checking prerequisites..."

    local pkg_dir="/tmp/rayhunter-packages"

    if ! command -v adb > /dev/null 2>&1; then
        log "adb not found, installing android-tools..."
        if ls "$pkg_dir"/android-tools*.ipk 1>/dev/null 2>&1; then
            opkg install "$pkg_dir"/*.ipk 2>/dev/null || true
        else
            opkg update && opkg install android-tools || die "Failed to install android-tools. Transfer .ipk packages to $pkg_dir or provide internet access."
        fi
        command -v adb > /dev/null 2>&1 || die "adb still not available after package install."
    fi

    if ! command -v openssl > /dev/null 2>&1; then
        log "openssl not found, installing openssl-util..."
        if ls "$pkg_dir"/openssl-util*.ipk 1>/dev/null 2>&1; then
            opkg install "$pkg_dir"/*.ipk 2>/dev/null || true
        else
            opkg update 2>/dev/null && opkg install openssl-util || die "Failed to install openssl-util. Transfer .ipk packages to $pkg_dir or provide internet access."
        fi
        command -v openssl > /dev/null 2>&1 || die "openssl still not available after package install."
    fi

    log "Prerequisites satisfied."
}

# ---------- step 1: detect AT command port ----------

detect_at_port() {
    log "Scanning for modem AT command port..."

    local at_port=""
    for port in /dev/ttyUSB*; do
        [ -e "$port" ] || continue
        log "  Trying $port..."
        local resp
        resp=$(send_at "$port" "AT" 2)
        if echo "$resp" | grep -q "OK"; then
            at_port="$port"
            log "  Found AT port: $at_port"
            break
        fi
    done

    if [ -z "$at_port" ]; then
        die "Could not find modem AT command port. Are /dev/ttyUSB* devices present?"
    fi

    AT_PORT="$at_port"
}

# ---------- step 2: save current USB config ----------

save_usb_config() {
    log "Reading current USB configuration..."
    local resp
    resp=$(send_at "$AT_PORT" 'AT+QCFG="usbcfg"' 3)
    ORIGINAL_USBCFG=$(echo "$resp" | grep '+QCFG:' | head -1)
    if [ -n "$ORIGINAL_USBCFG" ]; then
        log "  Current config: $ORIGINAL_USBCFG"
        log "  (Save this for rollback if needed)"
    else
        log "  WARNING: Could not read current USB config"
    fi
}

# ---------- step 3: unlock ADB ----------

unlock_adb() {
    log "Unlocking ADB on modem..."

    # Get the QADBKEY salt
    local resp
    resp=$(send_at "$AT_PORT" "AT+QADBKEY?" 3)
    if ! echo "$resp" | grep -q "OK"; then
        die "AT+QADBKEY? failed. Response: $resp"
    fi

    local salt
    salt=$(echo "$resp" | grep '+QADBKEY:' | sed 's/.*+QADBKEY: *//' | tr -d '\r\n' | cut -c1-8)
    if [ -z "$salt" ] || [ ${#salt} -lt 8 ]; then
        die "Could not extract 8-char salt from QADBKEY response: $resp"
    fi
    log "  Salt: $salt"

    # Compute MD5 crypt hash and extract chars 12-28
    local full_hash
    full_hash=$(openssl passwd -1 -salt "$salt" "SH_adb_quectel")
    # full_hash looks like: $1$SALT$<hash>
    # We need characters 12-28 (0-indexed) of the full hash string
    local unlock_key
    unlock_key=$(echo "$full_hash" | cut -c13-28)
    log "  Unlock key: $unlock_key"

    # Send unlock key
    resp=$(send_at "$AT_PORT" "AT+QADBKEY=\"$unlock_key\"" 3)
    if ! echo "$resp" | grep -q "OK"; then
        die "AT+QADBKEY unlock failed. Response: $resp"
    fi
    log "  ADB key accepted."

    # Enable ADB via USB config (EP06 PID 0x0306)
    resp=$(send_at "$AT_PORT" "AT+QCFG=\"usbcfg\",$EP06_VID,$EP06_PID,1,1,1,1,1,1,0" 3)
    if ! echo "$resp" | grep -q "OK"; then
        die "Failed to enable ADB. Response: $resp"
    fi
    log "  ADB enabled, waiting for USB re-enumeration..."
    sleep 5
}

# ---------- step 4: connect via ADB ----------

wait_for_adb() {
    log "Waiting for ADB device..."

    local retries=10
    while [ $retries -gt 0 ]; do
        if adb devices 2>/dev/null | grep -q "device$"; then
            log "  ADB device connected."
            return 0
        fi
        retries=$((retries - 1))
        sleep 2
    done

    die "ADB device did not appear. Check USB connection and try again."
}

# ---------- step 5: push files ----------

get_rayhunter_binary() {
    if [ -n "$RAYHUNTER_BINARY" ] && [ -f "$RAYHUNTER_BINARY" ]; then
        log "Using provided binary: $RAYHUNTER_BINARY"
        return 0
    fi

    log "Downloading rayhunter-daemon from GitHub releases..."
    RAYHUNTER_BINARY="/tmp/rayhunter-daemon"
    if command -v curl > /dev/null 2>&1; then
        curl -L -o "$RAYHUNTER_BINARY" "$RAYHUNTER_RELEASE_URL" || die "Download failed"
    elif command -v wget > /dev/null 2>&1; then
        wget -O "$RAYHUNTER_BINARY" "$RAYHUNTER_RELEASE_URL" || die "Download failed"
    else
        die "Neither curl nor wget available. Please provide the binary path as an argument."
    fi

    [ -s "$RAYHUNTER_BINARY" ] || die "Downloaded binary is empty"
    log "  Downloaded to $RAYHUNTER_BINARY"
}

generate_config() {
    log "Generating config.toml..."
    cat > /tmp/rayhunter-config.toml << 'CONFIGEOF'
qmdl_store_path = "/data/rayhunter/qmdl"
port = 8080
debug_mode = false
colorblind_mode = false
device = "ep06"
ui_level = 0
key_input_mode = 0
ntfy_url = ""
enabled_notifications = ["Warning"]

[analyzers]
imsi_requested = true
connection_redirect_2g_downgrade = true
lte_sib6_and_7_downgrade = true
null_cipher = true
nas_null_cipher = true
incomplete_sib = true
test_analyzer = false
CONFIGEOF
}

push_files() {
    log "Pushing files to modem..."

    adb shell "mount -o remount,rw /" || die "Failed to remount root filesystem"
    adb shell "mkdir -p /data/rayhunter" || die "Failed to create /data/rayhunter"

    # Push rayhunter binary
    log "  Pushing rayhunter-daemon..."
    adb push "$RAYHUNTER_BINARY" /data/rayhunter/rayhunter-daemon || die "Failed to push rayhunter-daemon"
    adb shell "chmod 755 /data/rayhunter/rayhunter-daemon"

    # Push config
    log "  Pushing config.toml..."
    adb push /tmp/rayhunter-config.toml /data/rayhunter/config.toml || die "Failed to push config.toml"

    # Push init scripts
    # Find the script directory (same dir as this script, or use bundled heredocs)
    local script_dir
    script_dir=$(dirname "$0")

    if [ -f "$script_dir/rayhunter_daemon" ]; then
        log "  Pushing rayhunter_daemon init script..."
        adb push "$script_dir/rayhunter_daemon" /etc/init.d/rayhunter_daemon
    else
        log "  Generating rayhunter_daemon init script..."
        cat > /tmp/rayhunter_daemon << 'INITEOF'
#! /bin/sh

set -e

case "$1" in
start)
    echo -n "Starting rayhunter: "
    #RAYHUNTER-PRESTART
    start-stop-daemon -S -b --make-pidfile --pidfile /tmp/rayhunter.pid \
    --startas /bin/sh -- -c "RUST_LOG=info exec /data/rayhunter/rayhunter-daemon /data/rayhunter/config.toml > /data/rayhunter/rayhunter.log 2>&1"
    echo "done"
    ;;
  stop)
    echo -n "Stopping rayhunter: "
    start-stop-daemon -K -p /tmp/rayhunter.pid
    echo "done"
    ;;
  restart)
    $0 stop
    $0 start
    ;;
  *)
    echo "Usage rayhunter_daemon { start | stop | restart }" >&2
    exit 1
    ;;
esac

exit 0
INITEOF
        adb push /tmp/rayhunter_daemon /etc/init.d/rayhunter_daemon
    fi

    if [ -f "$script_dir/misc-daemon" ]; then
        log "  Pushing misc-daemon init script..."
        adb push "$script_dir/misc-daemon" /etc/init.d/misc-daemon
    else
        log "  Generating misc-daemon init script..."
        cat > /tmp/misc-daemon << 'MISCEOF'
#!/bin/sh

set -e

case "$1" in
  start)
        echo -n "Starting miscellaneous daemons: "
        search_dir="/sys/bus/msm_subsys/devices/"
        for entry in `ls $search_dir`
        do
            subsys_temp=`cat $search_dir/$entry/name`
            if [ "$subsys_temp" == "modem" ]
            then
                break
            fi
        done
        counter=0
        while [ ${counter} -le 10 ]
        do
           msstate=`cat $search_dir/$entry/state`
           if [ "$msstate" == "ONLINE" ]
           then
              break
           fi
           counter=$(( $counter + 1 ))
           sleep 1
        done

        if [ -f /etc/init.d/init_qcom_audio ]
        then
           /etc/init.d/init_qcom_audio start
        fi

        if [ -f /sbin/reboot-daemon ]
        then
           /sbin/reboot-daemon &
        fi

        if [ -f /etc/init.d/start_atfwd_daemon ]
        then
           /etc/init.d/start_atfwd_daemon start
        fi

        if [ -f /etc/init.d/rayhunter_daemon ]
        then
           /etc/init.d/rayhunter_daemon start
        fi

        if [ -f /etc/init.d/start_stop_qti_ppp_le ]
        then
           /etc/init.d/start_stop_qti_ppp_le start
        fi

        if [ -f /etc/init.d/start_loc_launcher ]
        then
           /etc/init.d/start_loc_launcher start
        fi

        echo -n "Completed starting miscellaneous daemons"
        ;;
  stop)
        echo -n "Stopping miscellaneous daemons: "


        if [ -f /etc/init.d/start_atfwd_daemon ]
        then
           /etc/init.d/start_atfwd_daemon stop
        fi

        if [ -f /etc/init.d/start_loc_launcher ]
        then
           /etc/init.d/start_loc_launcher stop
        fi

        if [ -f /etc/init.d/rayhunter_daemon ]
        then
           /etc/init.d/rayhunter_daemon stop
        fi

        if [ -f /etc/init.d/init_qcom_audio ]
        then
            /etc/init.d/init_qcom_audio stop
        fi

        if [ -f /etc/init.d/start_stop_qti_ppp_le ]
        then
           /etc/init.d/start_stop_qti_ppp_le stop
        fi

        echo -n "Completed stopping miscellaneous daemons"
        ;;
  restart)
        $0 stop
        $0 start
        ;;
  *)
        echo "Usage misc-daemon { start | stop | restart}" >&2
        exit 1
        ;;
esac

exit 0
MISCEOF
        adb push /tmp/misc-daemon /etc/init.d/misc-daemon
    fi

    adb shell "chmod 755 /etc/init.d/rayhunter_daemon"
    adb shell "chmod 755 /etc/init.d/misc-daemon"

    log "  Files pushed successfully."
}

# ---------- step 6: reboot and verify ----------

reboot_and_verify() {
    log "Rebooting modem..."
    adb shell "shutdown -r -t 1 now" || true
    log "Waiting 30 seconds for modem to restart..."
    sleep 30

    # Need to re-detect AT port after reboot
    detect_at_port
    unlock_adb
    wait_for_adb

    log "Checking if rayhunter is running..."
    local status
    status=$(adb shell "ls /data/rayhunter/rayhunter.log 2>/dev/null && echo EXISTS" 2>/dev/null) || true
    if echo "$status" | grep -q "EXISTS"; then
        log "  Rayhunter log file exists - daemon appears to be running."
    else
        log "  WARNING: Rayhunter log file not found. Check installation."
    fi
}

# ---------- step 7: set up port forwarding ----------

setup_port_forward() {
    log "Setting up ADB port forward (tcp:8080 -> tcp:8080)..."
    adb forward tcp:8080 tcp:8080 || die "Failed to set up port forwarding"
    log "  Port forwarding active."
}

# ---------- step 8: install boot persistence ----------

install_boot_script() {
    local script_dir
    script_dir=$(dirname "$0")

    if [ -f "$script_dir/rayhunter-openwrt-boot" ]; then
        log "Installing OpenWrt boot persistence script..."
        cp "$script_dir/rayhunter-openwrt-boot" /etc/init.d/rayhunter-openwrt-boot
        chmod 755 /etc/init.d/rayhunter-openwrt-boot
        /etc/init.d/rayhunter-openwrt-boot enable
        log "  Boot script installed and enabled."
    else
        log "NOTE: rayhunter-openwrt-boot not found alongside this script."
        log "  ADB unlock and port forwarding will not persist across router reboots."
        log "  Copy rayhunter-openwrt-boot to /etc/init.d/ manually if needed."
    fi
}

# ---------- main ----------

main() {
    echo "============================================"
    echo "  Rayhunter Installer for GL-X750 (EP06)"
    echo "============================================"
    echo

    check_root
    check_prerequisites
    detect_at_port
    save_usb_config
    get_rayhunter_binary
    generate_config
    unlock_adb
    wait_for_adb
    push_files
    reboot_and_verify
    setup_port_forward
    install_boot_script

    echo
    echo "============================================"
    echo "  Installation complete!"
    echo "============================================"
    echo
    echo "Rayhunter is now running on your EP06 modem."
    echo "Access the web UI at: http://192.168.8.1:8080"
    echo
    echo "To view modem logs:"
    echo "  adb shell cat /data/rayhunter/rayhunter.log"
    echo
    if [ -n "$ORIGINAL_USBCFG" ]; then
        echo "To rollback USB config if needed:"
        echo "  Send via AT port: AT+QCFG=\"usbcfg\",<original values>"
        echo "  Original was: $ORIGINAL_USBCFG"
        echo
    fi
}

main "$@"
