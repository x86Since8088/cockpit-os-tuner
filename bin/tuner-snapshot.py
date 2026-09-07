#!/usr/bin/env python3
"""Headless snapshot collector for cockpit-tuner.

Resolves every setting in schemas.json (same semantics as the plugin's
app.js resolvers), compares against the most recent snapshot in
~/.local/share/cockpit-tuner/history/, and writes a new snapshot file ONLY
when at least one value changed. Designed to run from a systemd user timer.

Exit codes: 0 = ok (written or unchanged), 1 = error.
"""

import glob
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
SCHEMAS = os.path.join(SCRIPT_DIR, "..", "schemas.json")
HISTORY = os.path.expanduser("~/.local/share/cockpit-tuner/history")

SYSCTL_SOURCES = ["/etc/sysctl.conf", "/etc/sysctl.d/*.conf",
                  "/run/sysctl.d/*.conf", "/usr/lib/sysctl.d/*.conf"]


def read_file(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def run_cmd(argv):
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=15,
                             env={**os.environ, "LC_ALL": "C"})
        return out.stdout
    except (OSError, subprocess.TimeoutExpired):
        return None


def resolve_live(setting):
    src = setting.get("live") or {"type": "none"}
    t = src["type"]
    if t == "none":
        return None
    if t in ("procfile", "procfile-bracket"):
        content = read_file(src["path"])
        if content is None:
            return src.get("emptyAs")
        v = content.strip()
        if t == "procfile-bracket":
            m = re.search(r"\[([^\]]+)\]", v)
            v = m.group(1) if m else v
        return v if v else src.get("emptyAs")
    if t == "command":
        out = run_cmd(src["argv"])
        v = (out or "").strip()
        return v if v else src.get("emptyAs")
    if t == "file-regex":
        return resolve_file_regex(src)
    return None


def resolve_file_regex(src):
    content = read_file(src["path"])
    if content is None:
        return None
    m = re.search(src["regex"], content, re.M)
    if not m:
        return None
    return (m.group(1) if m.groups() else m.group(0)).strip()


def sysctl_persistent_map(settings):
    keys = [s["persistent"]["key"] for s in settings
            if s.get("persistent", {}).get("type") == "sysctl"]
    if not keys:
        return {}
    files = []
    for pattern in SYSCTL_SOURCES:
        files.extend(sorted(glob.glob(pattern)) if "*" in pattern
                     else ([pattern] if os.path.exists(pattern) else []))
    entries = {}
    for path in files:
        content = read_file(path)
        if content is None:
            continue
        for line in content.splitlines():
            m = re.match(r"^\s*([^=#\s]+)\s*=\s*(.*)$", line)
            if m and m.group(1) in keys:
                entries.setdefault(m.group(1), []).append(
                    {"file": path, "value": m.group(2).strip()})
    result = {}
    for key, hits in entries.items():
        # sysctl.d precedence: sort by basename; same basename -> /etc wins
        hits.sort(key=lambda e: (os.path.basename(e["file"]),
                                 e["file"].startswith("/etc/")))
        result[key] = hits[-1]["value"]
    return result


def resolve_persistent(setting, sysctl_map):
    src = setting.get("persistent") or {"type": "none"}
    t = src["type"]
    if t == "none":
        return None
    if t == "sysctl":
        return sysctl_map.get(src["key"])
    if t == "file-regex":
        return resolve_file_regex(src)
    if t == "command":
        out = run_cmd(src["argv"])
        v = (out or "").strip()
        return v if v else None
    return None


def latest_snapshot():
    files = glob.glob(os.path.join(HISTORY, "snapshot-*.json"))
    if not files:
        return None
    newest = max(files, key=os.path.getmtime)
    try:
        with open(newest) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def main():
    with open(SCHEMAS) as f:
        settings = json.load(f)["settings"]

    sysctl_map = sysctl_persistent_map(settings)
    values = {}
    for s in settings:
        values[s["id"]] = {
            "live": resolve_live(s),
            "persistent": resolve_persistent(s, sysctl_map),
        }

    prev = latest_snapshot()
    if prev and prev.get("values") == values:
        print("unchanged since %s — no snapshot written" % prev.get("name"))
        return 0

    os.makedirs(HISTORY, exist_ok=True)
    # UTC, matching the plugin's toISOString()-derived names so files interleave
    stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
    name = "snapshot-" + stamp.replace(":", "-").replace("+00-00", "") + ".json"
    data = {"name": name, "timestamp": stamp, "source": "timer",
            "values": values}
    path = os.path.join(HISTORY, name)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    changed = "initial snapshot" if not prev else "%d value(s) changed" % sum(
        1 for k in values if values[k] != (prev.get("values") or {}).get(k))
    print("wrote %s (%s)" % (path, changed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
