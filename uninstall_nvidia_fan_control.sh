#!/usr/bin/env bash
set -euo pipefail

COOLBITS_CONFIG="/etc/X11/xorg.conf.d/20-nvidia-coolbits.conf"
FAN_SERVICE_NAME="nvidia-fan-manager.service"
FAN_SERVICE_PATH="/etc/systemd/system/${FAN_SERVICE_NAME}"
FAN_DAEMON_PATH="/usr/local/bin/nvidia_fan_manager.py"
FAN_GUI_PATH="/usr/local/bin/nvidia_fan_manager_gui.py"
FAN_CONFIG_PATH="/etc/nvidia-fan-manager/config.json"
FAN_DESKTOP_PATH="/usr/share/applications/nvidia-fancurve-manager.desktop"

REMOVE_COOLBITS=1
REMOVE_FAN_MANAGER=1

usage() {
    cat <<USAGE
Usage: $0 [options]

Options:
  --keep-coolbits          Leave /etc/X11/xorg.conf.d/20-nvidia-coolbits.conf in place.
  --keep-fan-daemon        Do not remove the fan manager binaries/service/desktop entry.
  --help                   Show this help message.

The script must be run as root (use sudo).
USAGE
}

error_exit() {
    echo "Error: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-coolbits)
            REMOVE_COOLBITS=0
            shift
            ;;
        --keep-fan-daemon)
            REMOVE_FAN_MANAGER=0
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

if [[ $EUID -ne 0 ]]; then
    error_exit "This script must be run as root (use sudo)."
fi

remove_coolbits_config() {
    if (( ! REMOVE_COOLBITS )); then
        echo "Skipping removal of CoolBits configuration."
        return
    fi

    if [[ -f "$COOLBITS_CONFIG" ]]; then
        rm -f "$COOLBITS_CONFIG"
        echo "Removed $COOLBITS_CONFIG"
    else
        echo "CoolBits configuration not present, nothing to remove."
    fi

    shopt -s nullglob
    local backups=("${COOLBITS_CONFIG}".*.bak)
    shopt -u nullglob
    if (( ${#backups[@]} )); then
        rm -f "${backups[@]}"
        echo "Removed CoolBits backup files."
    fi
}

remove_fan_manager() {
    if (( ! REMOVE_FAN_MANAGER )); then
        echo "Skipping removal of fan manager daemon."
        return
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-unit-files --no-legend | awk '{print $1}' | grep -Fxq "$FAN_SERVICE_NAME"; then
            systemctl stop "$FAN_SERVICE_NAME" >/dev/null 2>&1 || true
            systemctl disable "$FAN_SERVICE_NAME" >/dev/null 2>&1 || true
            echo "Stopped and disabled $FAN_SERVICE_NAME."
        fi
    else
        echo "systemctl not available; skipping service disable."
    fi

    if [[ -f "$FAN_SERVICE_PATH" ]]; then
        rm -f "$FAN_SERVICE_PATH"
        echo "Removed $FAN_SERVICE_PATH"
    fi

    if [[ -f "$FAN_DAEMON_PATH" ]]; then
        rm -f "$FAN_DAEMON_PATH"
        echo "Removed $FAN_DAEMON_PATH"
    fi

    if [[ -f "$FAN_GUI_PATH" ]]; then
        rm -f "$FAN_GUI_PATH"
        echo "Removed $FAN_GUI_PATH"
    fi

    if [[ -f "$FAN_CONFIG_PATH" ]]; then
        rm -f "$FAN_CONFIG_PATH"
        echo "Removed $FAN_CONFIG_PATH"
    fi

    if [[ -f "$FAN_DESKTOP_PATH" ]]; then
        rm -f "$FAN_DESKTOP_PATH"
        echo "Removed $FAN_DESKTOP_PATH"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
    fi
}

main() {
    remove_coolbits_config
    remove_fan_manager

    echo
    echo "Uninstall routine completed."
    if (( REMOVE_COOLBITS )); then
        echo "- CoolBits configuration removed. X11 will revert to defaults after reboot."
    fi
    if (( REMOVE_FAN_MANAGER )); then
        echo "- Fan manager daemon and assets removed."
    fi
}

main
