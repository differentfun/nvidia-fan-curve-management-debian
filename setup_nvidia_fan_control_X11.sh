#!/usr/bin/env bash
set -euo pipefail

COOLBITS_VALUE=12
INSTALL_GWE=1
RUN_APT_UPDATE=1
FLATPAK_USER_OVERRIDE=""
FLATPAK_SCOPE="system"

usage() {
    cat <<USAGE
Usage: $0 [options]

Options:
  --coolbits <value>       Set CoolBits capability mask (default: 12)
  --skip-gwe               Skip installing GreenWithEnvy
  --skip-apt-update        Do not run apt-get update automatically
  --flatpak-scope <scope>  Install GWE for 'system' (default) or 'user'
  --flatpak-user <user>    When using user scope, target this account
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
        --skip-gwe)
            INSTALL_GWE=0
            shift
            ;;
        --skip-apt-update)
            RUN_APT_UPDATE=0
            shift
            ;;
        --flatpak-scope)
            [[ $# -ge 2 ]] || { echo "Missing value for --flatpak-scope" >&2; exit 1; }
            case "$2" in
                system|user)
                    FLATPAK_SCOPE="$2"
                    ;;
                *)
                    echo "Invalid value for --flatpak-scope: $2 (expected 'system' or 'user')" >&2
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        --flatpak-user)
            [[ $# -ge 2 ]] || { echo "Missing value for --flatpak-user" >&2; exit 1; }
            FLATPAK_USER_OVERRIDE="$2"
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

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)." >&2
    exit 1
fi

TARGET_USER=""
RUN_FLATPAK_AS_ROOT=1

if [[ "$FLATPAK_SCOPE" == "system" && -n "$FLATPAK_USER_OVERRIDE" ]]; then
    echo "--flatpak-user is only valid with --flatpak-scope user." >&2
    exit 1
fi

if [[ "$FLATPAK_SCOPE" == "user" ]]; then
    RUN_FLATPAK_AS_ROOT=0
    if [[ -n "$FLATPAK_USER_OVERRIDE" ]]; then
        TARGET_USER="$FLATPAK_USER_OVERRIDE"
    elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        TARGET_USER="$SUDO_USER"
    else
        echo "User scope selected but no non-root user detected. Use --flatpak-user <name>." >&2
        exit 1
    fi
    if ! id "$TARGET_USER" >/dev/null 2>&1; then
        echo "User $TARGET_USER not found." >&2
        exit 1
    fi
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

install_flatpak() {
    if command -v flatpak >/dev/null 2>&1; then
        return
    fi
    echo "Installing flatpak..."
    if (( RUN_APT_UPDATE )); then
        autoupdate_apt
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y flatpak
}

ensure_flatpak_session_support() {
    if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        return
    fi

    if command -v dbus-run-session >/dev/null 2>&1; then
        return
    fi

    if command -v dbus-launch >/dev/null 2>&1; then
        return
    fi

    echo "Installing dbus-x11 to provide session bus helpers for Flatpak..."
    if (( RUN_APT_UPDATE )); then
        autoupdate_apt
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends dbus-x11
}

warn_if_wayland_session() {
    local session_user session_id session_type

    if [[ -n "$TARGET_USER" ]]; then
        session_user="$TARGET_USER"
    elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        session_user="$SUDO_USER"
    else
        session_user=""
    fi

    if [[ -z "$session_user" ]]; then
        return
    fi

    if ! command -v loginctl >/dev/null 2>&1; then
        return
    fi

    session_id=$(loginctl list-sessions --no-legend 2>/dev/null | awk -v user="$session_user" '$3==user {print $1; exit}')
    if [[ -z "$session_id" ]]; then
        return
    fi

    session_type=$(loginctl show-session "$session_id" -p Type --value 2>/dev/null || true)
    if [[ "$session_type" == "wayland" ]]; then
        cat <<WARN
Warning: Detected active Wayland session for user ${session_user}. The NV-CONTROL X extension is unavailable on Wayland, so GreenWithEnvy cannot control the GPU. Log into an X11 session (e.g. "GNOME on Xorg") or disable Wayland, then rerun the script.
WARN
    fi
}

run_flatpak() {
    if (( RUN_FLATPAK_AS_ROOT )); then
        ensure_flatpak_session_support
        if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
            flatpak "$@"
        elif command -v dbus-run-session >/dev/null 2>&1; then
            dbus-run-session -- flatpak "$@"
        else
            flatpak "$@"
        fi
    else
        ensure_flatpak_session_support
        if command -v dbus-run-session >/dev/null 2>&1; then
            runuser -u "$TARGET_USER" -- dbus-run-session -- flatpak "$@"
        else
            runuser -u "$TARGET_USER" -- flatpak "$@"
        fi
    fi
}

install_gwe() {
    install_flatpak

    local scope
    if (( RUN_FLATPAK_AS_ROOT )); then
        scope="--system"
    else
        scope="--user"
    fi

    if ! run_flatpak remote-list "$scope" --columns=name | grep -Fxq "flathub"; then
        echo "Adding Flathub remote for $([[ $scope == "--system" ]] && echo "system" || echo "user") installation..."
        run_flatpak remote-add "$scope" --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    fi

    if run_flatpak info "$scope" com.leinardi.gwe >/dev/null 2>&1; then
        echo "Removing existing GreenWithEnvy installation..."
        run_flatpak uninstall "$scope" --delete-data --noninteractive -y com.leinardi.gwe
    fi

    echo "Installing GreenWithEnvy via Flatpak..."
    run_flatpak install "$scope" --noninteractive -y flathub com.leinardi.gwe
}

warn_if_wayland_session

if (( INSTALL_GWE )); then
    install_gwe
else
    echo "Skipped GreenWithEnvy installation." >&2
fi

echo
echo "Setup complete."
echo "Restart your display manager or reboot to apply CoolBits."
echo "Launch GreenWithEnvy from your app menu or with: flatpak run com.leinardi.gwe"
