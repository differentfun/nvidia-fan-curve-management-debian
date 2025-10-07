# Nvidia Fan Curve Management on Debian

This repository provides a helper script for Debian systems with Nvidia GPUs. It enables CoolBits so the proprietary driver exposes manual fan controls, and it prepares the GUI tool GreenWithEnvy (GWE) through Flatpak so you can draw a custom fan curve.

## What the setup script does
- Creates or updates `/etc/X11/xorg.conf.d/20-nvidia-coolbits.conf` with a configurable CoolBits mask (default `12`).
- Keeps a timestamped backup if the file already exists.
- Optionally installs Flatpak (via `apt`) and GreenWithEnvy from Flathub.
- Adds the Flathub remote for the system (default) or a specific user if requested.

## Requirements
- Debian or derivative with the proprietary Nvidia driver already installed.
- Root privileges (run the script via `sudo`).
- X11 session (Wayland works through XWayland, but you still need the X11 config in place).

## Usage
```bash
sudo ./setup_nvidia_fan_control_X11.sh
```
For a turnkey setup that also deploys the Wayland shim and systemd service:
```bash
sudo ./setup_nvidia_fan_control_Wayland_And_X11.sh
```
After the script completes, restart your display manager or reboot so the CoolBits change is picked up. Launch GreenWithEnvy from your desktop menu or run:
```bash
flatpak run com.leinardi.gwe
```
Configure your desired fan curve in GWE and enable automatic profile loading if you want it at login.

## Wayland hosts

Nvidia exposes the NV-CONTROL extension only to Xorg, so GWE cannot talk to the driver when you log into a Wayland session. The helper `nvidia_wayland_fan_daemon.sh` shipped in this repo starts a minimal headless Xorg instance and enforces a fan curve through `nvidia-settings`, letting you stay on Wayland:

```bash
sudo ./nvidia_wayland_fan_daemon.sh \
    --curve "35:25,50:45,65:65,75:80,82:100"
```

`setup_nvidia_fan_control_Wayland_And_X11.sh` copies the daemon under `/usr/local/bin`, writes a `nvidia-wayland-fan.service` unit, and enables it automatically if you prefer not to manage those steps manually.

The curve is defined as comma-separated `temperature:speed` pairs (speed is a percentage). The daemon polls the GPU temperature via `nvidia-smi` and keeps the fan in manual mode until it exits, restoring automatic control after shutdown.

## Script options
- `--coolbits <value>`: override the CoolBits mask (defaults to `12`, which unlocks fan and overclock controls).
- `--skip-gwe`: configure CoolBits only, skip Flatpak/GWE installation.
- `--skip-apt-update`: do not run `apt-get update` before installing Flatpak.
- `--flatpak-scope <system|user>`: choose whether GreenWithEnvy is installed system-wide (default) or for a single user.
- `--flatpak-user <user>`: when using user scope, select the target account.
- `--help`: show usage info.

## Verification steps
1. Run `nvidia-smi --query-gpu=temperature.gpu,fan.speed --format=csv` to confirm the driver reports fan speed.
2. Start GreenWithEnvy and make sure the “Custom fan curve” toggle is available.
3. Apply a curve, monitor temperatures under load, and adjust as needed.
