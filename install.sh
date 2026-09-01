#!/usr/bin/env bash
#
# install.sh - install the cockpit-tuner plugin (System Tuner).
#
# Usage:
#   sudo ./install.sh                 # install to /usr/share/cockpit/tuner
#   sudo ./install.sh --uninstall     # remove it again
#   ./install.sh --user               # install for the current user only,
#                                     #   into ~/.local/share/cockpit/tuner
#   ./install.sh --user --with-timer  # also install + enable the hourly
#                                     #   change-only snapshot user timer
#   DESTDIR=/tmp/stage ./install.sh   # stage into a package build root
#
# The plugin is plain HTML/CSS/JS plus a python3 snapshot script. There is
# no build step and no dependency on node, npm or a bundler. The plugin is
# read-only by design: it never runs with superuser and writes only snapshot
# files under ~/.local/share/cockpit-tuner/history/.

set -Eeuo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NAME="tuner"
MODE="system"
ACTION="install"
WITH_TIMER=0

PAYLOAD=(manifest.json index.html app.js adapter.js tuner.css schemas.json profiles.json README.md)

usage() { sed -n '2,18p' "$0" | sed 's/^# \?//'; exit "${1:-0}"; }

while (($#)); do
    case "$1" in
        --user)       MODE="user"; shift ;;
        --system)     MODE="system"; shift ;;
        --uninstall)  ACTION="uninstall"; shift ;;
        --with-timer) WITH_TIMER=1; shift ;;
        -h|--help)    usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

if [[ "$MODE" == "user" ]]; then
    BASE="${XDG_DATA_HOME:-$HOME/.local/share}/cockpit"
else
    BASE="${DESTDIR:-}/usr/share/cockpit"
fi
TARGET="$BASE/$NAME"
# $HOME can be unset when a system install runs from a batch/job context.
UNIT_DIR="${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/systemd/user"

if [[ "$ACTION" == "uninstall" ]]; then
    if [[ "$MODE" == "user" ]]; then
        systemctl --user disable --now cockpit-tuner-snapshot.timer 2>/dev/null || true
        rm -f -- "$UNIT_DIR/cockpit-tuner-snapshot.service" "$UNIT_DIR/cockpit-tuner-snapshot.timer"
        systemctl --user daemon-reload 2>/dev/null || true
    fi
    if [[ -L "$TARGET" || -d "$TARGET" ]]; then
        rm -rf -- "$TARGET"
        echo "removed $TARGET"
    else
        echo "nothing to remove at $TARGET"
    fi
    echo "note: snapshot history in ~/.local/share/cockpit-tuner/ is kept"
    exit 0
fi

# --- pre-flight -----------------------------------------------------------

for f in "${PAYLOAD[@]}" bin/tuner-snapshot.py; do
    [[ -f "$SRC/$f" ]] || { echo "missing source file: $SRC/$f" >&2; exit 1; }
done

# A malformed manifest or schema makes Cockpit (or the snapshot service)
# fail silently. Fail here instead.
if command -v python3 >/dev/null 2>&1; then
    for j in manifest.json schemas.json profiles.json; do
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SRC/$j" \
            || { echo "$j is not valid JSON" >&2; exit 1; }
    done
    python3 -m py_compile "$SRC/bin/tuner-snapshot.py" \
        || { echo "bin/tuner-snapshot.py does not compile" >&2; exit 1; }
else
    echo "note: python3 not available, skipping JSON/py validation" >&2
fi

if [[ "$MODE" == "system" && -z "${DESTDIR:-}" && "$(id -u)" != "0" ]]; then
    echo "a system-wide install needs root; re-run with sudo, or use --user" >&2
    exit 1
fi

# --- install --------------------------------------------------------------

# An earlier development setup symlinked the target at the working tree;
# replace a symlink with a real installed directory.
if [[ -L "$TARGET" ]]; then
    echo "replacing existing symlink $TARGET -> $(readlink "$TARGET")"
    rm -f -- "$TARGET"
fi

install -d -m 0755 "$TARGET" "$TARGET/bin"
for f in "${PAYLOAD[@]}"; do
    install -m 0644 "$SRC/$f" "$TARGET/$f"
done
install -m 0755 "$SRC/bin/tuner-snapshot.py" "$TARGET/bin/tuner-snapshot.py"

# Remove files from older versions that are no longer part of the payload.
while IFS= read -r -d '' stale; do
    base="$(basename "$stale")"
    keep=0
    for f in "${PAYLOAD[@]}"; do
        [[ "$base" == "$f" ]] && keep=1 && break
    done
    ((keep)) || { rm -f -- "$stale"; echo "removed stale file $base"; }
done < <(find "$TARGET" -maxdepth 1 -type f -print0)

echo "installed to $TARGET"

# --- snapshot timer (user mode only) --------------------------------------

if ((WITH_TIMER)); then
    if [[ "$MODE" != "user" ]]; then
        echo "--with-timer is a per-user feature; run with --user" >&2
        exit 1
    fi
    install -d -m 0755 "$UNIT_DIR"
    sed "s|@SNAPSHOT@|$TARGET/bin/tuner-snapshot.py|" \
        "$SRC/systemd/cockpit-tuner-snapshot.service.in" \
        > "$UNIT_DIR/cockpit-tuner-snapshot.service"
    install -m 0644 "$SRC/systemd/cockpit-tuner-snapshot.timer" \
        "$UNIT_DIR/cockpit-tuner-snapshot.timer"
    systemctl --user daemon-reload
    systemctl --user enable --now cockpit-tuner-snapshot.timer
    echo "hourly snapshot timer enabled ($(systemctl --user is-active cockpit-tuner-snapshot.timer))"
fi

cat <<'NOTE'

Cockpit picks the package up on the next page load; a hard reload
(Ctrl-Shift-R) clears the browser's cached manifest list. Restarting
cockpit.service is not required.

The page appears in the Cockpit navigation as "System Tuner".
NOTE
