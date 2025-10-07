#!/usr/bin/env python3
import copy
import ctypes
import ctypes.util
import json
import os
import shutil
import subprocess
import sys
import tkinter as tk
from tkinter import messagebox, ttk

from nvidia_fan_manager import DEFAULT_CONFIG as CORE_DEFAULT_CONFIG, normalize_config

CONFIG_PATH = "/etc/nvidia-fan-manager/config.json"
MANAGER_BINARY = "/usr/local/bin/nvidia_fan_manager.py"
SERVICE_NAME = "nvidia-fan-manager.service"

DEFAULT_CURVE = copy.deepcopy(CORE_DEFAULT_CONFIG["profiles"][0]["curve"])


def default_curve():
    return copy.deepcopy(DEFAULT_CURVE)


NVML_SUCCESS = 0


def _load_nvml_library():
    lib_path = ctypes.util.find_library("nvidia-ml")
    if not lib_path:
        raise RuntimeError("libnvidia-ml.so not found")
    lib = ctypes.CDLL(lib_path)
    lib.nvmlInit_v2.restype = ctypes.c_int
    lib.nvmlShutdown.restype = ctypes.c_int
    lib.nvmlErrorString.restype = ctypes.c_char_p
    lib.nvmlDeviceGetCount_v2.restype = ctypes.c_int
    lib.nvmlDeviceGetCount_v2.argtypes = [ctypes.POINTER(ctypes.c_uint)]
    lib.nvmlDeviceGetHandleByIndex_v2.restype = ctypes.c_int
    lib.nvmlDeviceGetHandleByIndex_v2.argtypes = [ctypes.c_uint, ctypes.POINTER(ctypes.c_void_p)]
    return lib


def _nvml_check(lib, result, msg):
    if result != NVML_SUCCESS:
        err = lib.nvmlErrorString(result).decode("utf-8", "ignore")
        raise RuntimeError(f"{msg}: {err}")


def discover_gpus_and_fans():
    lib = _load_nvml_library()
    gpus = []
    try:
        _nvml_check(lib, lib.nvmlInit_v2(), "nvmlInit")
        count = ctypes.c_uint()
        _nvml_check(lib, lib.nvmlDeviceGetCount_v2(ctypes.byref(count)), "nvmlDeviceGetCount_v2")
        for idx in range(count.value):
            handle = ctypes.c_void_p()
            _nvml_check(
                lib,
                lib.nvmlDeviceGetHandleByIndex_v2(ctypes.c_uint(idx), ctypes.byref(handle)),
                f"nvmlDeviceGetHandleByIndex_v2({idx})",
            )

            name = f"GPU {idx}"
            try:
                lib.nvmlDeviceGetName.restype = ctypes.c_int
                lib.nvmlDeviceGetName.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint]
                buf = ctypes.create_string_buffer(256)
                res = lib.nvmlDeviceGetName(handle, buf, ctypes.c_uint(len(buf)))
                if res == NVML_SUCCESS:
                    decoded = buf.value.decode("utf-8", "ignore")
                    if decoded:
                        name = decoded
            except AttributeError:
                pass

            fans = 1
            try:
                lib.nvmlDeviceGetNumFans.restype = ctypes.c_int
                lib.nvmlDeviceGetNumFans.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint)]
                fan_count = ctypes.c_uint()
                res = lib.nvmlDeviceGetNumFans(handle, ctypes.byref(fan_count))
                if res == NVML_SUCCESS and fan_count.value > 0:
                    fans = fan_count.value
            except AttributeError:
                pass

            gpus.append({"index": idx, "name": name, "fans": max(1, fans)})
    finally:
        try:
            lib.nvmlShutdown()
        except Exception:
            pass
    return gpus



def load_config() -> dict:
    if not os.path.exists(CONFIG_PATH):
        return copy.deepcopy(CORE_DEFAULT_CONFIG)
    with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    return normalize_config(data)


