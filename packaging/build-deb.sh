#!/usr/bin/env bash
#
# build-deb.sh — build a self-contained kraken-redux_<version>_amd64.deb.
#
# Layout produced inside the package:
#   /usr/lib/kraken-redux/openkraken/      the Python package, copied from source
#   /usr/lib/kraken-redux/vendor/          liquidctl>=1.15 + deps (pip --target)
#   /usr/bin/kraken-redux                  launcher (adds both dirs to sys.path)
#   /usr/share/applications/kraken-redux.desktop
#   /usr/share/icons/hicolor/scalable/apps/kraken-redux.svg
#   /usr/lib/udev/rules.d/70-kraken-redux.rules
#   /usr/share/doc/kraken-redux/{README.md,PROTOCOL.md,copyright}
#
# PyQt6 and Pillow are NOT vendored: they come from the distribution
# (Depends: python3-pyqt6, python3-pil). Only liquidctl (which a Debian/Ubuntu
# stable release may lack at >=1.15 with Kraken 2024 support) is bundled.
#
set -euo pipefail

# --- locate ourselves and the project root ---------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"

PKG_NAME="kraken-redux"
ARCH="amd64"
LIQUIDCTL_SPEC="liquidctl>=1.15"

DIST_DIR="$SCRIPT_DIR/dist"
BUILD_ROOT="$SCRIPT_DIR/build"

# --- pretty progress --------------------------------------------------------
step() { printf '\n\033[1;35m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- sanity checks ----------------------------------------------------------
command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb not found (install the 'dpkg' package)"
command -v python3  >/dev/null 2>&1 || die "python3 not found"
[[ -f "$PROJECT_ROOT/pyproject.toml" ]] || die "pyproject.toml not found at $PROJECT_ROOT"
[[ -d "$PROJECT_ROOT/openkraken"     ]] || die "openkraken/ package not found at $PROJECT_ROOT"

# --- read metadata from pyproject.toml --------------------------------------
# Parse with Python's stdlib tomllib (3.11+) and fall back to a regex for 3.10.
read_meta() {
    python3 - "$PROJECT_ROOT/pyproject.toml" <<'PY'
import re, sys
path = sys.argv[1]
data = None
try:
    import tomllib
    with open(path, "rb") as fh:
        data = tomllib.load(fh)
except Exception:
    data = None
if data is not None:
    proj = data.get("project", {})
    version = proj.get("version", "")
    description = proj.get("description", "")
else:
    text = open(path, encoding="utf-8").read()
    m = re.search(r'(?m)^\s*version\s*=\s*"([^"]+)"', text)
    version = m.group(1) if m else ""
    m = re.search(r'(?m)^\s*description\s*=\s*"([^"]+)"', text)
    description = m.group(1) if m else ""
print(version)
print(description)
PY
}

mapfile -t _META < <(read_meta)
VERSION="${_META[0]:-}"
DESCRIPTION_SHORT="${_META[1]:-}"
[[ -n "$VERSION" ]] || die "could not read version from pyproject.toml"

# Tagline (first emphasised line of the README) used as the long description.
README_TAGLINE="$(
    python3 - "$PROJECT_ROOT/README.md" <<'PY'
import sys
line = ""
for raw in open(sys.argv[1], encoding="utf-8"):
    s = raw.strip()
    if s.startswith("*") and s.endswith("*") and len(s) > 2:
        line = s.strip("*").strip()
        break
print(line)
PY
)"
[[ -n "$README_TAGLINE" ]] || README_TAGLINE="$DESCRIPTION_SHORT"

DEB_FILE="$DIST_DIR/${PKG_NAME}_${VERSION}_${ARCH}.deb"

step "Building $PKG_NAME $VERSION ($ARCH)"
info "project root : $PROJECT_ROOT"
info "output       : $DEB_FILE"

# --- clean staging ----------------------------------------------------------
step "Preparing staging tree"
rm -rf "$BUILD_ROOT"
PKGROOT="$BUILD_ROOT/pkgroot"
mkdir -p "$DIST_DIR"
mkdir -p "$PKGROOT/DEBIAN"
mkdir -p "$PKGROOT/usr/lib/$PKG_NAME"
mkdir -p "$PKGROOT/usr/bin"
mkdir -p "$PKGROOT/usr/share/applications"
mkdir -p "$PKGROOT/usr/share/icons/hicolor/scalable/apps"
mkdir -p "$PKGROOT/usr/lib/udev/rules.d"
mkdir -p "$PKGROOT/usr/share/doc/$PKG_NAME"
info "staged at $PKGROOT"

