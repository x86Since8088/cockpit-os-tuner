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

# CODE AND DATA THAT SHIPPED WITH THIS SCRIPT resolve relative to the script.
# schemas.json is part of the payload; it must match the payload this file came
# from, so an upgrade can never pair a new collector with an old schema. This is
# the OPPOSITE rule from configuration below, and the two are different on
# purpose: code must match the payload, config must match the HOST
# (docs/DEPLOY-CONTRACT.md section 4.3, JC-9).
SCHEMAS = os.path.join(SCRIPT_DIR, "..", "schemas.json")

DEFAULT_INSTALL_CONF = "/etc/cockpit-tuner/install.conf"


def load_env(path):
    """The section 4.1 grammar, and nothing wider.

    KEY=value, optional whole-value double quotes, full-line comments only, no
    export, and NO interpolation. A `$` or a backtick in a value is a refusal
    rather than an expansion: a shell would expand it, this parser will not, and
    the day somebody teaches it to is the day command substitution becomes a
    code-execution primitive in a config file.
    """
    out = {}
    with open(path, encoding="utf-8") as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                raise ValueError("%s:%d: not KEY=VALUE" % (path, n))
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip()
            if not re.fullmatch(r"[A-Z][A-Z0-9_]*", k):
                raise ValueError("%s:%d: bad key %r" % (path, n, k))
            if len(v) >= 2 and v[0] == v[-1] == '"':
                v = v[1:-1]
            if any(c in v for c in "$`"):
                raise ValueError("%s:%d: %s contains $ or ` - interpolation is not "
                                 "supported (DEPLOY-CONTRACT section 4.1)" % (path, n, k))
            if k in out:
                sys.stderr.write("%s:%d: warning: %s set twice; last wins\n" % (path, n, k))
            out[k] = v
    return out


def _owned_by_me(path):
    try:
        return os.stat(path).st_uid == os.getuid()
    except OSError:
        return False


def env_file():
    """Where this script's configuration lives. Three steps, and no fourth.

    There is deliberately NO "look beside me" step. This file's realpath lands
    in the payload, and a .env beside the payload would be the right answer on a
    deployed host - which is exactly why it must not be implemented, because the
    same line in a dev install lands in the checkout and reads a TEST-ONLY .env.
    The indirection through install.conf is what makes dev-versus-deployed a
    fact recorded at install time instead of a coincidence of where a file sits.
    """
    # 1. The test seam. Non-root only, and only a file the caller owns: an
    #    environment variable that redirects a privileged process's
    #    configuration is an escalation, whether or not the file holds secrets.
    override = os.environ.get("TUNER_ENV")
    if override:
        if os.geteuid() == 0:
            sys.stderr.write("tuner-snapshot: ignoring TUNER_ENV (running as root)\n")
        elif not _owned_by_me(override):
            sys.stderr.write("tuner-snapshot: ignoring TUNER_ENV (not owned by uid %d)\n"
                             % os.getuid())
        else:
            return override

    # 2. install.conf. The normal path, and the only one on a production host.
    conf = DEFAULT_INSTALL_CONF
    from_env = os.environ.get("TUNER_INSTALL_CONF")
    if from_env and os.geteuid() != 0:
        conf = from_env
    if os.path.isfile(conf):
        got = load_env(conf).get("ENV_FILE")
        if got:
            return got

    # 3. Nothing. Fail loudly, and name the file.
    sys.exit("tuner-snapshot: no configuration. %s does not exist or does not set\n"
             "  ENV_FILE=. Run install.sh, which writes it. For a dev run, point\n"
             "  TUNER_ENV at a .env you own." % conf)


def history_dir():
    env = load_env(env_file())
    d = env.get("TUNER_HISTORY_DIR")
    if not d:
        sys.exit("tuner-snapshot: %s does not set TUNER_HISTORY_DIR." % env_file())
    return os.path.expanduser(d)

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
    files = glob.glob(os.path.join(history_dir(), "snapshot-*.json"))
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

    history = history_dir()
    os.makedirs(history, exist_ok=True)
    # UTC, matching the plugin's toISOString()-derived names so files interleave
    stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
    name = "snapshot-" + stamp.replace(":", "-").replace("+00-00", "") + ".json"
    data = {"name": name, "timestamp": stamp, "source": "timer",
            "values": values}
    path = os.path.join(history, name)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    changed = "initial snapshot" if not prev else "%d value(s) changed" % sum(
        1 for k in values if values[k] != (prev.get("values") or {}).get(k))
    print("wrote %s (%s)" % (path, changed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