class FanCurveManagerGUI:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("Nvidia Fancurve Manager")
        self.config = load_config()
        self._loading = False
        self.gpu_options = self._discover_hardware()
        if not self.gpu_options:
            self.gpu_options = [{"index": 0, "name": "GPU 0", "fans": 1}]
        first_profile = self.config.get("profiles", [])[0]
        self.current_gpu_index = int(first_profile.get("gpu_index", self.gpu_options[0]["index"]))
        self.current_fan_index = int(first_profile.get("fan_index", 0))

        self._build_ui()
        self._populate_fields()

    def _build_ui(self):
        frm_main = ttk.Frame(self.root, padding=12)
        frm_main.grid(row=0, column=0, sticky="nsew")
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(0, weight=1)

        # Fan / GPU selectors
        frm_top = ttk.Frame(frm_main)
        frm_top.grid(row=0, column=0, sticky="ew")
        frm_top.columnconfigure(1, weight=1)
        frm_top.columnconfigure(3, weight=1)

        ttk.Label(frm_top, text="GPU").grid(row=0, column=0, sticky="w", padx=(0, 4))
        self.gpu_combo = ttk.Combobox(frm_top, state="readonly", width=36)
        self.gpu_combo.grid(row=0, column=1, sticky="ew")
        self.gpu_combo.bind("<<ComboboxSelected>>", self._on_gpu_selected)

        ttk.Label(frm_top, text="Fan").grid(row=0, column=2, sticky="w", padx=(16, 4))
        self.fan_combo = ttk.Combobox(frm_top, state="readonly", width=8)
        self.fan_combo.grid(row=0, column=3, sticky="w")
        self.fan_combo.bind("<<ComboboxSelected>>", self._on_fan_selected)

        self.poll_info_label = ttk.Label(frm_main, foreground="gray")
        self.poll_info_label.grid(row=1, column=0, sticky="w", pady=(6, 0))

        # Curve table
        frm_table = ttk.Frame(frm_main)
        frm_table.grid(row=2, column=0, sticky="nsew", pady=(12, 0))
        frm_main.rowconfigure(2, weight=1)
        frm_table.columnconfigure(0, weight=1)

        columns = ("temperature", "speed")
        self.tree = ttk.Treeview(frm_table, columns=columns, show="headings", selectmode="browse", height=10)
        self.tree.heading("temperature", text="Temperature (°C)")
        self.tree.heading("speed", text="Fan speed (%)")
        self.tree.column("temperature", width=130, anchor="center")
        self.tree.column("speed", width=130, anchor="center")
        self.tree.grid(row=0, column=0, sticky="nsew")

        scrollbar = ttk.Scrollbar(frm_table, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=scrollbar.set)
        scrollbar.grid(row=0, column=1, sticky="ns")

        # Curve controls
        frm_controls = ttk.Frame(frm_main)
        frm_controls.grid(row=3, column=0, sticky="ew", pady=(12, 0))
        frm_controls.columnconfigure(6, weight=1)

        ttk.Label(frm_controls, text="Temp °C").grid(row=0, column=0, padx=(0, 4))
        self.temp_entry = ttk.Entry(frm_controls, width=8)
        self.temp_entry.grid(row=0, column=1)

        ttk.Label(frm_controls, text="Speed %").grid(row=0, column=2, padx=(12, 4))
        self.speed_entry = ttk.Entry(frm_controls, width=8)
        self.speed_entry.grid(row=0, column=3)

        ttk.Button(frm_controls, text="Add point", command=self.add_point).grid(row=0, column=4, padx=(12, 0))
        ttk.Button(frm_controls, text="Remove selected", command=self.remove_selected).grid(row=0, column=5, padx=(8, 0))

        # Action buttons
        frm_actions = ttk.Frame(frm_main)
        frm_actions.grid(row=4, column=0, sticky="ew", pady=(16, 0))
        frm_actions.columnconfigure(0, weight=1)
        frm_actions.columnconfigure(1, weight=1)
        frm_actions.columnconfigure(2, weight=1)
        frm_actions.columnconfigure(3, weight=1)

        ttk.Button(frm_actions, text="Reload from disk", command=self.reload_config).grid(row=0, column=0, sticky="ew", padx=(0, 8))
        ttk.Button(frm_actions, text="Reset defaults", command=self.reset_defaults).grid(row=0, column=1, sticky="ew", padx=8)
        ttk.Button(frm_actions, text="Save", command=self.save_config).grid(row=0, column=2, sticky="ew", padx=8)
        ttk.Button(frm_actions, text="Apply (HUP service)", command=self.reload_service).grid(row=0, column=3, sticky="ew", padx=(8, 0))

    def _discover_hardware(self):
        try:
            gpus = discover_gpus_and_fans()
            if gpus:
                return gpus
        except Exception as exc:
            print(f"[fan-manager-gui] NVML discovery failed: {exc}", file=sys.stderr)
        return [{"index": 0, "name": "GPU 0", "fans": 1}]

    def _refresh_gpu_combo(self):
        values = [f"{info['index']}: {info['name']}" for info in self.gpu_options]
        self.gpu_combo["values"] = values or ["GPU 0"]

    def _profiles(self):
        return self.config.setdefault("profiles", [])

    def _find_profile(self, gpu_index: int, fan_index: int):
        for profile in self._profiles():
            if profile.get("gpu_index") == gpu_index and profile.get("fan_index") == fan_index:
                return profile
        return None

    def _default_hysteresis(self) -> float:
        profiles = self._profiles()
        if profiles:
            return float(profiles[0].get("hysteresis", 2.0))
        return 2.0

    def _get_or_create_profile(self, gpu_index: int, fan_index: int):
        profile = self._find_profile(gpu_index, fan_index)
        if profile is None:
            profile = {
                "gpu_index": gpu_index,
                "fan_index": fan_index,
                "curve": default_curve(),
                "hysteresis": self._default_hysteresis(),
            }
            self._profiles().append(profile)
        return profile

    def _set_tree_curve(self, curve):
        for item in self.tree.get_children():
            self.tree.delete(item)
        for point in sorted(curve, key=lambda p: p["temperature"]):
            self.tree.insert("", tk.END, values=(f"{point['temperature']:.1f}", f"{point['speed']:.1f}"))

    def _load_profile_curve(self, gpu_index: int, fan_index: int):
        profile = self._find_profile(gpu_index, fan_index)
        if profile is None:
            curve = default_curve()
        else:
            curve = profile.get("curve", default_curve())
        self._set_tree_curve(curve)
        self._update_poll_info()

    def _set_gpu_selection(self, gpu_index: int):
        match = 0
        for pos, info in enumerate(self.gpu_options):
            if info["index"] == gpu_index:
                match = pos
                break
        self._loading = True
        self.gpu_combo.current(match)
        self._loading = False
        self.current_gpu_index = self.gpu_options[match]["index"]

    def _update_fan_options(self, preferred_index: int = 0):
        selection = self.gpu_combo.current()
        if selection < 0:
            selection = 0
            self.gpu_combo.current(0)
        fans = max(1, self.gpu_options[selection].get("fans", 1))
        values = [str(i) for i in range(fans)]
        self.fan_combo["values"] = values or ["0"]
        if preferred_index >= fans or preferred_index < 0:
            preferred_index = 0
        self._loading = True
        self.fan_combo.current(preferred_index)
        self._loading = False
        self.current_fan_index = preferred_index

    def _on_gpu_selected(self, *_):
        if self._loading:
            return
        idx = self.gpu_combo.current()
        if idx < 0:
            return
        self.current_gpu_index = self.gpu_options[idx]["index"]
        preferred = self.current_fan_index
        if preferred >= self.gpu_options[idx].get("fans", 1):
            preferred = 0
        self._update_fan_options(preferred)
        self._load_profile_curve(self.current_gpu_index, self.current_fan_index)

    def _on_fan_selected(self, *_):
        if self._loading:
            return
        idx = self.fan_combo.current()
        if idx < 0:
            idx = 0
        self.current_fan_index = idx
        self._load_profile_curve(self.current_gpu_index, self.current_fan_index)

    def _update_poll_info(self):
        poll = float(self.config.get("poll_interval", 2.0))
        profile = self._find_profile(self.current_gpu_index, self.current_fan_index)
        if profile is not None:
            hysteresis = float(profile.get("hysteresis", self._default_hysteresis()))
        else:
            hysteresis = self._default_hysteresis()
        self.poll_info_label.config(
            text=f"Poll interval: {poll:.1f}s • Hysteresis: {hysteresis:.1f}% (use CLI for advanced tuning)"
        )

    def _populate_fields(self):
        self._loading = True
        self._refresh_gpu_combo()
        profiles = self._profiles()
        first_profile = profiles[0]
        self._set_gpu_selection(int(first_profile.get("gpu_index", self.gpu_options[0]["index"])))
        self._update_fan_options(int(first_profile.get("fan_index", 0)))
        self._loading = False
        self._load_profile_curve(self.current_gpu_index, self.current_fan_index)

    def reload_config(self):
        try:
            self.config = load_config()
            first_profile = self.config["profiles"][0]
            self.current_gpu_index = int(first_profile.get("gpu_index", self.gpu_options[0]["index"]))
            self.current_fan_index = int(first_profile.get("fan_index", 0))
            self._populate_fields()
            messagebox.showinfo("Reloaded", "Configuration reloaded from disk.")
        except Exception as exc:
            messagebox.showerror("Error", f"Failed to reload configuration:\n{exc}")

    def reset_defaults(self):
        profile = self._get_or_create_profile(self.current_gpu_index, self.current_fan_index)
        profile["curve"] = default_curve()
        self._set_tree_curve(profile["curve"])
        self._update_poll_info()

    def add_point(self):
        try:
            temperature = float(self.temp_entry.get())
            speed = float(self.speed_entry.get())
        except ValueError:
            messagebox.showerror("Invalid input", "Enter numeric values for temperature and speed.")
            return
        if temperature < 0:
            messagebox.showerror("Invalid input", "Temperature must be non-negative.")
            return
        if not 0 <= speed <= 100:
            messagebox.showerror("Invalid input", "Fan speed must be between 0 and 100.")
            return
        self.tree.insert("", tk.END, values=(f"{temperature:.1f}", f"{speed:.1f}"))
        self.temp_entry.delete(0, tk.END)
        self.speed_entry.delete(0, tk.END)

    def remove_selected(self):
        selection = self.tree.selection()
        if not selection:
            messagebox.showinfo("No selection", "Select a point to remove.")
            return
        self.tree.delete(selection[0])

    def _collect_curve(self):
        items = []
        for item in self.tree.get_children():
            temp_str, speed_str = self.tree.item(item, "values")
            items.append(
                {
                    "temperature": float(temp_str),
                    "speed": float(speed_str),
                }
            )
        if not items:
            raise ValueError("Curve must contain at least one point.")
        items.sort(key=lambda entry: entry["temperature"])
        last_temp = -1
        for entry in items:
            if entry["temperature"] <= last_temp:
                raise ValueError("Temperatures must be strictly increasing.")
            last_temp = entry["temperature"]
        return items

    def save_config(self):
        try:
            curve = self._collect_curve()
        except ValueError as exc:
            messagebox.showerror("Invalid input", str(exc))
            return

        poll_interval = float(self.config.get("poll_interval", 2.0))
        if poll_interval <= 0:
            messagebox.showerror("Invalid input", "Poll interval must be greater than zero.")
            return

        profile = self._get_or_create_profile(self.current_gpu_index, self.current_fan_index)
        hysteresis = float(profile.get("hysteresis", self._default_hysteresis()))
        if hysteresis < 0:
            messagebox.showerror("Invalid input", "Hysteresis cannot be negative.")
            return

        gpu_index = int(self.current_gpu_index)
        fan_index = int(self.current_fan_index)

        curve_str = ",".join(f"{pt['temperature']:.1f}:{pt['speed']:.1f}" for pt in curve)
        cmd = [
            "python3",
            MANAGER_BINARY,
            "--config",
            CONFIG_PATH,
            "--profile",
            f"{gpu_index}:{fan_index}",
            "--set-curve",
            curve_str,
            "--set-hysteresis",
            str(hysteresis),
            "--set-poll-interval",
            str(poll_interval),
        ]

        cmd = self._wrap_with_pkexec(cmd)
        if cmd is None:
            return

        try:
            result = subprocess.run(cmd, check=True, capture_output=True, text=True)
        except FileNotFoundError:
            messagebox.showerror("Error", f"Manager binary not found at {MANAGER_BINARY}")
            return
        except subprocess.CalledProcessError as exc:
            stderr = exc.stderr.strip() if exc.stderr else str(exc)
            messagebox.showerror("Error saving", f"Failed to update configuration:\n{stderr}")
            return

        profile["curve"] = [item.copy() for item in curve]
        profile["hysteresis"] = hysteresis
        self.config["poll_interval"] = poll_interval
        self._load_profile_curve(gpu_index, fan_index)
        messagebox.showinfo("Saved", "Configuration saved. Use 'Apply' to notify the running daemon.")

    def reload_service(self):
        if not shutil.which("systemctl"):
            messagebox.showinfo("systemctl not found", "systemctl is not available; restart the daemon manually.")
            return
        cmd = ["systemctl", "reload", SERVICE_NAME]
        cmd = self._wrap_with_pkexec(cmd)
        if cmd is None:
            return

        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            messagebox.showinfo("Reloaded", "Reload signal sent to the fan manager service.")
        else:
            stderr = result.stderr.strip() or "Unknown error"
            messagebox.showerror("Reload failed", f"Failed to reload service:\n{stderr}")

    def _wrap_with_pkexec(self, cmd):
        if os.geteuid() == 0:
            return cmd

        pkexec_path = shutil.which("pkexec")
        if not pkexec_path:
            messagebox.showerror(
                "Permission required",
                "pkexec not found. Install polkit, or launch this GUI with administrative privileges.",
            )
            return None

        env_cmd = [pkexec_path, "env"]
        for key in ("DISPLAY", "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS"):
            value = os.environ.get(key)
            if value:
                env_cmd.append(f"{key}={value}")
        return env_cmd + cmd


def main():
    root = tk.Tk()
    app = FanCurveManagerGUI(root)
    root.mainloop()


if __name__ == "__main__":
    main()