# --- copy the python package from source ------------------------------------
step "Copying openkraken package from source"
cp -a "$PROJECT_ROOT/openkraken" "$PKGROOT/usr/lib/$PKG_NAME/openkraken"
# Drop caches / compiled artefacts so the package is reproducible and lean.
find "$PKGROOT/usr/lib/$PKG_NAME/openkraken" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$PKGROOT/usr/lib/$PKG_NAME/openkraken" -type f -name '*.py[co]' -delete
info "copied $(find "$PKGROOT/usr/lib/$PKG_NAME/openkraken" -name '*.py' | wc -l) python files"

# --- vendor liquidctl + deps (network pip) ----------------------------------
step "Vendoring $LIQUIDCTL_SPEC and its dependencies (pip --target)"
VENDOR_DIR="$PKGROOT/usr/lib/$PKG_NAME/vendor"
mkdir -p "$VENDOR_DIR"
# --no-compile keeps the tree free of .pyc; we never vendor PyQt6/Pillow (system).
python3 -m pip install \
    --target "$VENDOR_DIR" \
    --no-compile \
    --upgrade \
    "$LIQUIDCTL_SPEC"
# Probe the vendored version BEFORE the cache sweep. Use -B / DONTWRITEBYTECODE
# so this import never re-creates the __pycache__ dirs we are about to delete.
VENDORED_LIQUIDCTL_VER="$(
    PYTHONPATH="$VENDOR_DIR" PYTHONDONTWRITEBYTECODE=1 python3 -B -c \
        'import liquidctl; print(getattr(liquidctl, "__version__", "unknown"))' 2>/dev/null \
        || echo unknown
)"
info "vendored liquidctl version: $VENDORED_LIQUIDCTL_VER"
# Tidy: strip byte-compiled caches so the tree is lean and reproducible.
find "$VENDOR_DIR" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$VENDOR_DIR" -type f -name '*.py[co]' -delete

# --- launcher ---------------------------------------------------------------
step "Writing /usr/bin/$PKG_NAME launcher"
cat >"$PKGROOT/usr/bin/$PKG_NAME" <<'PY'
#!/usr/bin/env python3
"""Kraken-Redux launcher (Debian package).

Puts the packaged code and the vendored third-party deps (liquidctl) on
sys.path, then hands off to openkraken.app:main. PyQt6 and Pillow come from the
distribution's system site-packages (Depends: python3-pyqt6, python3-pil).
"""
import os
import sys

_LIB = "/usr/lib/kraken-redux"
_VENDOR = os.path.join(_LIB, "vendor")
# Prepend so the packaged package and vendored liquidctl win over anything else,
# but after the interpreter's own dirs.
for _p in (_LIB, _VENDOR):
    if _p not in sys.path:
        sys.path.insert(1, _p)

from openkraken.app import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod 755 "$PKGROOT/usr/bin/$PKG_NAME"

# --- desktop entry ----------------------------------------------------------
step "Writing desktop entry, icon, udev rule, docs"
cat >"$PKGROOT/usr/share/applications/$PKG_NAME.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Version=1.0
Name=Kraken-Redux
GenericName=Liquid Cooler Control
Comment=Monitor and control your NZXT Kraken liquid cooler (fork of OpenKraken)
Exec=/usr/bin/kraken-redux
Icon=kraken-redux
Terminal=false
Categories=System;Monitor;
Keywords=nzxt;kraken;cooler;aio;liquid;temperature;fan;pump;lcd;
StartupNotify=true
StartupWMClass=kraken-redux
DESKTOP
chmod 644 "$PKGROOT/usr/share/applications/$PKG_NAME.desktop"

# --- icon -------------------------------------------------------------------
cp -a "$PROJECT_ROOT/openkraken/resources/kraken-redux.svg" \
      "$PKGROOT/usr/share/icons/hicolor/scalable/apps/$PKG_NAME.svg"
chmod 644 "$PKGROOT/usr/share/icons/hicolor/scalable/apps/$PKG_NAME.svg"

# --- udev rule --------------------------------------------------------------
cat >"$PKGROOT/usr/lib/udev/rules.d/70-$PKG_NAME.rules" <<'UDEV'
# Kraken-Redux — non-root access to NZXT devices over raw USB HID.
# Covers the Kraken 2024 Elite RGB (1e71:3012) and all other NZXT (1e71) gear.
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1e71", TAG+="uaccess", MODE="0660", GROUP="plugdev"
UDEV
chmod 644 "$PKGROOT/usr/lib/udev/rules.d/70-$PKG_NAME.rules"

