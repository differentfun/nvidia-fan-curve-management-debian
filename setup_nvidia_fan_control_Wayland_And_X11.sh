#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

COOLBITS_VALUE=12
INSTALL_GWE=1
RUN_APT_UPDATE=1
FLATPAK_USER_OVERRIDE=""
FLATPAK_SCOPE="system"
INSTALL_WAYLAND_SERVICE=1
WAYLAND_DISPLAY=":99"
WAYLAND_GPU_INDEX=0
WAYLAND_FAN_INDEX=0
WAYLAND_POLL_INTERVAL=3
WAYLAND_CURVE="40:30,50:40,60:55,70:70,80:85,85:100"
WAYLAND_RESTORE_AUTO=1
WAYLAND_KEEP_XORG=0
WAYLAND_INSTALL_PATH="/usr/local/bin/nvidia_wayland_fan_daemon.sh"
WAYLAND_SERVICE_PATH="/etc/systemd/system/nvidia-wayland-fan.service"
WAYLAND_SERVICE_NAME="nvidia-wayland-fan.service"

usage() {
    cat <<USAGE
Usage: $0 [options]

Options:
  --coolbits <value>       Set CoolBits capability mask (default: 12)
  --skip-gwe               Skip installing GreenWithEnvy
  --skip-apt-update        Do not run apt-get update automatically
  --flatpak-scope <scope>  Install GWE for 'system' (default) or 'user'
  --flatpak-user <user>    When using user scope, target this account
  --skip-wayland-daemon    Skip installing the Wayland fan control daemon
  --wayland-display <id>   X display id for the shim (default: :99)
  --wayland-gpu <index>    GPU index for the shim (default: 0)
  --wayland-fan <index>    Fan index controlled by the shim (default: 0)
  --wayland-curve <pairs>  Temp:speed pairs for the shim fan curve
  --wayland-interval <s>   Poll interval seconds for the shim (default: 3)
  --wayland-no-auto        Do not restore automatic fan control on stop
  --wayland-keep-xorg      Leave shim-managed Xorg running on stop
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
        --skip-wayland-daemon)
            INSTALL_WAYLAND_SERVICE=0
            shift
            ;;
        --wayland-display)
            [[ $# -ge 2 ]] || { echo "Missing value for --wayland-display" >&2; exit 1; }
            WAYLAND_DISPLAY="$2"
            shift 2
            ;;
        --wayland-gpu)
            [[ $# -ge 2 ]] || { echo "Missing value for --wayland-gpu" >&2; exit 1; }
            WAYLAND_GPU_INDEX="$2"
            shift 2
            ;;
        --wayland-fan)
            [[ $# -ge 2 ]] || { echo "Missing value for --wayland-fan" >&2; exit 1; }
            WAYLAND_FAN_INDEX="$2"
            shift 2
            ;;
        --wayland-curve)
            [[ $# -ge 2 ]] || { echo "Missing value for --wayland-curve" >&2; exit 1; }
            WAYLAND_CURVE="$2"
            shift 2
            ;;
        --wayland-interval)
            [[ $# -ge 2 ]] || { echo "Missing value for --wayland-interval" >&2; exit 1; }
            WAYLAND_POLL_INTERVAL="$2"
            shift 2
            ;;
        --wayland-no-auto)
            WAYLAND_RESTORE_AUTO=0
            shift
            ;;
        --wayland-keep-xorg)
            WAYLAND_KEEP_XORG=1
            shift
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

if [[ ! "$WAYLAND_GPU_INDEX" =~ ^[0-9]+$ ]]; then
    echo "Wayland GPU index must be an integer." >&2
    exit 1
fi

if [[ ! "$WAYLAND_FAN_INDEX" =~ ^[0-9]+$ ]]; then
    echo "Wayland fan index must be an integer." >&2
    exit 1
fi

if [[ ! "$WAYLAND_POLL_INTERVAL" =~ ^[0-9]+$ ]]; then
    echo "Wayland poll interval must be an integer (seconds)." >&2
    exit 1
fi

if [[ ! "$WAYLAND_DISPLAY" =~ ^:[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Wayland display must match :<number>[.<screen>]." >&2
    exit 1
fi

WAYLAND_CURVE="${WAYLAND_CURVE//[[:space:]]/}"
if [[ -z "$WAYLAND_CURVE" ]]; then
    echo "Wayland fan curve must not be empty." >&2
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

ensure_wayland_requirements() {
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "systemctl not found. Cannot configure Wayland daemon automatically." >&2
        exit 1
    fi

    local packages=()
    if ! command -v Xorg >/dev/null 2>&1; then
        packages+=(xserver-xorg-core)
    fi
    if ! command -v nvidia-settings >/dev/null 2>&1; then
        packages+=(nvidia-settings)
    fi
    if (( ${#packages[@]} )); then
        echo "Installing required packages for Wayland daemon: ${packages[*]}"
        if (( RUN_APT_UPDATE )); then
            autoupdate_apt
        fi
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
    fi
}

write_wayland_daemon_script() {
    local source_path="${SCRIPT_DIR}/nvidia_wayland_fan_daemon.sh"
    local target_dir

    target_dir="$(dirname "$WAYLAND_INSTALL_PATH")"
    mkdir -p "$target_dir"

    if [[ -f "$source_path" ]]; then
        install -m 755 "$source_path" "$WAYLAND_INSTALL_PATH"
    else
        cat <<'DAEMON' >"$WAYLAND_INSTALL_PATH"
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
DAEMON
        chmod 755 "$WAYLAND_INSTALL_PATH"
    fi
}

create_wayland_service_unit() {
    local exec_start="$WAYLAND_INSTALL_PATH"
    exec_start+=" --display=${WAYLAND_DISPLAY}"
    exec_start+=" --gpu=${WAYLAND_GPU_INDEX}"
    exec_start+=" --fan=${WAYLAND_FAN_INDEX}"
    exec_start+=" --interval=${WAYLAND_POLL_INTERVAL}"
    exec_start+=" --curve=${WAYLAND_CURVE}"
    if (( WAYLAND_RESTORE_AUTO == 0 )); then
        exec_start+=" --no-auto-restore"
    fi
    if (( WAYLAND_KEEP_XORG )); then
        exec_start+=" --keep-xorg"
    fi

    cat >"$WAYLAND_SERVICE_PATH" <<UNIT
[Unit]
Description=Nvidia fan curve shim for Wayland sessions
After=multi-user.target

[Service]
Type=simple
ExecStart=${exec_start}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    chmod 644 "$WAYLAND_SERVICE_PATH"
}

install_wayland_service() {
    ensure_wayland_requirements
    write_wayland_daemon_script
    create_wayland_service_unit

    systemctl daemon-reload
    systemctl enable "$WAYLAND_SERVICE_NAME"
    systemctl restart "$WAYLAND_SERVICE_NAME"
    echo "Wayland fan control daemon installed and active (service: ${WAYLAND_SERVICE_NAME})."
}

if (( INSTALL_GWE )); then
    install_gwe
else
    echo "Skipped GreenWithEnvy installation." >&2
fi

if (( INSTALL_WAYLAND_SERVICE )); then
    install_wayland_service
else
    echo "Skipped Wayland fan control daemon installation." >&2
fi

echo
echo "Setup complete."
echo "Restart your display manager or reboot to apply CoolBits."
echo "Launch GreenWithEnvy from your app menu or with: flatpak run com.leinardi.gwe"
