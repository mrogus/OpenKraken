"""Render an NZXT-style *web integration* to a frame for the Kraken LCD.

This is OpenKraken's Linux stand-in for NZXT CAM's "Web Integration": a web app
(HTML/JS/CSS, e.g. https://reinhardtbotha.github.io/NZXT-aviation/) is loaded in a
headless Chromium via Playwright, fed live telemetry through the same
``window.nzxt.v1`` API CAM injects, and screenshotted at the LCD resolution. The
engine then streams those frames to the panel like any other LCD content.

Playwright is an **optional** dependency: :meth:`WebRenderer.available` returns
False when it (or its browser) is missing, so the rest of the app is unaffected.
All browser calls must happen on a single thread (the engine thread owns the
instance) -- the Playwright *sync* API requires that.
"""
from __future__ import annotations

import logging
from typing import Any

_LOGGER = logging.getLogger(__name__)

# The NZXT web-integration API CAM injects before the app runs. The app reads
# width/height/shape/targetFps from here, then overwrites window.nzxt with its
# own object exposing onMonitoringDataUpdate (which we call each frame).
_SHIM = (
    'window.nzxt = {{ v1: {{ width: {size}, height: {size}, '
    'shape: "circle", targetFps: {fps} }} }};'
)

# Integrations render their *display* (vs the CAM settings pane) only when the
# URL carries this query flag; add it if the caller didn't.
_KRAKEN_QUERY = "kraken=1"


def _with_kraken_flag(url: str) -> str:
    if _KRAKEN_QUERY in url:
        return url
    sep = "&" if "?" in url else "?"
    return f"{url}{sep}{_KRAKEN_QUERY}"


# --------------------------------------------------------------------------- #
# Telemetry -> NZXT MonitoringData
# --------------------------------------------------------------------------- #

# Cached NVML handle for the optional GPU core-clock readout (best-effort).
_nvml_state: dict[str, Any] = {"tried": False, "mod": None, "handle": None}


def _gpu_clock_mhz() -> int | None:
    if not _nvml_state["tried"]:
        _nvml_state["tried"] = True
        try:
            import pynvml

            pynvml.nvmlInit()
            _nvml_state["handle"] = pynvml.nvmlDeviceGetHandleByIndex(0)
            _nvml_state["mod"] = pynvml
        except Exception:
            _nvml_state["mod"] = None
    mod = _nvml_state["mod"]
    if mod is None:
        return None
    try:
        return int(mod.nvmlDeviceGetClockInfo(_nvml_state["handle"], mod.NVML_CLOCK_GRAPHICS))
    except Exception:
        return None


def _frac(pct: float | None) -> float | None:
    """0..100 percentage -> 0..1 fraction (the shape NZXT integrations expect)."""
    return pct / 100.0 if pct is not None else None


def build_monitoring_data(snap: Any, status: Any) -> dict:
    """Build the ``window.nzxt.v1`` MonitoringData object from live telemetry.

    ``snap`` is a :class:`~openkraken.backend.sensors.SystemSnapshot` and
    ``status`` a :class:`~openkraken.backend.device.DeviceStatus` (either may be
    ``None``). Loads are emitted as 0..1 fractions; the AIO pump is reported as
    the CPU cooler's ``fanSpeed`` (how CAM surfaces it) as well as under
    ``kraken.pumpSpeed``.
    """
    g = lambda o, a: getattr(o, a, None) if o is not None else None  # noqa: E731

    pump = g(status, "pump_rpm")
    fan = g(status, "fan_rpm")
    ram_used = g(snap, "ram_used_gb")
    ram_total = g(snap, "ram_total_gb")

    return {
        "cpus": [
            {
                "name": "CPU",
                "temperature": g(snap, "cpu_temp"),
                "load": _frac(g(snap, "cpu_load")),
                "frequency": (
                    round(snap.cpu_freq_mhz)
                    if getattr(snap, "cpu_freq_mhz", None)
                    else None
                ),
                "fanSpeed": pump,  # AIO pump shows up as the CPU-cooler fan
                "power": None,
            }
        ],
        "gpus": [
            {
                "name": "GPU",
                "type": "Nvidia",
                "temperature": g(snap, "gpu_temp"),
                "load": _frac(g(snap, "gpu_load")),
                "frequency": _gpu_clock_mhz(),
                "power": g(snap, "gpu_power_w"),
                "fanSpeed": None,
            }
        ],
        "ram": {
            "inUse": round(ram_used * 1024) if ram_used is not None else None,
            "totalSize": round(ram_total * 1024) if ram_total is not None else None,
        },
        "kraken": {
            "liquidTemperature": g(status, "liquid_temp"),
            "fanSpeed": fan,
            "pumpSpeed": pump,
        },
    }


