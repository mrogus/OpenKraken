# Packaging Kraken-Redux

This directory holds three ways to install [Kraken-Redux](https://github.com/mrogus/Kraken-Redux)
(a fork of [OpenKraken](https://github.com/davidboulay/OpenKraken)):

1. An **AUR package** (`aur/PKGBUILD`) for Arch, CachyOS, Manjaro, and other
   Arch-based distributions.
2. A **Debian package** (`kraken-redux_<version>_amd64.deb`) for Debian, Ubuntu,
   Pop!\_OS, Linux Mint, and other apt-based distributions.
3. A **universal installer** (`install.sh`) that works on any Linux distribution
   by cloning the source and running the project's own `setup.sh`.

| File            | What it does                                                            |
| --------------- | ----------------------------------------------------------------------- |
| `aur/PKGBUILD`  | Builds the AUR package (`makepkg -si`).                                 |
| `build-deb.sh`  | Builds the `.deb` into `dist/` using `dpkg-deb`.                         |
| `install.sh`    | Curl-able installer: clones the repo and runs `setup.sh`.               |

---

## Quick install (any distro)

The fastest path — no build, no clone by hand:

```sh
curl -fsSL https://raw.githubusercontent.com/mrogus/Kraken-Redux/main/packaging/install.sh | bash
```

This:

1. Checks for `git` and `python3` (≥ 3.10), with per-distro hints if anything is
   missing (`apt` / `dnf` / `pacman`).
2. Clones the source into `~/.local/share/openkraken-src` (or `git pull`s an
   existing checkout there).
3. Runs the project's idempotent `setup.sh` (creates a venv, installs the app
   and dependencies, upgrades liquidctl if needed, installs a desktop launcher).

It never needs root. `setup.sh` only *offers* to install a udev rule, and only
when run interactively in a terminal — piping it through `bash` never prompts.

To install into a different directory:

```sh
OPENKRAKEN_SRC_DIR=/opt/openkraken-src bash install.sh
```

---

## Building the Debian package

From this directory (or anywhere — the script locates the project root itself):

```sh
./build-deb.sh
```

The build needs network access (it runs `pip install --target` to vendor
liquidctl). It produces:

```
packaging/dist/kraken-redux_<version>_amd64.deb
```

### What goes in the package

| Path                                               | Contents                                  |
| -------------------------------------------------- | ----------------------------------------- |
| `/usr/lib/kraken-redux/openkraken/`                | The Python package, copied from source.   |
| `/usr/lib/kraken-redux/vendor/`                    | `liquidctl >= 1.15` + its dependencies.   |
| `/usr/bin/kraken-redux`                            | Launcher (adds both dirs to `sys.path`).  |
| `/usr/share/applications/kraken-redux.desktop`     | Application-menu entry.                   |
| `/usr/share/icons/hicolor/scalable/apps/kraken-redux.svg` | App icon.                          |
| `/usr/lib/udev/rules.d/70-kraken-redux.rules`      | Non-root NZXT device access.              |
| `/usr/share/doc/kraken-redux/`                     | `README.md`, `PROTOCOL.md`, `copyright`.  |

**PyQt6 and Pillow are not bundled** — they come from the distribution via the
package `Depends:` (`python3-pyqt6`, `python3-pil`). Only **liquidctl** is
vendored, because Debian/Ubuntu stable releases often ship a version too old to
know the Kraken 2024 Elite RGB (`1e71:3012`).

The package declares:

```
Depends: python3 (>= 3.10), python3-pyqt6, python3-pil
```

The maintainer scripts reload udev rules (`udevadm control --reload-rules &&
udevadm trigger`) and refresh the desktop database (`update-desktop-database`)
on install and removal, so device access and the launcher work without a reboot.

### Inspecting the built package

```sh
dpkg-deb -I packaging/dist/kraken-redux_*_amd64.deb   # control metadata
dpkg-deb -c packaging/dist/kraken-redux_*_amd64.deb   # file listing
lintian   packaging/dist/kraken-redux_*_amd64.deb     # optional lint (if installed)
```

### Installing the `.deb`

```sh
sudo apt install ./packaging/dist/kraken-redux_<version>_amd64.deb
```

Using `apt install ./file.deb` (rather than `dpkg -i`) pulls in the
`python3-pyqt6` / `python3-pil` dependencies automatically. On a plain `dpkg -i`
you may need `sudo apt-get -f install` afterwards to satisfy them.

After install, launch **Kraken-Redux** from the application menu, or run
`kraken-redux` from a terminal. Useful flags:

| Flag           | Effect                                              |
| -------------- | --------------------------------------------------- |
| `--minimized`  | Start hidden (tray if available, else background).  |
| `--config PATH`| Use an alternate config file.                       |
| `--debug`      | Verbose (DEBUG-level) logging.                       |
| `--version`    | Print version and exit.                             |

### Removing the package

```sh
sudo apt remove kraken-redux      # or: sudo dpkg -r kraken-redux
```

Your configuration in `~/.config/openkraken/` is left untouched.

---

## Which should I use?

- **Arch-based distro (Arch, CachyOS, Manjaro, ...)?** Use the AUR package
  (`aur/PKGBUILD`) — see [aur/PKGBUILD](aur/PKGBUILD).
- **apt-based distro and you want a clean, manageable install?** Build and
  install the `.deb`.
- **Any other distro, or you want the latest source / an editable checkout?**
  Use the `install.sh` one-liner.

All three install the same application; they only differ in how the code and
its dependencies are laid out on disk.
