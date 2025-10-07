#!/usr/bin/env bash
set -euo pipefail

# Default configuration
DISPLAY=":99"
GPU_INDEX=0
FAN_INDEX=0
POLL_INTERVAL=3
FAN_CURVE="40:30,50:40,60:55,70:70,80:85,85:100"
RESTORE_AUTO=1
STOP_XORG_ON_EXIT=1

XORG_PID=""
SOCKET_PATH=""
XAUTHORITY_FILE=""
CURRENT_SPEED=""
STARTED_XORG=0
declare -a CURVE_TEMPS=()
declare -a CURVE_SPEEDS=()

usage() {
    cat <<'USAGE'
Usage: nvidia_wayland_fan_daemon.sh [options]

Options:
  --display <id>       X display to use for headless Xorg (default: :99)
  --gpu <index>        Target GPU index for fan control (default: 0)
  --fan <index>        Target fan index on the GPU (default: 0)
  --curve <pairs>      Comma-separated temp:speed pairs (default: 40:30,50:40,60:55,70:70,80:85,85:100)
  --interval <sec>     Polling interval in seconds (default: 3)
  --no-auto-restore    Do not restore automatic fan control on exit
  --keep-xorg          Do not stop the Xorg instance on exit (reuse existing display)
  --help               Show this help message

Example:
  sudo ./nvidia_wayland_fan_daemon.sh \
       --curve "35:25,50:45,65:65,75:80,82:100"
USAGE
}

error_exit() {
    echo "Error: $*" >&2
    exit 1
}