# --- docs -------------------------------------------------------------------
cp -a "$PROJECT_ROOT/README.md"   "$PKGROOT/usr/share/doc/$PKG_NAME/README.md"
cp -a "$PROJECT_ROOT/PROTOCOL.md" "$PKGROOT/usr/share/doc/$PKG_NAME/PROTOCOL.md"
chmod 644 "$PKGROOT/usr/share/doc/$PKG_NAME/README.md" \
          "$PKGROOT/usr/share/doc/$PKG_NAME/PROTOCOL.md"

# Machine-readable copyright (DEP-5 style).
cat >"$PKGROOT/usr/share/doc/$PKG_NAME/copyright" <<'COPYRIGHT'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Kraken-Redux
Source: https://github.com/mrogus/Kraken-Redux
Comment: Fork of OpenKraken (https://github.com/davidboulay/OpenKraken)

Files: *
Copyright: 2026 David Boulay and OpenKraken contributors
Copyright: 2026 Kraken-Redux contributors
License: MIT

Files: usr/lib/kraken-redux/vendor/*
Copyright: liquidctl contributors
License: GPL-3.0+
Comment: Bundled copy of liquidctl (https://github.com/liquidctl/liquidctl)
 and its dependencies, installed unmodified via pip. See each package's own
 *.dist-info/ for the authoritative license of that component.

License: MIT
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 .
 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.
 .
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.

License: GPL-3.0+
 liquidctl is distributed under the terms of the GNU General Public License
 version 3 or (at your option) any later version. On Debian systems the full
 text is in /usr/share/common-licenses/GPL-3.
COPYRIGHT
chmod 644 "$PKGROOT/usr/share/doc/$PKG_NAME/copyright"

# --- control file -----------------------------------------------------------
step "Generating DEBIAN/control"
# Long description: each continuation line is indented by one space (Debian).
INSTALLED_SIZE_KB="$(du -s -k "$PKGROOT/usr" | cut -f1)"
cat >"$PKGROOT/DEBIAN/control" <<CONTROL
Package: $PKG_NAME
Version: $VERSION
Architecture: $ARCH
Maintainer: Kraken-Redux contributors <noreply@github.com>
Installed-Size: $INSTALLED_SIZE_KB
Depends: python3 (>= 3.10), python3-pyqt6, python3-pil
Section: utils
Priority: optional
Homepage: https://github.com/mrogus/Kraken-Redux
Description: $README_TAGLINE
 $DESCRIPTION_SHORT
 .
 Kraken-Redux is a native PyQt6 desktop app. It monitors CPU/GPU/liquid
 temperatures and pump/fan RPM, edits pump and fan curves (which run in the
 cooler's own firmware for liquid-temp curves), drives the round 640x640 LCD
 with live sensor screens, images and GIFs, and controls the RGB lighting.
 .
 A recent build of liquidctl (>= 1.15, with Kraken 2024 support) is bundled,
 so the package works even on distributions whose liquidctl is too old.
 PyQt6 and Pillow are taken from the distribution.
CONTROL

# --- maintainer scripts -----------------------------------------------------
step "Writing maintainer scripts (postinst / postrm)"
cat >"$PKGROOT/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
# postinst — reload udev rules so device access works without a reboot, and
# refresh the desktop database so the launcher shows up immediately.
set -e

if [ "$1" = "configure" ]; then
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules >/dev/null 2>&1 || true
        udevadm trigger >/dev/null 2>&1 || true
    fi
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database >/dev/null 2>&1 || true
    fi
fi

exit 0
POSTINST
chmod 755 "$PKGROOT/DEBIAN/postinst"

cat >"$PKGROOT/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
# postrm — reload udev rules after our rule file is gone, and refresh the
# desktop database so the (now removed) launcher disappears.
set -e

if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules >/dev/null 2>&1 || true
    udevadm trigger >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database >/dev/null 2>&1 || true
fi

exit 0
POSTRM
chmod 755 "$PKGROOT/DEBIAN/postrm"

# --- build the .deb ---------------------------------------------------------
step "Building the .deb with dpkg-deb"
# Root-owned files inside the archive: use fakeroot when available so ownership
# is root:root regardless of who runs the build.
if command -v fakeroot >/dev/null 2>&1; then
    fakeroot dpkg-deb --root-owner-group --build "$PKGROOT" "$DEB_FILE"
else
    dpkg-deb --root-owner-group --build "$PKGROOT" "$DEB_FILE"
fi

step "Done"
info "built: $DEB_FILE"
info "size : $(du -h "$DEB_FILE" | cut -f1)"
printf '%s\n' "$DEB_FILE"
