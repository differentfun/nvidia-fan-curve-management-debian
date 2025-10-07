#!/usr/bin/env python3
import argparse
import json
import os
import signal
import sys
import time
from dataclasses import dataclass
from typing import List, Optional, Tuple

import ctypes
import ctypes.util

NVML_SUCCESS = 0
DEFAULT_CONFIG_PATH = "/etc/nvidia-fan-manager/config.json"
DEFAULT_CURVE = [
    {"temperature": 30, "speed": 25},
    {"temperature": 40, "speed": 35},
    {"temperature": 50, "speed": 45},
    {"temperature": 60, "speed": 60},
    {"temperature": 70, "speed": 75},
    {"temperature": 80, "speed": 90},
]
DEFAULT_PROFILE = {
    "gpu_index": 0,
    "fan_index": 0,
    "curve": DEFAULT_CURVE,
    "hysteresis": 2.0,
}
DEFAULT_CONFIG = {
    "poll_interval": 2.0,
    "profiles": [DEFAULT_PROFILE],
}


class NvmlError(RuntimeError):
    pass


def load_nvml():
    lib_path = ctypes.util.find_library("nvidia-ml")
    if not lib_path:
        raise NvmlError("libnvidia-ml.so not found. Install proprietary Nvidia driver utilities.")
    lib = ctypes.CDLL(lib_path)
    lib.nvmlInit_v2.restype = ctypes.c_int
    lib.nvmlShutdown.restype = ctypes.c_int
    lib.nvmlErrorString.restype = ctypes.c_char_p
    return lib


def nvml_error(lib, code, msg):
    if code != NVML_SUCCESS:
        err = lib.nvmlErrorString(code).decode("utf-8", "ignore")
        raise NvmlError(f"{msg}: {err}")


def ensure_root():
    if os.geteuid() != 0:
        raise SystemExit("This command must be run as root.")


def deep_copy_config(cfg: dict) -> dict:
    return json.loads(json.dumps(cfg))


def normalize_config(raw_cfg: dict) -> dict:
    cfg = deep_copy_config(raw_cfg)
    poll_interval = cfg.get("poll_interval", DEFAULT_CONFIG["poll_interval"])
    try:
        poll_interval = float(poll_interval)
    except (TypeError, ValueError):
        poll_interval = DEFAULT_CONFIG["poll_interval"]

    profiles_input = cfg.get("profiles")
    if not isinstance(profiles_input, list) or not profiles_input:
        profiles_input = [
            {
                "gpu_index": cfg.get("gpu_index", DEFAULT_PROFILE["gpu_index"]),
                "fan_index": cfg.get("fan_index", DEFAULT_PROFILE["fan_index"]),
                "curve": cfg.get("curve", DEFAULT_PROFILE["curve"]),
                "hysteresis": cfg.get("hysteresis", DEFAULT_PROFILE["hysteresis"]),
            }
        ]

    normalized_profiles: List[dict] = []
    for entry in profiles_input:
        try:
            gpu_idx = int(entry.get("gpu_index", DEFAULT_PROFILE["gpu_index"]))
            fan_idx = int(entry.get("fan_index", DEFAULT_PROFILE["fan_index"]))
        except (TypeError, ValueError):
            continue

        curve_raw = entry.get("curve") or DEFAULT_PROFILE["curve"]
        curve: List[dict] = []
        for point in curve_raw:
            try:
                temp = float(point["temperature"])
                speed = float(point["speed"])
            except (KeyError, TypeError, ValueError):
                continue
            curve.append({"temperature": temp, "speed": max(0.0, min(100.0, speed))})
        if not curve:
            curve = deep_copy_config(DEFAULT_PROFILE["curve"])
        curve.sort(key=lambda item: item["temperature"])

        hysteresis_raw = entry.get("hysteresis", cfg.get("hysteresis", DEFAULT_PROFILE["hysteresis"]))
        try:
            hysteresis = float(hysteresis_raw)
        except (TypeError, ValueError):
            hysteresis = DEFAULT_PROFILE["hysteresis"]

        normalized_profiles.append(
            {
                "gpu_index": gpu_idx,
                "fan_index": fan_idx,
                "curve": curve,
                "hysteresis": hysteresis,
            }
        )

    if not normalized_profiles:
        normalized_profiles = [deep_copy_config(DEFAULT_PROFILE)]

    return {
        "poll_interval": max(0.5, poll_interval),
        "profiles": normalized_profiles,
    }


