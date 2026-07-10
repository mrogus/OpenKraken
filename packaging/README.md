# Packaging Kraken-Redux

This directory holds two ways to install [Kraken-Redux](https://github.com/mrogus/Kraken-Redux)
(a fork of [OpenKraken](https://github.com/davidboulay/OpenKraken)):

1. An **AUR package** (`aur/PKGBUILD`) for Arch, CachyOS, Manjaro, and other
   Arch-based distributions.
2. A **universal installer** (`install.sh`) that works on any Linux distribution
   by cloning the source and running the project's own `setup.sh`.

| File            | What it does                                                            |
| --------------- | ----------------------------------------------------------------------- |
| `aur/PKGBUILD`  | Builds the AUR package (`makepkg -si`).                                 |
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

## AUR

```sh
git clone https://aur.archlinux.org/kraken-redux.git
cd kraken-redux
makepkg -si
```

Or an AUR helper: `yay -S kraken-redux` / `paru -S kraken-redux`. See
[aur/PKGBUILD](aur/PKGBUILD).

---

## Which should I use?

- **Arch-based distro (Arch, CachyOS, Manjaro, ...)?** Use the AUR package.
- **Any other distro, or you want the latest source / an editable checkout?**
  Use the `install.sh` one-liner.

Both install the same application; they only differ in how the code and its
dependencies are laid out on disk.
