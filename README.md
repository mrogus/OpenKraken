# Kraken-Redux

NZXT doesn't ship CAM for Linux. This app fills that gap: monitor your loop,
edit pump/fan curves, drive the round LCD (sensor screens, images, GIFs, web
integrations), and control the RGB lighting — all without booting into
Windows.

## Compatible devices

Built on [liquidctl](https://github.com/liquidctl/liquidctl)'s `KrakenZ3`
driver. Anything it lists under that class should work:

| Model | USB ID | LCD |
| --- | --- | --- |
| Kraken Z (Z53 / Z63 / Z73) | `1e71:3008` | 320×320 |
| Kraken 2023 Elite | `1e71:300c` | 640×640 |
| Kraken 2023 | `1e71:300e` | 240×240 |
| Kraken 2024 Elite RGB | `1e71:3012` | 640×640 |
| Kraken 2024 Plus | `1e71:3014` | 240×240 |

Native RGB control (the reverse-engineered HUE2 protocol, see
[PROTOCOL.md](PROTOCOL.md)) was built against the 2024 Elite RGB — other
models should work for cooling/LCD but haven't been checked for lighting.

## Credit

This is a fork of [OpenKraken](https://github.com/davidboulay/OpenKraken) by
David Boulay. All the hard work — reverse-engineering the LCD/RGB protocol,
the PyQt6 GUI, the cooling engine, the Debian packaging — is his. His original
version already had: live sensor dashboard, pump/fan curves, LCD sensor
screens/images/GIFs, native RGB lighting, a Debian package + universal
installer, and self-update.

## What this fork adds/fixes

- LCD font resolution via fontconfig (was hardcoded to a Debian path — broken
  on Fedora/Arch/etc.)
- A PyQt6 GUI crash when a second error arrives before the first clears
- A streamed sensor-frame orientation bug
- NVML-based NVIDIA telemetry (no more spawning `nvidia-smi` per sample)
- A **Web Integration** LCD mode — see below
- Device (re)connect went from ~11s to ~50ms on hardware that never answers
  the lighting-info query (the 2023 Elite doesn't; the app now learns that
  once and stops asking)
- An AUR package

## Building from source

```sh
git clone https://github.com/mrogus/Kraken-Redux kraken-redux
cd kraken-redux
./setup.sh
```

`setup.sh` is idempotent: venv with `--system-site-packages` (so it sees your
system PyQt6), installs the app, upgrades liquidctl if it's too old for your
model, installs a desktop launcher.

**Things that bit me setting this up, in case they bite you too:**

- **A `.venv` copied from another machine is dead weight.** Python venvs
  embed absolute paths to the interpreter. If you moved this checkout from
  another install (different distro, reinstalled OS, whatever), `rm -rf .venv`
  and rerun `setup.sh` — don't try to reuse it.
- **The udev rule from upstream only covers `hidraw`.** The LCD goes over raw
  USB bulk transfer, not HID, so you also need a `usb` rule. And if the
  in-kernel `nzxt_kraken3` driver is bound (check `sensors` / `lm-sensors`),
  liquidctl controls pump/fan curves through **hwmon sysfs files**
  (`pwm*`, `temp*_auto_point*_pwm`) — those aren't device nodes, so udev's
  ACL/`uaccess` mechanism doesn't reach them. You need an explicit
  `RUN+="chmod ..."` rule for that too. `setup.sh` writes all of this for you;
  see `packaging/aur/70-kraken-redux.rules` for the actual rule.
- **Web Integration needs two things, not one:** the `playwright` Python
  package, *and* its headless Chromium (`python -m playwright install
  chromium`, a ~300MB download pip/pacman can't manage for you). The LCD page
  now shows an in-app warning telling you which one is missing instead of
  the mode silently doing nothing.
- **If you migrate to a new machine**, the udev rule and any distro-specific
  fixes need reapplying — they live in `/etc`, not in this checkout.

## AUR

```sh
git clone https://aur.archlinux.org/kraken-redux.git
cd kraken-redux
makepkg -si
```

Or use an AUR helper: `yay -S kraken-redux` / `paru -S kraken-redux`. Source:
[`packaging/aur/PKGBUILD`](packaging/aur/PKGBUILD).

## Don't forget to check

- **`sensors` / `lm-sensors`** shows your Kraken as an hwmon chip
  (`kraken2023elite`, `kraken2024elite`, ...) if the kernel driver picked it
  up. If it's missing, cooling curves silently do nothing.
- **udev rule applied**: `getfacl -p /dev/hidrawN` on your Kraken's node
  should show `user:<you>:rw-`, and `ls -l /sys/class/hwmon/hwmonN/pwm1`
  should be writable. No replug/reboot needed — `udevadm trigger`
  re-synthesizes add events for already-connected devices.
- **`--debug` first** if anything looks wrong. Most failures (permissions,
  missing Playwright, a wedged LCD) log a clear reason.
- **Config lives in `~/.config/openkraken/`** (kept at the old path on
  purpose so upgrading from OpenKraken doesn't lose your settings).

## Web integrations

NZXT CAM on Windows can render third-party "web integrations" to the LCD —
small web apps that show custom dashboards, aviation instruments, etc. This
fork implements the same thing on Linux: a headless Chromium (via Playwright)
renders the page and streams it to the panel.

Browse existing ones here: [NZXT web-integrations-examples community
list](https://github.com/NZXTCorp/web-integrations-examples/blob/main/community.md).
Add one from the LCD page (Web Integration mode → Add… → paste its URL).

**Writing your own:** it's a normal web page. NZXT's runtime injects
`window.nzxt.v1` before your page loads (`{ width, height, shape, targetFps }`)
and your page calls:

```js
window.nzxt.v1.onMonitoringDataUpdate((data) => {
  // data.cpus[0].temperature, data.cpus[0].load (0..1), ...
  // data.gpus[0], data.ram.inUse/totalSize, data.kraken.liquidTemperature/fanSpeed/pumpSpeed
});
```

Your page must only render its dashboard when the URL has `?kraken=1` (that's
how CAM/this app distinguishes the LCD display from a settings page). See
`openkraken/backend/web_render.py` (`build_monitoring_data`) for the exact
field shapes this app fills in.

## Not affiliated with NZXT

Independent, community project. "Kraken" is used descriptively for hardware
interoperability only.
