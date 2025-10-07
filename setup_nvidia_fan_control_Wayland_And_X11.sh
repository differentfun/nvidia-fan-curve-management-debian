#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

COOLBITS_VALUE=12
RUN_APT_UPDATE=1
INSTALL_FAN_MANAGER=1
FAN_GPU_INDEX=0
FAN_FAN_INDEX=0
FAN_CURVE="30:25,40:35,50:45,60:60,70:75,80:90"
FAN_POLL_INTERVAL=2
FAN_HYSTERESIS=2
FAN_MANAGER_INSTALL_PATH="/usr/local/bin/nvidia_fan_manager.py"
FAN_MANAGER_GUI_INSTALL_PATH="/usr/local/bin/nvidia_fan_manager_gui.py"
FAN_MANAGER_CONFIG_PATH="/etc/nvidia-fan-manager/config.json"
FAN_MANAGER_SERVICE_PATH="/etc/systemd/system/nvidia-fan-manager.service"
FAN_MANAGER_SERVICE_NAME="nvidia-fan-manager.service"
FAN_MANAGER_DESKTOP_PATH="/usr/share/applications/nvidia-fancurve-manager.desktop"

usage() {
    cat <<USAGE
Usage: $0 [options]

Options:
  --coolbits <value>       Set CoolBits capability mask (default: 12)
  --skip-apt-update        Do not run apt-get update automatically
  --skip-fan-daemon        Skip installing the NVML-based fan control daemon
  --fan-gpu <index>        GPU index to manage (default: 0)
  --fan-index <index>      Fan index on the GPU (default: 0)
  --fan-curve <pairs>      Temp:speed pairs for the fan curve
  --fan-interval <s>       Poll interval seconds for the daemon (default: 2)
  --fan-hysteresis <°C>    Temperature hysteresis before changing speed (default: 2)
  --help                   Show this help message
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --coolbits)
            [[ $# -ge 2 ]] || { echo "Missing value for --coolbits" >&2; exit 1; }
            COOLBITS_VALUE="$2"
            shift 2
            ;;
        --skip-apt-update)
            RUN_APT_UPDATE=0
            shift
            ;;
        --skip-fan-daemon)
            INSTALL_FAN_MANAGER=0
            shift
            ;;
        --fan-gpu)
            [[ $# -ge 2 ]] || { echo "Missing value for --fan-gpu" >&2; exit 1; }
            FAN_GPU_INDEX="$2"
            shift 2
            ;;
        --fan-index)
            [[ $# -ge 2 ]] || { echo "Missing value for --fan-index" >&2; exit 1; }
            FAN_FAN_INDEX="$2"
            shift 2
            ;;
        --fan-curve)
            [[ $# -ge 2 ]] || { echo "Missing value for --fan-curve" >&2; exit 1; }
            FAN_CURVE="$2"
            shift 2
            ;;
        --fan-interval)
            [[ $# -ge 2 ]] || { echo "Missing value for --fan-interval" >&2; exit 1; }
            FAN_POLL_INTERVAL="$2"
            shift 2
            ;;
        --fan-hysteresis)
            [[ $# -ge 2 ]] || { echo "Missing value for --fan-hysteresis" >&2; exit 1; }
            FAN_HYSTERESIS="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ ! "$COOLBITS_VALUE" =~ ^[0-9]+$ ]]; then
    echo "CoolBits value must be an integer." >&2
    exit 1
fi

if [[ ! "$FAN_GPU_INDEX" =~ ^[0-9]+$ ]]; then
    echo "Fan GPU index must be an integer." >&2
    exit 1
fi

if [[ ! "$FAN_FAN_INDEX" =~ ^[0-9]+$ ]]; then
    echo "Fan index must be an integer." >&2
    exit 1
fi

if [[ ! "$FAN_POLL_INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "Fan poll interval must be numeric (seconds)." >&2
    exit 1
fi

if [[ ! "$FAN_HYSTERESIS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "Fan hysteresis must be numeric (°C)." >&2
    exit 1
fi

FAN_CURVE="${FAN_CURVE//[[:space:]]/}"
if [[ -z "$FAN_CURVE" ]]; then
    echo "Fan curve must not be empty." >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)." >&2
    exit 1
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "Warning: nvidia-smi not found. Ensure the proprietary Nvidia driver is installed." >&2
fi

CONFIG_DIR="/etc/X11/xorg.conf.d"
CONFIG_FILE="${CONFIG_DIR}/20-nvidia-coolbits.conf"
BACKUP_SUFFIX="$(date +%Y%m%d%H%M%S)"

mkdir -p "$CONFIG_DIR"

cleanup_previous_config() {
    shopt -s nullglob
    local backup
    local old_backups=( "${CONFIG_FILE}".*.bak )
    shopt -u nullglob

    if (( ${#old_backups[@]} )); then
        rm -f "${old_backups[@]}"
        echo "Removed previous CoolBits backups."
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        backup="${CONFIG_FILE}.${BACKUP_SUFFIX}.bak"
        mv "$CONFIG_FILE" "$backup"
        echo "Existing CoolBits config moved to ${backup}"
    fi
}

cleanup_previous_config

cat >"$CONFIG_FILE" <<CFG
Section "Device"
    Identifier "Nvidia Card"
    Driver "nvidia"
    Option "CoolBits" "${COOLBITS_VALUE}"
    Option "AllowEmptyInitialConfiguration" "true"
EndSection
CFG

chmod 644 "$CONFIG_FILE"
echo "CoolBits configuration written to $CONFIG_FILE"

autoupdate_apt() {
    echo "Running apt-get update..."
    apt-get update
}

install_fan_manager() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 not found. Installing..."
        if (( RUN_APT_UPDATE )); then
            autoupdate_apt
        fi
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "systemctl not available; cannot configure fan manager service." >&2
        exit 1
    fi

    local source_path="${SCRIPT_DIR}/nvidia_fan_manager.py"
    local gui_source="${SCRIPT_DIR}/nvidia_fan_manager_gui.py"
    if [[ ! -f "$source_path" ]]; then
        echo "nvidia_fan_manager.py not found next to the setup script." >&2
        exit 1
    fi
    if [[ ! -f "$gui_source" ]]; then
        echo "nvidia_fan_manager_gui.py not found next to the setup script." >&2
        exit 1
    fi

    install -Dm755 "$source_path" "$FAN_MANAGER_INSTALL_PATH"
    install -Dm755 "$gui_source" "$FAN_MANAGER_GUI_INSTALL_PATH"
    mkdir -p "$(dirname "$FAN_MANAGER_CONFIG_PATH")"

    python3 "$FAN_MANAGER_INSTALL_PATH" \
        --config "$FAN_MANAGER_CONFIG_PATH" \
        --profile "${FAN_GPU_INDEX}:${FAN_FAN_INDEX}" \
        --set-curve "$FAN_CURVE" \
        --set-poll-interval "$FAN_POLL_INTERVAL" \
        --set-hysteresis "$FAN_HYSTERESIS"

    cat >"$FAN_MANAGER_SERVICE_PATH" <<UNIT
[Unit]
Description=Nvidia Fan Manager
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $FAN_MANAGER_INSTALL_PATH --daemon
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    chmod 644 "$FAN_MANAGER_SERVICE_PATH"

    systemctl daemon-reload
    systemctl enable "$FAN_MANAGER_SERVICE_NAME"
    systemctl restart "$FAN_MANAGER_SERVICE_NAME"
    echo "NVML-based fan manager installed and active (service: ${FAN_MANAGER_SERVICE_NAME})."

    cat >"$FAN_MANAGER_DESKTOP_PATH" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Nvidia Fancurve Manager
Comment=Configure custom Nvidia fan curves
Exec=$FAN_MANAGER_GUI_INSTALL_PATH
Icon=preferences-system
Categories=Settings;System;
Terminal=false
DESKTOP
    chmod 644 "$FAN_MANAGER_DESKTOP_PATH"

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
    fi
}
if (( INSTALL_FAN_MANAGER )); then
    install_fan_manager
else
    echo "Skipped NVML fan manager installation." >&2
fi

echo
echo "Setup complete."
echo "Restart your display manager or reboot to apply CoolBits."
echo "Use the Nvidia Fancurve Manager app (or /usr/local/bin/nvidia_fan_manager.py) to adjust the curve."
