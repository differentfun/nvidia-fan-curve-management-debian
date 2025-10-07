# Nvidia Fan Curve Management on Debian

This repository provides helper scripts for Debian systems with Nvidia GPUs. They enable CoolBits so the proprietary driver exposes manual fan controls and, if you want a fully automatic setup, install a custom NVML-based fan manager with both CLI and GUI front-ends. The author is not affiliated in any way with NVIDIA; use these tools at your own risk.

## What the setup scripts do
- Create or update `/etc/X11/xorg.conf.d/20-nvidia-coolbits.conf` with a configurable CoolBits mask (default `12`), keeping timestamped backups when a previous file exists.
- Optionally deploy a NVML-based fan control daemon (`nvidia_fan_manager.py`), a systemd service, and a Tk GUI so the curve can be edited quickly from the desktop and works identically on X11 and Wayland.

## Requirements
- Debian or derivative with the proprietary Nvidia driver already installed.
- Root privileges (run the script via `sudo`).
- X11 session (Wayland works through XWayland, but you still need the X11 config in place).

## Usage
```bash
sudo ./setup_nvidia_fan_control_Wayland_And_X11.sh
```
The script writes the CoolBits configuration, drops the NVML-based fan manager (CLI + GUI) and enables the accompanying systemd service. After it completes, restart your display manager or reboot so CoolBits are picked up. Use the “Nvidia Fancurve Manager” entry that appears in your applications menu (or run `pkexec /usr/local/bin/nvidia_fan_manager_gui.py`) to tweak curves, or operate everything via `/usr/local/bin/nvidia_fan_manager.py`.

## Wayland hosts

Nvidia exposes the NV-CONTROL extension only to Xorg, so X11 tools such as GreenWithEnvy stop working the moment you log into a Wayland session. The combined setup script therefore installs a standalone NVML-based daemon (`/usr/local/bin/nvidia_fan_manager.py`) together with `nvidia-fan-manager.service`, which works identically on Wayland and X11 by talking directly to the driver.

After running the combined setup you can tweak or test the daemon manually with:
```bash
sudo /usr/local/bin/nvidia_fan_manager.py --status
```

The daemon reads `/etc/nvidia-fan-manager/config.json`, where the curve is defined as comma-separated `temperature:speed` pairs (speed is a percentage). Each temperature acts as a threshold: the fan takes the speed of the highest entry whose temperature is ≤ the current GPU temperature. Fan speeds are clamped between 10 % and 100 %. The daemon uses NVML to keep the fan in manual mode while running and restores automatic control on shutdown.

### GUI editor

The installer also drops “Nvidia Fancurve Manager” into your applications menu (or run `/usr/local/bin/nvidia_fan_manager_gui.py`). The GUI lets you:
- Select the GPU/fan to manage from auto-detected dropdowns.
- Edit the temperature/speed curve visually.
- Save the configuration (the tool rewrites `/etc/nvidia-fan-manager/config.json`) and optionally signal the daemon with a HUP so changes take effect immediately. Poll interval and hysteresis are displayed for reference and can be changed via the CLI if needed.

When saving changes or reloading the service the GUI will prompt for your administrator password through Polkit (`pkexec`).

If you prefer the CLI, you can rewrite the config directly with:
```bash
sudo /usr/local/bin/nvidia_fan_manager.py \
    --profile 0:0 \
    --set-curve "40:35,55:50,70:75,82:100" \
    --set-poll-interval 2 \
    --set-hysteresis 3
sudo systemctl reload nvidia-fan-manager.service
```

## Multiple GPUs

The daemon can manage several GPU/fan pairs at the same time. Each entry in `/etc/nvidia-fan-manager/config.json` is a separate profile. Use the CLI to add or remove profiles:
```bash
# Add a second GPU/fan profile with the default curve
sudo /usr/local/bin/nvidia_fan_manager.py --add-profile 1:0

# Set a dedicated curve for GPU 1 / fan 0
sudo /usr/local/bin/nvidia_fan_manager.py --profile 1:0 --set-curve "35:30,55:55,75:80,85:100"

# List everything currently configured
sudo /usr/local/bin/nvidia_fan_manager.py --list-profiles
```
The daemon and GUI automatically pick up all configured profiles; no further action is required to keep them in sync.

## Uninstall

To roll everything back (CoolBits config plus the fan manager assets):
```bash
sudo ./uninstall_nvidia_fan_control.sh
```
Use `--keep-coolbits` or `--keep-fan-daemon` if you only want to remove part of the setup.

## Script options (`setup_nvidia_fan_control_Wayland_And_X11.sh`)
- `--coolbits <value>`: override the CoolBits mask (default `12`).
- `--skip-apt-update`: do not run `apt-get update` before installing dependencies.
- `--skip-fan-daemon`: configure CoolBits only, skip the NVML fan manager deployment.
- `--fan-curve <temp:speed,...>`: override the curve used to seed `/etc/nvidia-fan-manager/config.json`.
- `--fan-interval <seconds>`: polling cadence for the daemon.
- `--fan-hysteresis <value>`: minimum fan-speed delta (in %) required before a new setting is applied (values below `0.5` are bumped to `0.5`).
- `--fan-gpu <index>` / `--fan-index <index>`: choose which GPU/fan is driven when multiple are exposed.
- `--help`: show usage info.

## Fan manager CLI options (`/usr/local/bin/nvidia_fan_manager.py`)
- `--profile <gpu:fan>`: select which GPU/fan pair subsequent actions should target (defaults to the first profile in the config).
- `--add-profile <gpu:fan>` / `--remove-profile <gpu:fan>`: create or delete profiles without touching the JSON manually.
- `--list-profiles`: dump the current configuration and exit.
- `--set-curve <temp:speed,...>`: assign a new curve to the selected profile.
- `--set-hysteresis <value>`: adjust the minimum fan-speed delta before a new setting is applied for the selected profile.
- `--set-poll-interval <seconds>`: change the global polling cadence.
- `--status`: print temperature/actual/target speed for the selected profile (or all profiles if none specified).
- `--restore-auto`: hand control back to the driver for the selected profile (or all profiles).
- `--once`: apply the configured curves once and exit (useful after editing the config manually).
- `--daemon`: keep running in the background and continuously enforce all profiles.

## Verification steps
1. Run `nvidia-smi --query-gpu=temperature.gpu,fan.speed --format=csv` to confirm the driver reports temperatures and fan speed.
2. Check `systemctl status nvidia-fan-manager.service` to ensure the daemon is active and watch logs with `journalctl -u nvidia-fan-manager.service -f`.
3. Use the GUI or CLI to apply a custom curve, stress the GPU, and confirm the fan responds as expected.