def load_config(path: str) -> dict:
    if not os.path.exists(path):
        return deep_copy_config(DEFAULT_CONFIG)
    with open(path, "r", encoding="utf-8") as fh:
        cfg = json.load(fh)
    return normalize_config(cfg)


def save_config(path: str, config: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    config = normalize_config(config)
    temp_path = f"{path}.tmp"
    with open(temp_path, "w", encoding="utf-8") as fh:
        json.dump(config, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(temp_path, path)


def parse_curve_string(curve_str: str) -> List[dict]:
    points: List[dict] = []
    if not curve_str:
        raise ValueError("Curve string cannot be empty.")
    for entry in curve_str.split(","):
        entry = entry.strip()
        if not entry:
            continue
        if ":" not in entry:
            raise ValueError(f"Invalid curve entry '{entry}' (expected temp:speed).")
        temp_str, speed_str = entry.split(":", 1)
        try:
            temp = float(temp_str)
            speed = float(speed_str)
        except ValueError as exc:
            raise ValueError(f"Invalid numbers in entry '{entry}'.") from exc
        if temp < 0:
            raise ValueError("Temperature values must be non-negative.")
        if not 0 <= speed <= 100:
            raise ValueError("Fan speed values must be between 0 and 100.")
        points.append({"temperature": temp, "speed": speed})
    if not points:
        raise ValueError("Curve must contain at least one point.")
    points.sort(key=lambda item: item["temperature"])
    return points


@dataclass
class CurvePoint:
    temperature: float
    speed: float


class FanCurve:
    def __init__(self, points: List[CurvePoint]):
        if not points:
            raise ValueError("Fan curve requires at least one point.")
        self._points = sorted(points, key=lambda p: p.temperature)

    @classmethod
    def from_dicts(cls, items: List[dict]) -> "FanCurve":
        pts = []
        for item in items:
            pts.append(CurvePoint(float(item["temperature"]), float(item["speed"])))
        return cls(pts)

    def to_dicts(self) -> List[dict]:
        return [{"temperature": p.temperature, "speed": p.speed} for p in self._points]

    def value(self, temperature: float) -> float:
        chosen = self._points[0].speed
        for point in self._points:
            if temperature >= point.temperature:
                chosen = point.speed
            else:
                break
        return chosen


def parse_profile_token(token: str) -> Tuple[int, int]:
    if token is None:
        raise ValueError("Profile selector is required")
    parts = token.split(":", 1)
    if len(parts) != 2:
        raise ValueError(f"Invalid profile spec '{token}' (expected gpu:fan)")
    try:
        gpu_idx = int(parts[0])
        fan_idx = int(parts[1])
    except ValueError as exc:
        raise ValueError(f"Invalid integers in profile spec '{token}'") from exc
    if gpu_idx < 0 or fan_idx < 0:
        raise ValueError("GPU and fan indices must be non-negative")
    return gpu_idx, fan_idx


def find_profile(profiles: List[dict], gpu_index: int, fan_index: int) -> Optional[dict]:
    for profile in profiles:
        if profile.get("gpu_index") == gpu_index and profile.get("fan_index") == fan_index:
            return profile
    return None


def ensure_profile(profiles: List[dict], gpu_index: int, fan_index: int, create: bool = False) -> Optional[dict]:
    profile = find_profile(profiles, gpu_index, fan_index)
    if profile is None and create:
        profile = {
            "gpu_index": gpu_index,
            "fan_index": fan_index,
            "curve": deep_copy_config(DEFAULT_CURVE),
            "hysteresis": DEFAULT_PROFILE["hysteresis"],
        }
        profiles.append(profile)
    return profile


def remove_profile(profiles: List[dict], gpu_index: int, fan_index: int) -> bool:
    for idx, profile in enumerate(list(profiles)):
        if profile.get("gpu_index") == gpu_index and profile.get("fan_index") == fan_index:
            profiles.pop(idx)
            return True
    return False


def resolve_profile_tuple(args, config: dict) -> Tuple[int, int]:
    if args.profile:
        return parse_profile_token(args.profile)
    profiles = config.get("profiles", [])
    base = profiles[0] if profiles else DEFAULT_PROFILE
    gpu = args.gpu_index if args.gpu_index is not None else int(base.get("gpu_index", 0))
    fan = args.fan_index if args.fan_index is not None else int(base.get("fan_index", 0))
    if gpu < 0 or fan < 0:
        raise ValueError("GPU and fan indices must be non-negative")
    return gpu, fan


class NvmlController:
    def __init__(self, gpu_index: int, fan_index: int):
        self.gpu_index = gpu_index
        self.fan_index = fan_index
        self.lib = load_nvml()
        nvml_error(self.lib, self.lib.nvmlInit_v2(), "nvmlInit failed")
        self.device = self._get_device_handle(gpu_index)
        self._validate_fan_index(fan_index)

    def shutdown(self):
        self.lib.nvmlShutdown()

    def _get_device_handle(self, index: int):
        handle = ctypes.c_void_p()
        func = self.lib.nvmlDeviceGetHandleByIndex_v2
        func.argtypes = [ctypes.c_uint, ctypes.POINTER(ctypes.c_void_p)]
        func.restype = ctypes.c_int
        nvml_error(self.lib, func(index, ctypes.byref(handle)), "nvmlDeviceGetHandleByIndex failed")
        return handle

    def _validate_fan_index(self, fan_index: int):
        try:
            func = self.lib.nvmlDeviceGetNumFans
        except AttributeError:
            return
        value = ctypes.c_uint()
        func.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint)]
        func.restype = ctypes.c_int
        nvml_error(self.lib, func(self.device, ctypes.byref(value)), "nvmlDeviceGetNumFans failed")
        if fan_index >= value.value:
            raise NvmlError(f"Fan index {fan_index} out of range (available: {value.value}).")

    def get_temperature(self) -> float:
        func = self.lib.nvmlDeviceGetTemperature
        func.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.POINTER(ctypes.c_uint)]
        func.restype = ctypes.c_int
        result = ctypes.c_uint()
        nvml_error(
            self.lib,
            func(self.device, 0, ctypes.byref(result)),
            "nvmlDeviceGetTemperature failed",
        )
        return float(result.value)

    def get_fan_speed(self) -> float:
        func = self.lib.nvmlDeviceGetFanSpeed_v2
        func.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.POINTER(ctypes.c_uint)]
        func.restype = ctypes.c_int
        value = ctypes.c_uint()
        nvml_error(
            self.lib,
            func(self.device, ctypes.c_uint(self.fan_index), ctypes.byref(value)),
            "nvmlDeviceGetFanSpeed_v2 failed",
        )
        return float(value.value)

    def set_fan_speed(self, speed: float):
        speed_int = ctypes.c_uint(int(round(speed)))
        func = self.lib.nvmlDeviceSetFanSpeed_v2
        func.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint]
        func.restype = ctypes.c_int
        nvml_error(
            self.lib,
            func(self.device, ctypes.c_uint(self.fan_index), speed_int),
            "nvmlDeviceSetFanSpeed_v2 failed",
        )

    def restore_auto(self):
        func = self.lib.nvmlDeviceSetDefaultFanSpeed_v2
        func.argtypes = [ctypes.c_void_p, ctypes.c_uint]
        func.restype = ctypes.c_int
        nvml_error(
            self.lib,
            func(self.device, ctypes.c_uint(self.fan_index)),
            "nvmlDeviceSetDefaultFanSpeed_v2 failed",
        )


