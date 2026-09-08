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
* Without administrative access the page is **read-only** (locked edit box).
  With it, settings whose schema has an `edit` descriptor can be applied;
  every apply is journaled to root-owned `/var/lib/cockpit-tuner/undo.jsonl`
  and is revertible from the Undo history panel. Snapshots still land in
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

## Installing and deploying

There are **two processes** and they are not the same thing. `cockpit-tuner` is
the smallest plugin in this tree, which makes it the one to read first — and the
one to copy when writing plugin number seven. Both scripts are governed by
`docs/DEPLOY-CONTRACT.md` in `cockpit-secrets`.

| | `install.sh` | `deploy.sh` / `deploy.ps1` / `deploy.bat` |
|---|---|---|
| What it is | An in-place install **by symlink**, from wherever it is run | The real deployment: a copy, then config, then `install.sh` |
| Moves bytes? | **No.** It links; it never copies the payload | Yes. It is the only thing that copies |
| Run from | The payload — dev checkout *or* install path | The dev checkout |
| Owns units? | Renders and places them. Never enables or starts | Enables, behind an explicit flag |
| Owns `.env`? | No. Reads it, refuses if a required key is missing | Yes. Seeds it from `.envdefault`, **missing-only** |

**The single idea:** the script is the same; only where it is run from differs.

```bash
# A DEV install - the page becomes symlinks into this checkout, so editing
# app.js changes what the browser loads on the next reload.
cp .envdefault .env          # TEST-ONLY, gitignored; see the header in .envdefault
sudo ./install.sh

# A DEPLOYED install - self-sustaining, no relationship to the share.
sudo ./deploy.sh                        # -> /opt/cockpit-tuner
sudo ./deploy.sh --with-timer           # ... and place the snapshot units
sudo ./deploy.sh --install-to /srv/x    # somewhere else, absolute
sudo ./deploy.sh --verify               # the standing checks, then stop
```

**The acceptance test:** after `deploy.sh`, unmount the dev share and this host
keeps working. A dev install is deliberately the opposite — it *is* the share.

### Which install is this?

```bash
readlink -f /usr/share/cockpit/tuner/index.html
grep INSTALL_KIND /etc/cockpit-tuner/install.conf
```

Every plugin on the host at once. It reads each plugin's own `install.conf`
rather than pattern-matching a path, so it needs no dev-root literal — and a
README is a shipped artifact, which the standing ban forbids from carrying one:

```bash
for d in /usr/share/cockpit/*/; do
    n=${d%/}; n=${n##*/}
    t=$(readlink -f "$d/index.html" 2>/dev/null) || continue
    k=$(sed -n 's/^INSTALL_KIND=//p' "/etc/cockpit-$n/install.conf" 2>/dev/null)
    printf '%-12s %-9s %s\n' "$n" "${k:-unknown}" "$t"
done
```

`INSTALL_KIND` is the authoritative answer because `install.sh` writes it on
every run. The `readlink` above it is the fallback for when there is no time to
read a file: a target under `/opt` is a deployed install, and a target anywhere
else is not.

### The layout a deploy produces

```
/opt/cockpit-tuner/
├── payload -> payload-1.0.0        the swap point: one rename(2), safe against a live Cockpit
├── payload-1.0.0/                  immutable once written; nothing writes inside it
│   ├── index.html  *.js  *.css  *.json    the page files
│   ├── bin/                        tuner-snapshot.py, tuner-crawl.py — run by the unit, served to nobody
│   ├── systemd/                    *.service.in, *.timer
│   ├── install.sh  VERSION  .envdefault
├── .env                            OPERATOR CONFIG — a SIBLING of payload, never replaced
└── payload-0.9.0/                  the previous version, kept for rollback
```

`.env` is a **sibling** of `payload`, not a child. That is the only way "seed
`.env` in the install path" and "an upgrade never touches operator config" can
both be true. Rollback needs no share and no network:

```bash
cd /opt/cockpit-tuner
ln -sfn payload-0.9.0 payload.new && mv -T payload.new payload && payload/install.sh
```

State lives in `/var/lib/cockpit-tuner` (the root-owned undo journal) and in each
user's `~/.local/share/cockpit-tuner/history`. Neither is under the install path,
because an upgrade replaces the payload wholesale — and because backup policy,
logrotate and `restorecon` already know `/var`.

### The snapshot timer

It is a systemd **user** timer: snapshots are one operator's view of one machine,
and root has no business reaching into somebody's home. `install.sh` renders and
places it; **it never enables it**, and neither does `deploy.sh` — root cannot
enable a user timer for somebody else. In the session that should collect them:

```bash
systemctl --user enable --now cockpit-tuner-snapshot.timer
```

### Conformance to DEPLOY-CONTRACT

Verified 2026-09-07 against a staged install under a temp dir, with `DESTDIR=`
set so nothing touched the live host.

| Area | Status |
|---|---|
| §1 Deploys to `/opt/cockpit-tuner`; `payload-<version>/` + `payload` symlink; `.env` a sibling | yes |
| §1.4 State in `/var/lib`, nothing runtime-writable inside the payload | yes |
| §2.1 Per-file symlinks into a real `/usr/share/cockpit/tuner` | yes |
| §2.2 Refuses a destination it does not own | yes |
| §2.4 No `rm -r` in `install.sh` at all; `deploy.sh` only in `remove_old_payload` | yes |
| §3.1 `readlink -f` then `dirname`; classification records only | yes |
| §3.3 Writes `/etc/cockpit-tuner/install.conf` | yes |
| §4.1 `.envdefault` in the one grammar; no interpolation | yes |
| §4.2 Seeded missing-only; secret-shaped values refused | yes |
| §4.3 `bin/tuner-snapshot.py` resolves `.env` only via `install.conf`; no "beside me" step | yes |
| §5 No `etcdefaults/` — this plugin manages no system data files | n/a |
| §6.1 `install.sh` renders and places units; never enables, starts or stops | yes |
| §6.2 `@PLACEHOLDER@` templates; a survivor is a refusal | yes |
| §6.1 Neither script touches `cockpit.socket` | yes |
| §7.1 One declaration, read by `deploy.sh`, `deploy.ps1` and `validate.sh` | yes |
| §7.2 Pre-flight refusals 1, 2, 2b, 3, 5, 6, 7, 8, 9 present and proven to fire | yes |
| §7.3 Post-install assertion on what was produced | yes |
| §9 No deployed artifact names a dev-tree or retired path | yes — see note |

**The one note.** `payload/install.sh` contains the dev-root path as a literal.
§3.1 *requires* it: that constant is how the script classifies the install and
how `--uninstall` knows to tell an operator running against a dev host that their
checkout is not being touched. The standing ban is therefore scoped to shipped
**artifacts** — the page files, the payload scripts, the units and `.envdefault` —
exactly as §7.2 check 9 scopes it. `install.sh` is the installer's own knowledge
of where a dev tree lives, not a dead path carried into production.
