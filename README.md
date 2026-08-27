# cockpit-tuner

A read-only Cockpit plugin framework for browsing system-tuning **setting schemas**
and **profiles**, and comparing them against **live**, **persistent**, and
**historical** values on this machine.

## Design

```
cockpit-tuner/
├── manifest.json    Cockpit package manifest (menu entry "System Tuner")
├── index.html       page shell, loaded in Cockpit's sandboxed iframe
├── adapter.js       backend abstraction: CockpitBackend (cockpit-bridge) or
│                    MockBackend (plain browser, canned data + localStorage)
├── app.js           comparison matrix UI, snapshot logic
├── tuner.css        styling (light/dark)
├── schemas.json     DATA: setting definitions (how to read live + persistent)
└── profiles.json    DATA: named recommendation sets (safe / aggressive / …)
```

The framework is **data-driven**: adding a setting or profile means editing the
two JSON files — no code changes.

### Isolation / safety

* Cockpit loads each package in its own sandboxed iframe; a broken plugin cannot
  destabilize cockpit-ws or the bridge — worst case is a broken page.
* v1 is **read-only**: it never runs with superuser and never writes system
  state. The only writes are snapshot JSON files under
  `~/.local/share/cockpit-tuner/history/`.
* Opening `index.html` outside Cockpit (cockpit.js fails to load) automatically
  activates **mock mode** — a banner appears and canned data is served, so the
  UI can be developed and tested in any plain browser without touching Cockpit.

## Schema format (`schemas.json`)

```jsonc
{
  "id": "vm.swappiness",          // unique key; profiles reference it
  "title": "vm.swappiness",
  "description": "…",
  "group": "safe",                // safe | aggressive | tkg | info
  "category": "memory",           // free-form, drives the category filter
  "risk": "low",                  // none | low | medium | high
  "live":       { "type": "procfile", "path": "/proc/sys/vm/swappiness" },
  "persistent": { "type": "sysctl",   "key": "vm.swappiness" },
  "verify": "sysctl vm.swappiness",
  "rollback": "how to undo"
}
```

Live source types: `procfile` (read+trim), `procfile-bracket` (extract the
`[bracketed]` token, e.g. THP), `command` (argv array), `file-regex`
(`path` + `regex`, group 1), `none`. Optional `emptyAs` supplies a display value
when the file/command yields nothing.

Persistent source types: `sysctl` (batched grep across `/etc/sysctl.conf`,
`/etc/sysctl.d/`, `/run/sysctl.d/`, `/usr/lib/sysctl.d/` with sysctl.d
precedence rules — winning file shown next to the value), `file-regex`,
`command`, `none`.

## Profiles (`profiles.json`)

A profile maps setting id → recommended value (compared as trimmed strings
against the live value). Shipped profiles: `ubuntu-defaults`,
`stability-safe`, `stability-aggressive`.

## Snapshots (history)

"Take snapshot" captures `{live, persistent}` for every setting into a
timestamped JSON file under `~/.local/share/cockpit-tuner/history/` (mock mode:
localStorage). Selecting a snapshot adds a comparison column; values that
changed since the snapshot are highlighted.

**Automatic hourly snapshots**: `bin/tuner-snapshot.py` resolves the same
schemas headlessly and writes a snapshot **only when a value changed** since
the newest existing one (by mtime). It runs from a systemd user timer
(enabled):

```
~/.config/systemd/user/cockpit-tuner-snapshot.{service,timer}   # OnCalendar=hourly
systemctl --user list-timers cockpit-tuner-snapshot.timer        # status
systemctl --user disable --now cockpit-tuner-snapshot.timer      # stop
```

Note: session-dependent values (e.g. `ulimit` soft limits) can differ between
cockpit-bridge snapshots and timer snapshots — both are truthful for their
observer.

## Comparison semantics

| Highlight | Meaning |
|---|---|
| green | live value matches the selected profile |
| red (profile cell) | live value differs from the profile recommendation |
| amber (persistent cell) | drift: live ≠ persistent (change not applied, or not persisted) |
| purple (snapshot cell) | live value changed since the selected snapshot |

## Install

User-level (no root, current setup — symlinked):

```
ln -sfn /home/eddie/Documents/ClaudeSystem/cockpit-tuner ~/.local/share/cockpit/tuner
```

Log out/in to Cockpit at https://localhost:9090 → "System Tuner" in the menu.
System-wide instead: copy the directory to `/usr/share/cockpit/tuner`.
Uninstall: remove the symlink/directory.