@dataclass
class ManagedProfile:
    gpu_index: int
    fan_index: int
    curve: FanCurve
    hysteresis: float
    controller: NvmlController
    last_speed: Optional[float] = None
    last_temp: Optional[float] = None

    def close(self, restore_auto: bool):
        if restore_auto:
            try:
                self.controller.restore_auto()
            except NvmlError as exc:
                print(
                    f"[fan-manager] Failed to restore automatic mode for GPU {self.gpu_index} fan {self.fan_index}: {exc}",
                    file=sys.stderr,
                )
        self.controller.shutdown()


class FanManager:
    def __init__(
        self,
        profiles: List[ManagedProfile],
        poll_interval: float,
        restore_on_exit: bool,
        config_path: str,
    ):
        self.profiles = profiles
        self.poll_interval = max(0.5, float(poll_interval))
        self.restore_on_exit = restore_on_exit
        self.config_path = config_path
        self._running = True
        self._reload_requested = False
        signal.signal(signal.SIGTERM, self.stop)
        signal.signal(signal.SIGINT, self.stop)
        signal.signal(signal.SIGHUP, self.trigger_reload)

    def stop(self, *_):
        self._running = False

    def trigger_reload(self, *_):
        self._reload_requested = True

    def set_profiles(self, profiles: List[ManagedProfile]):
        self._close_profiles(self.profiles, restore=self.restore_on_exit)
        self.profiles = profiles

    @staticmethod
    def _close_profiles(profiles: List[ManagedProfile], restore: bool):
        for profile in profiles:
            profile.close(restore)

    @staticmethod
    def should_apply(profile: ManagedProfile, target_speed: float) -> bool:
        if profile.last_speed is None:
            return True
        threshold = max(0.5, profile.hysteresis)
        return abs(target_speed - profile.last_speed) >= threshold

    @staticmethod
    def apply_speed(profile: ManagedProfile, target_speed: float, temperature: float):
        target_speed = max(10.0, min(100.0, target_speed))
        profile.controller.set_fan_speed(target_speed)
        profile.last_speed = target_speed
        profile.last_temp = temperature

    def loop_once(self):
        if not self.profiles:
            print("[fan-manager] No profiles configured; sleeping.", flush=True)
            time.sleep(self.poll_interval)
            return

        for profile in self.profiles:
            try:
                temperature = profile.controller.get_temperature()
                target = profile.curve.value(temperature)
                if self.should_apply(profile, target):
                    self.apply_speed(profile, target, temperature)
                    print(
                        f"[fan-manager] GPU {profile.gpu_index} fan {profile.fan_index} temp={temperature:.1f}°C target={target:.1f}% applied",
                        flush=True,
                    )
                else:
                    print(
                        f"[fan-manager] GPU {profile.gpu_index} fan {profile.fan_index} temp={temperature:.1f}°C target={target:.1f}% (within hysteresis)",
                        flush=True,
                    )
            except NvmlError as exc:
                print(
                    f"[fan-manager] Error managing GPU {profile.gpu_index} fan {profile.fan_index}: {exc}",
                    file=sys.stderr,
                    flush=True,
                )

    def run(self):
        try:
            while self._running:
                if self._reload_requested:
                    self.reload_config()
                    self._reload_requested = False
                self.loop_once()
                time.sleep(self.poll_interval)
        finally:
            self._close_profiles(self.profiles, restore=self.restore_on_exit)

    def reload_config(self):
        try:
            cfg = load_config(self.config_path)
        except Exception as exc:
            print(f"[fan-manager] Failed to reload config: {exc}", file=sys.stderr)
            return
        try:
            new_profiles = build_managed_profiles(cfg)
        except Exception as exc:
            print(f"[fan-manager] Invalid configuration: {exc}", file=sys.stderr)
            for profile in new_profiles if 'new_profiles' in locals() else []:
                profile.close(restore_auto=False)
            return
        self.poll_interval = max(0.5, float(cfg.get("poll_interval", self.poll_interval)))
        self.set_profiles(new_profiles)
        print("[fan-manager] Configuration reloaded.", flush=True)