# --------------------------------------------------------------------------- #
# Renderer
# --------------------------------------------------------------------------- #

_FRAME_PATH = "/dev/shm/openkraken_web.png"


class WebRenderer:
    """Headless-Chromium renderer for a single web integration URL.

    Owns one Playwright browser + page; :meth:`render` feeds telemetry and
    returns a fresh PNG path. Lazily started on first :meth:`render`; a URL
    change reloads. Every method must be called from the same thread.
    """

    def __init__(self, size: int = 640, fps: int = 10) -> None:
        self._size = size
        self._fps = fps
        self._pw = None
        self._browser = None
        self._page = None
        self._url: str | None = None
        self._frame_path = _FRAME_PATH

    @staticmethod
    def available() -> bool:
        """True if Playwright (and, best-effort, its browser) can be used."""
        try:
            import playwright.sync_api  # noqa: F401
        except Exception:
            return False
        return True

    def set_url(self, url: str) -> None:
        """Select the integration URL; reloaded on the next :meth:`render`."""
        url = _with_kraken_flag(url)
        if url != self._url:
            self._url = url
            # Force a reload on next render (tear the page down lazily there).
            self._teardown_page()

    # -- lifecycle -------------------------------------------------------- #
    def _ensure_started(self) -> bool:
        if self._page is not None:
            return True
        if not self._url:
            return False
        try:
            from playwright.sync_api import sync_playwright

            if self._pw is None:
                self._pw = sync_playwright().start()
            if self._browser is None:
                self._browser = self._pw.chromium.launch(headless=True)
            page = self._browser.new_page(
                viewport={"width": self._size, "height": self._size},
                device_scale_factor=1,
            )
            page.add_init_script(_SHIM.format(size=self._size, fps=self._fps))
            page.goto(self._url, wait_until="networkidle", timeout=45000)
            page.wait_for_function(
                "() => window.nzxt && window.nzxt.v1 && "
                "typeof window.nzxt.v1.onMonitoringDataUpdate === 'function'",
                timeout=20000,
            )
            self._page = page
            _LOGGER.info("web integration loaded: %s", self._url)
            return True
        except Exception as exc:
            _LOGGER.warning("web integration failed to load (%s): %s", self._url, exc)
            self._teardown_page()
            return False

    def render(self, data: dict) -> str | None:
        """Feed ``data`` to the integration and return a fresh frame path.

        Returns ``None`` on any failure (caller keeps the previous frame).
        """
        if not self._ensure_started():
            return None
        try:
            self._page.evaluate("(d) => window.nzxt.v1.onMonitoringDataUpdate(d)", data)
            self._page.screenshot(
                path=self._frame_path,
                clip={"x": 0, "y": 0, "width": self._size, "height": self._size},
            )
            return self._frame_path
        except Exception as exc:
            _LOGGER.warning("web integration render failed: %s", exc)
            self._teardown_page()  # force a clean reload next tick
            return None

    def _teardown_page(self) -> None:
        page, self._page = self._page, None
        try:
            if page is not None:
                page.close()
        except Exception:
            pass

    def close(self) -> None:
        """Tear down the page, browser and Playwright driver (idempotent)."""
        self._teardown_page()
        for attr, closer in (("_browser", "close"), ("_pw", "stop")):
            obj = getattr(self, attr)
            setattr(self, attr, None)
            try:
                if obj is not None:
                    getattr(obj, closer)()
            except Exception:
                pass