parse_curve() {
    local input="$1"
    local pair
    local last_temp=-1
    IFS=',' read -ra pairs <<<"$input"
    [[ ${#pairs[@]} -gt 0 ]] || error_exit "Fan curve must contain at least one temp:speed pair."

    CURVE_TEMPS=()
    CURVE_SPEEDS=()

    for pair in "${pairs[@]}"; do
        if [[ ! $pair =~ ^([0-9]+):([0-9]+)$ ]]; then
            error_exit "Invalid fan curve entry: $pair (expected temp:speed)."
        fi
        local temp="${BASH_REMATCH[1]}"
        local speed="${BASH_REMATCH[2]}"

        (( temp > last_temp )) || error_exit "Fan curve temperatures must be strictly increasing."
        (( speed >= 0 && speed <= 100 )) || error_exit "Fan speed $speed out of range (0-100)."

        CURVE_TEMPS+=("$temp")
        CURVE_SPEEDS+=("$speed")
        last_temp="$temp"
    done
}

start_headless_xorg() {
    SOCKET_PATH="/tmp/.X11-unix/X${DISPLAY#:}"

    if [[ -S "$SOCKET_PATH" ]]; then
        STARTED_XORG=0
        return
    fi

    STARTED_XORG=1
    local log_file="/var/log/nvidia-headless-${DISPLAY#:}.log"

    mkdir -p /tmp/.X11-unix

    XAUTHORITY_FILE="/root/.nvidia-wayland-fan.Xauthority"
    export XAUTHORITY="$XAUTHORITY_FILE"
    rm -f "$XAUTHORITY_FILE"

    # Launch minimal Xorg so NV-CONTROL is available even on Wayland.
    Xorg "$DISPLAY" \
        -configdir /etc/X11/xorg.conf.d \
        -noreset \
        -nolisten tcp \
        -logfile "$log_file" \
        -dpi 96 \
        >/dev/null 2>&1 &

    XORG_PID=$!

    for _ in {1..20}; do
        if ! kill -0 "$XORG_PID" 2>/dev/null; then
            error_exit "Xorg failed to start. Check $log_file for details."
        fi
        if [[ -S "$SOCKET_PATH" && -f "$XAUTHORITY_FILE" ]]; then
            return
        fi
        sleep 0.5
    done

    error_exit "Timed out waiting for Xorg on $DISPLAY (see $log_file)."
}

stop_headless_xorg() {
    if (( STARTED_XORG )) && (( STOP_XORG_ON_EXIT )) && [[ -n "$XORG_PID" ]]; then
        if kill -0 "$XORG_PID" 2>/dev/null; then
            kill "$XORG_PID"
            wait "$XORG_PID" 2>/dev/null || true
        fi
        rm -f "$XAUTHORITY_FILE"
    fi
}

restore_auto_mode() {
    if (( RESTORE_AUTO )); then
        nvidia-settings -c "$DISPLAY" \
            -a "[gpu:${GPU_INDEX}]/GPUFanControlState=0" \
            >/dev/null 2>&1 || true
    fi
}

cleanup() {
    restore_auto_mode
    stop_headless_xorg
}

ensure_dependencies() {
    command -v nvidia-settings >/dev/null 2>&1 \
        || error_exit "nvidia-settings not found. Install the proprietary driver utilities."
    command -v nvidia-smi >/dev/null 2>&1 \
        || error_exit "nvidia-smi not found. Install the proprietary driver utilities."
    command -v Xorg >/dev/null 2>&1 \
        || error_exit "Xorg not found. Install xserver-xorg."
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This daemon must be run as root so it can spawn a headless Xorg instance."
    fi
}

set_manual_mode() {
    nvidia-settings -c "$DISPLAY" \
        -a "[gpu:${GPU_INDEX}]/GPUFanControlState=1" \
        >/dev/null
}

get_temperature() {
    local temp
    temp=$(nvidia-smi \
        --query-gpu=temperature.gpu \
        --format=csv,noheader,nounits \
        | sed -n "$((GPU_INDEX + 1))p")

    if [[ -z "$temp" ]]; then
        error_exit "Unable to read temperature for GPU index ${GPU_INDEX}."
    fi
    echo "$temp"
}

select_speed() {
    local temp="$1"
    local chosen="${CURVE_SPEEDS[0]}"
    local idx
    for idx in "${!CURVE_TEMPS[@]}"; do
        if (( temp >= CURVE_TEMPS[idx] )); then
            chosen="${CURVE_SPEEDS[idx]}"
        else
            break
        fi
    done
    echo "$chosen"
}

apply_speed() {
    local speed="$1"
    if [[ "$speed" == "$CURRENT_SPEED" ]]; then
        return
    fi

    nvidia-settings -c "$DISPLAY" \
        -a "[fan:${FAN_INDEX}]/GPUTargetFanSpeed=${speed}" \
        >/dev/null
    CURRENT_SPEED="$speed"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --display)
                [[ $# -ge 2 ]] || error_exit "Missing value for --display."
                DISPLAY="$2"
                shift 2
                ;;
            --gpu)
                [[ $# -ge 2 ]] || error_exit "Missing value for --gpu."
                GPU_INDEX="$2"
                shift 2
                ;;
            --fan)
                [[ $# -ge 2 ]] || error_exit "Missing value for --fan."
                FAN_INDEX="$2"
                shift 2
                ;;
            --curve)
                [[ $# -ge 2 ]] || error_exit "Missing value for --curve."
                FAN_CURVE="$2"
                shift 2
                ;;
            --interval)
                [[ $# -ge 2 ]] || error_exit "Missing value for --interval."
                POLL_INTERVAL="$2"
                shift 2
                ;;
            --no-auto-restore)
                RESTORE_AUTO=0
                shift
                ;;
            --keep-xorg)
                STOP_XORG_ON_EXIT=0
                shift
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                usage
                error_exit "Unknown option: $1"
                ;;
        esac
    done
}

main() {
    parse_args "$@"
    parse_curve "$FAN_CURVE"
    require_root
    ensure_dependencies

    trap cleanup EXIT INT TERM

    start_headless_xorg
    export DISPLAY
    export XAUTHORITY="${XAUTHORITY:-/root/.Xauthority}"

    set_manual_mode

    while true; do
        local temp speed
        temp=$(get_temperature)
        speed=$(select_speed "$temp")
        apply_speed "$speed"
        sleep "$POLL_INTERVAL"
    done
}

main "$@"