def build_managed_profiles(cfg: dict) -> List[ManagedProfile]:
    profiles = []
    try:
        for entry in cfg.get("profiles", []):
            gpu_index = int(entry.get("gpu_index", DEFAULT_PROFILE["gpu_index"]))
            fan_index = int(entry.get("fan_index", DEFAULT_PROFILE["fan_index"]))
            curve = FanCurve.from_dicts(entry.get("curve", DEFAULT_CURVE))
            hysteresis = float(entry.get("hysteresis", DEFAULT_PROFILE["hysteresis"]))
            controller = NvmlController(gpu_index, fan_index)
            profile = ManagedProfile(
                gpu_index=gpu_index,
                fan_index=fan_index,
                curve=curve,
                hysteresis=hysteresis,
                controller=controller,
            )
            profiles.append(profile)
        return profiles
    except Exception:
        for profile in profiles:
            profile.close(restore_auto=False)
        raise


def command_status(config: dict, profile_selector: Optional[Tuple[int, int]] = None) -> None:
    poll_interval = float(config.get("poll_interval", DEFAULT_CONFIG["poll_interval"]))
    profiles_cfg = config.get("profiles", [])
    if not profiles_cfg:
        print(json.dumps({"poll_interval": poll_interval, "profiles": []}, indent=2))
        return

    if profile_selector is not None:
        profile = find_profile(profiles_cfg, *profile_selector)
        if profile is None:
            raise SystemExit(f"Profile {profile_selector[0]}:{profile_selector[1]} not found.")
        selected = [profile]
    else:
        selected = profiles_cfg

    entries = []
    for entry in selected:
        try:
            controller = NvmlController(entry["gpu_index"], entry["fan_index"])
        except NvmlError as exc:
            raise SystemExit(f"Failed to query GPU {entry['gpu_index']} fan {entry['fan_index']}: {exc}") from exc
        try:
            temp = controller.get_temperature()
            speed = controller.get_fan_speed()
            target = FanCurve.from_dicts(entry["curve"]).value(temp)
        finally:
            controller.shutdown()
        entries.append(
            {
                "gpu_index": entry["gpu_index"],
                "fan_index": entry["fan_index"],
                "temperature": temp,
                "current_speed": speed,
                "target_speed": target,
                "hysteresis": float(entry.get("hysteresis", DEFAULT_PROFILE["hysteresis"])),
            }
        )

    print(json.dumps({"poll_interval": poll_interval, "profiles": entries}, indent=2))


