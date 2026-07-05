#!/usr/bin/env python3
"""Prototype: render an NZXT web integration to a 640x640 frame and (optionally)
push it to the Kraken LCD -- a Linux stand-in for NZXT CAM's "Web Integration".

Pipeline: Playwright (Chromium) loads the web app, we inject the NZXT
``window.nzxt.v1`` API shim *before* the app runs, feed it real telemetry via
``onMonitoringDataUpdate`` (CPU + discrete GPU via OpenKraken's SystemSensors,
liquid temp/fan/pump from the nzxt_kraken3 hwmon), then screenshot the result.

Usage:
    weblcd_proto.py [URL] [--out PATH] [--push] [--scale N]
"""
from __future__ import annotations

import argparse
import glob
import sys
import time

sys.path.insert(0, "/var/home/roger/github/openkraken")

DEFAULT_URL = "https://reinhardtbotha.github.io/NZXT-aviation/"
SIZE = 640


def _read_int(path: str) -> int | None:
    try:
        return int(open(path).read().strip())
    except Exception:
        return None


def _kraken_hwmon() -> str | None:
    for h in glob.glob("/sys/class/hwmon/hwmon*"):
        try:
            if open(h + "/name").read().strip() == "kraken2023elite":
                return h
        except OSError:
            pass
    return None


def gather_data() -> dict:
    """Build the NZXT MonitoringData object from real system sensors."""
    from openkraken.backend.sensors import SystemSensors

    s = SystemSensors()
    s.read()
    time.sleep(0.4)
    snap = s.read()

    kh = _kraken_hwmon()
    liquid = fan = pump = None
    if kh:
        t = _read_int(kh + "/temp1_input")
        liquid = round(t / 1000.0, 1) if t is not None else None
        # kraken3 hwmon: fan1 = pump, fan2 = fan (best-effort).
        pump = _read_int(kh + "/fan1_input")
        fan = _read_int(kh + "/fan2_input")

    def gb_to_mb(v):
        return round(v * 1024) if v is not None else None

    def frac(v):
        # This integration multiplies load by 100, i.e. it expects a 0..1
        # fraction, so convert our 0..100 percentages.
        return v / 100.0 if v is not None else 0.0

    # GPU core clock (MHz) via NVML for the "GPU MHz" readout.
    gpu_clock = None
    try:
        import pynvml

        pynvml.nvmlInit()
        _h = pynvml.nvmlDeviceGetHandleByIndex(0)
        gpu_clock = pynvml.nvmlDeviceGetClockInfo(_h, pynvml.NVML_CLOCK_GRAPHICS)
    except Exception:
        pass

    data = {
        "cpus": [
            {
                "name": "CPU",
                "temperature": snap.cpu_temp,
                "load": frac(snap.cpu_load),
                "frequency": round(snap.cpu_freq_mhz) if snap.cpu_freq_mhz else None,
                # This integration's bottom "PUMP" cell reads cpu.fanSpeed (it
                # only takes liquidTemperature from the kraken object), so feed
                # the pump RPM here.
                "fanSpeed": pump,
                "power": None,
            }
        ],
        "gpus": [
            {
                "name": "NVIDIA GeForce RTX 5080",
                "type": "Nvidia",
                "temperature": snap.gpu_temp,
                "load": frac(snap.gpu_load),
                "frequency": gpu_clock,
                "power": snap.gpu_power_w,
                "fanSpeed": None,
            }
        ],
        "ram": {
            "inUse": gb_to_mb(snap.ram_used_gb),
            "totalSize": gb_to_mb(snap.ram_total_gb),
        },
        "kraken": {
            "liquidTemperature": liquid,
            "fanSpeed": fan,
            "pumpSpeed": pump,
        },
    }
    return data


def render(url: str, out_path: str, scale: int) -> str:
    from playwright.sync_api import sync_playwright

    data = gather_data()
    print("telemetry ->", data)

    init = (
        f'window.nzxt = {{ v1: {{ width: {SIZE}, height: {SIZE}, '
        f'shape: "circle", targetFps: 10 }} }};'
    )

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(
            viewport={"width": SIZE, "height": SIZE},
            device_scale_factor=scale,
        )
        page.add_init_script(init)
        page.goto(url, wait_until="networkidle", timeout=45000)
        # Wait until the app has registered its monitoring callback.
        page.wait_for_function(
            "() => window.nzxt && window.nzxt.v1 && "
            "typeof window.nzxt.v1.onMonitoringDataUpdate === 'function'",
            timeout=20000,
        )
        # Push telemetry a few times so any animation/settling completes.
        for _ in range(6):
            page.evaluate("(d) => window.nzxt.v1.onMonitoringDataUpdate(d)", data)
            time.sleep(0.25)
        time.sleep(0.5)
        page.screenshot(
            path=out_path,
            clip={"x": 0, "y": 0, "width": SIZE, "height": SIZE},
        )
        browser.close()
    print("rendered ->", out_path)
    return out_path


def push_to_lcd(image_path: str) -> None:
    """Push the rendered PNG to the Kraken via OpenKraken's device wrapper."""
    from openkraken.backend.device import KrakenDevice

    dev = KrakenDevice()
    if not dev.connect():
        print("push: could not connect to Kraken (is OpenKraken still running?)")
        return
    ok = dev.set_lcd_static(image_path)
    print("push: set_lcd_static ->", ok)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("url", nargs="?", default=DEFAULT_URL)
    ap.add_argument("--out", default="/tmp/aviation_render.png")
    ap.add_argument("--scale", type=int, default=1, help="device scale factor")
    ap.add_argument("--push", action="store_true", help="push to Kraken LCD")
    args = ap.parse_args()

    out = render(args.url, args.out, args.scale)
    if args.push:
        push_to_lcd(out)


if __name__ == "__main__":
    main()
