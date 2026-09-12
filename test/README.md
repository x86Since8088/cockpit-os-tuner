# System Tuner — E2E tests

Playwright coverage for the tuner plugin. Six tests:

1. **schema completeness** (no Cockpit needed) — every entry in `../schemas.json`
   carries `default` + `recommended`, and every editable one carries `range`
   or `choices`. This is the executable guard on the schema contract.
2. category chips multi-select (union) with device categories opt-in
3. grouped mode pins selected settings and holds them while browsing snapshots
4. detail panel docks right of the table (sticky, 420px profile cap) and closes
5. non-admin user sees the page but the edit box is locked
6. admin edits `vm.swappiness`, the real kernel value changes, out-of-range is
   rejected, and the undo journal restores it — self-reverting

## Not shipped

This directory is **not** part of the installable package: `install.sh`'s
`PAGE=(…)` manifest lists only the page files, and its sweep removes anything
else from the deployed web root, so `test/` never reaches `/usr/share/cockpit`.

## Running

Needs a live Cockpit with the plugin installed (`deploy.sh`) and two throwaway
accounts — a non-admin and a sudo user — whose passwords live in a directory of
`<user>.pass` files (mode 0600) so nothing is hardcoded here.

```bash
cd source/test
npm install            # @playwright/test
npx playwright install chromium

TUNER_TEST_PASSDIR=/run/user/$(id -u)/tuner-e2e \
TUNER_TEST_USER=cptest TUNER_TEST_ADMIN=cptestadm \
TUNER_BASE_URL=https://localhost:9090 \
  npx playwright test
```

Only test 1 (schema completeness) runs without any of that — it reads the JSON
directly and is safe in plain CI:

```bash
npx playwright test -g "schema carries default"
```

## Env vars

| var | default | meaning |
|---|---|---|
| `TUNER_BASE_URL` | `https://localhost:9090` | Cockpit URL (self-signed cert tolerated) |
| `TUNER_TEST_USER` | `cptest` | non-admin account |
| `TUNER_TEST_ADMIN` | `cptestadm` | sudo account (enables Administrative access) |
| `TUNER_TEST_PASSDIR` | *(required)* | dir holding `<user>.pass` files |

The admin test mutates `vm.swappiness` to `orig+1` then undoes it, so it leaves
the kernel exactly as it found it.
