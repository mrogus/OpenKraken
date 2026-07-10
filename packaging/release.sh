#!/usr/bin/env bash
#
# release.sh — cut a Kraken-Redux release.
#
# Usage:
#   packaging/release.sh patch|minor|major     # bump from the current version
#   packaging/release.sh X.Y.Z                  # set an explicit version
#   packaging/release.sh --print                # just print the current version
#
# Steps it performs:
#   1. compute the new version and write it to pyproject.toml + openkraken/__init__.py
#   2. commit "Release vX.Y.Z" and create an annotated tag vX.Y.Z
#   3. push the branch and the tag
#   4. create a GitHub release for the tag (needs `gh`)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
INIT_PY="$ROOT/openkraken/__init__.py"
PYPROJECT="$ROOT/pyproject.toml"

err() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;35m==>\033[0m %s\n' "$*"; }

current_version() {
    grep -oP '^__version__\s*=\s*"\K[0-9]+\.[0-9]+\.[0-9]+' "$INIT_PY"
}

[ -f "$INIT_PY" ] || err "cannot find $INIT_PY (run from the repo)"
CUR="$(current_version)" || err "could not read current version"

if [ "${1:-}" = "--print" ]; then echo "$CUR"; exit 0; fi
[ $# -eq 1 ] || err "usage: release.sh patch|minor|major|X.Y.Z|--print"

case "$1" in
    major|minor|patch)
        IFS=. read -r MA MI PA <<<"$CUR"
        case "$1" in
            major) MA=$((MA + 1)); MI=0; PA=0 ;;
            minor) MI=$((MI + 1)); PA=0 ;;
            patch) PA=$((PA + 1)) ;;
        esac
        NEW="$MA.$MI.$PA"
        ;;
    [0-9]*.[0-9]*.[0-9]*) NEW="$1" ;;
    *) err "invalid version/bump: $1" ;;
esac

info "Releasing v$NEW (was v$CUR)"

# --- preflight ---------------------------------------------------------------
[ -z "$(git -C "$ROOT" status --porcelain)" ] || err "working tree is dirty; commit or stash first"
git -C "$ROOT" rev-parse "v$NEW" >/dev/null 2>&1 && err "tag v$NEW already exists"

# --- 1. write the new version ------------------------------------------------
sed -i -E "s/^__version__ = \"[0-9.]+\"/__version__ = \"$NEW\"/" "$INIT_PY"
sed -i -E "0,/^version = \"[0-9.]+\"/s//version = \"$NEW\"/" "$PYPROJECT"
info "version bumped in __init__.py + pyproject.toml"

# --- 2. commit + tag ---------------------------------------------------------
git -C "$ROOT" add openkraken/__init__.py pyproject.toml
git -C "$ROOT" commit -q -m "Release v$NEW"
git -C "$ROOT" tag -a "v$NEW" -m "Kraken-Redux v$NEW"
info "committed and tagged v$NEW"

# --- 3. push -----------------------------------------------------------------
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
git -C "$ROOT" push origin "$BRANCH"
git -C "$ROOT" push origin "v$NEW"
info "pushed $BRANCH and tag v$NEW"

# --- 4. GitHub release -------------------------------------------------------
if command -v gh >/dev/null 2>&1; then
    info "creating GitHub release v$NEW"
    if ! gh release view "v$NEW" >/dev/null 2>&1; then
        gh release create "v$NEW" \
            --title "Kraken-Redux v$NEW" \
            --generate-notes
    fi
    info "GitHub release v$NEW ready"
else
    info "gh not found — tag pushed; create the GitHub release manually if needed."
fi

info "Done: v$NEW released."