def restore_auto_profiles(config: dict, profile_selector: Optional[Tuple[int, int]] = None) -> None:
    profiles_cfg = config.get("profiles", [])
    if profile_selector is not None:
        profile = find_profile(profiles_cfg, *profile_selector)
        if profile is None:
            raise SystemExit(f"Profile {profile_selector[0]}:{profile_selector[1]} not found.")
        targets = [profile]
    else:
        targets = profiles_cfg

    if not targets:
        print("No profiles configured.")
        return

    for entry in targets:
        controller = NvmlController(entry["gpu_index"], entry["fan_index"])
        try:
            controller.restore_auto()
            print(f"Automatic fan control restored for GPU {entry['gpu_index']} fan {entry['fan_index']}.")
        finally:
            controller.shutdown()


def ensure_config_defaults(path: str):
    if not os.path.exists(path):
        save_config(path, deep_copy_config(DEFAULT_CONFIG))


def main():
    parser = argparse.ArgumentParser(description="Nvidia Fan Manager (NVML-based)")
    parser.add_argument("--config", default=DEFAULT_CONFIG_PATH, help="Path to configuration file.")
    parser.add_argument("--profile", help="Select a profile as gpu:fan (default: first profile).")
    parser.add_argument("--add-profile", help="Add a profile for gpu:fan (creates with default curve).")
    parser.add_argument("--remove-profile", help="Remove profile gpu:fan.")
    parser.add_argument("--list-profiles", action="store_true", help="List configured profiles and exit.")
    parser.add_argument("--gpu-index", type=int, help="Legacy override for GPU index (used if --profile omitted).")
    parser.add_argument("--fan-index", type=int, help="Legacy override for fan index (used if --profile omitted).")
    parser.add_argument("--daemon", action="store_true", help="Run as daemon.")
    parser.add_argument("--once", action="store_true", help="Apply curve once and exit.")
    parser.add_argument("--status", action="store_true", help="Show current readings.")
    parser.add_argument("--restore-auto", action="store_true", help="Restore automatic fan control and exit.")
    parser.add_argument("--set-curve", help="Update curve definition (e.g. '40:30,60:50,80:80').")
    parser.add_argument("--set-poll-interval", type=float, help="Update poll interval in seconds.")
    parser.add_argument("--set-hysteresis", type=float, help="Update hysteresis in °C.")
    parser.add_argument("--no-restore-on-exit", action="store_true", help="Do not restore auto mode when exiting daemon.")
    args = parser.parse_args()

    ensure_root()
    ensure_config_defaults(args.config)

    config = load_config(args.config)
    config_changed = False

    if args.add_profile:
        gpu, fan = parse_profile_token(args.add_profile)
        ensure_profile(config["profiles"], gpu, fan, create=True)
        config_changed = True
        if not args.profile:
            args.profile = args.add_profile

    if args.remove_profile:
        gpu, fan = parse_profile_token(args.remove_profile)
        if remove_profile(config["profiles"], gpu, fan):
            config_changed = True
        else:
            print(f"Profile {gpu}:{fan} not found.", file=sys.stderr)

    target_profile = None
    if args.set_curve or args.set_hysteresis is not None:
        gpu, fan = resolve_profile_tuple(args, config)
        target_profile = ensure_profile(config["profiles"], gpu, fan, create=True)

    if args.set_curve:
        target_profile["curve"] = parse_curve_string(args.set_curve)
        config_changed = True

    if args.set_hysteresis is not None:
        hysteresis = max(0.0, float(args.set_hysteresis))
        target_profile = target_profile or ensure_profile(
            config["profiles"],
            *resolve_profile_tuple(args, config),
            create=True,
        )
        target_profile["hysteresis"] = hysteresis
        config_changed = True

    if args.set_poll_interval is not None:
        config["poll_interval"] = max(0.5, float(args.set_poll_interval))
        config_changed = True

    if config_changed:
        save_config(args.config, config)
        print(f"Configuration updated: {args.config}")
        if not (args.status or args.restore_auto or args.once or args.daemon or args.list_profiles):
            return
        config = load_config(args.config)

    if args.list_profiles:
        print(json.dumps(config, indent=2))
        return

    profile_selector: Optional[Tuple[int, int]] = None
    if args.profile or args.gpu_index is not None or args.fan_index is not None:
        profile_selector = resolve_profile_tuple(args, config)

    if args.status:
        command_status(config, profile_selector)
        return

    if args.restore_auto:
        restore_auto_profiles(config, profile_selector)
        return

    if args.once or args.daemon:
        try:
            managed_profiles = build_managed_profiles(config)
        except NvmlError as exc:
            raise SystemExit(f"Failed to initialize NVML: {exc}") from exc

        manager = FanManager(
            profiles=managed_profiles,
            poll_interval=config.get("poll_interval", DEFAULT_CONFIG["poll_interval"]),
            restore_on_exit=not args.no_restore_on_exit,
            config_path=args.config,
        )

        if args.once:
            try:
                manager.loop_once()
            finally:
                manager.set_profiles([])
            return

        if args.daemon:
            print("Starting Nvidia fan manager daemon...")
            manager.run()
            return

    parser.print_help()


if __name__ == "__main__":
    main()
