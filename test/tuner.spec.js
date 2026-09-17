// E2E tests for the System Tuner Cockpit plugin.
//
// These run against a LIVE Cockpit (default https://localhost:9090) with the
// tuner package installed, plus two throwaway accounts:
//   TUNER_TEST_USER  (default "cptest")     — non-admin: sees the tuner but
//                                              gets a locked edit box.
//   TUNER_TEST_ADMIN (default "cptestadm")  — in sudo: enables Administrative
//                                              access, edits vm.swappiness
//                                              live-only, verifies against the
//                                              real kernel value, then undoes
//                                              it — the test is self-reverting.
//
// Configuration (all overridable by env; see test/README.md):
//   TUNER_BASE_URL      Cockpit base URL            (playwright.config.js)
//   TUNER_TEST_USER     non-admin username
//   TUNER_TEST_ADMIN    admin (sudo) username
//   TUNER_TEST_PASSDIR  dir holding <user>.pass files (mode 0600), so no
//                       password is ever hardcoded in the repo
//
// The schema-completeness test needs no Cockpit — it reads schemas.json from
// this repo (../schemas.json) directly, so it also runs in plain CI.
const { test, expect } = require('@playwright/test');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

// Repo-relative, never a machine path: schemas.json sits one level up from test/.
const SCHEMAS = path.join(__dirname, '..', 'schemas.json');

const USER = process.env.TUNER_TEST_USER || 'cptest';
const ADMIN = process.env.TUNER_TEST_ADMIN || 'cptestadm';
const PASSDIR = process.env.TUNER_TEST_PASSDIR || '';

function PASS(u) {
    if (!PASSDIR)
        throw new Error(
            'TUNER_TEST_PASSDIR is not set — point it at a directory holding ' +
            `${u}.pass (mode 0600). See test/README.md.`);
    return fs.readFileSync(path.join(PASSDIR, `${u}.pass`), 'utf8').trim();
}

const FRAME_SEL = 'iframe[name="cockpit1:localhost/tuner"]';

function liveSwappiness() {
    return execSync('sysctl -n vm.swappiness').toString().trim();
}

async function login(page, user, pass) {
    await page.goto('/tuner');
    await expect(page.locator('#login-user-input')).toBeVisible({ timeout: 15000 });
    await page.fill('#login-user-input', user);
    await page.fill('#login-password-input', pass);
    await page.click('#login-button');
    await page.waitForSelector(FRAME_SEL, { state: 'attached', timeout: 45000 });
    return page.frameLocator(FRAME_SEL);
}

async function enableAdmin(page, pass) {
    const indicator = page.locator('#super-user-indicator');
    await expect(indicator).toBeVisible({ timeout: 20000 });
    if (/Administrative access/i.test(await indicator.innerText()))
        return;
    await indicator.locator('button').first().click();
    const dialog = page.locator('.pf-v6-c-modal-box, [role="dialog"]').last();
    await dialog.locator('input[type="password"]').fill(pass);
    await dialog.getByRole('button', { name: /Authenticate/i }).click();
    await expect(indicator).toContainText(/Administrative access/i, { timeout: 30000 });
}

test('every setting schema carries default and recommended; editables carry range or choices', () => {
    const doc = JSON.parse(fs.readFileSync(SCHEMAS, 'utf8'));
    expect(doc.settings.length).toBeGreaterThan(20);
    for (const s of doc.settings) {
        expect(s.default, `${s.id} missing default`).toBeTruthy();
        expect(s.recommended, `${s.id} missing recommended`).toBeTruthy();
        if (s.edit)
            expect(Boolean(s.range || s.choices), `${s.id} editable but has neither range nor choices`).toBe(true);
    }
});

test('category chips multi-select (union), and device categories are opt-in', async ({ page }) => {
    const frame = await login(page, USER, PASS(USER));
    await expect(frame.locator('#settings-table')).toBeVisible({ timeout: 30000 });

    const rowIds = () => frame.locator('#settings-body tr[data-id]')
        .evaluateAll((els) => els.map((e) => e.getAttribute('data-id')));
    // Device rows are crawler-generated: disk.*, cpu.*, or net.<iface>.* —
    // but NOT the network sysctls net.core.* / net.ipv4.* (those are settings).
    const isDevice = (id) =>
        /^(disk|cpu)\./.test(id) || (/^net\./.test(id) && !/^net\.(core|ipv4|ipv6|bridge)\./.test(id));

    // Default view: no device rows (device categories are opt-in).
    const def = await rowIds();
    expect(def.some(isDevice)).toBe(false);
    expect(def.length).toBeGreaterThan(10);

    // Multi-select two normal categories -> union of both, nothing else.
    await frame.locator('.cat-chip[data-cat="oom"]').click();
    await frame.locator('.cat-chip[data-cat="network"]').click();
    const union = await rowIds();
    expect(union.some((id) => id.indexOf('oomd') !== -1 || id.indexOf('systemd-oomd') !== -1)).toBe(true);
    expect(union.some((id) => id.indexOf('somaxconn') !== -1)).toBe(true);
    expect(union.length).toBeLessThan(def.length); // filtered, not everything

    // Clear, then a device category shows only its rows.
    await frame.locator('.cat-chip[data-cat="oom"]').click();
    await frame.locator('.cat-chip[data-cat="network"]').click();
    await expect(frame.locator('.cat-divider')).toBeVisible(); // "devices:" separator
    const devChip = frame.locator('.cat-chip.dev').first();
    const devCat = await devChip.getAttribute('data-cat');
    await devChip.click();
    const devRows = await rowIds();
    expect(devRows.length).toBeGreaterThan(0);
    expect(devRows.every(isDevice)).toBe(true);
    console.log(`device category ${devCat}: ${devRows.length} rows`);
});

test('grouped mode pins selected settings to the top and holds them while browsing snapshots', async ({ page }) => {
    const frame = await login(page, USER, PASS(USER));
    await expect(frame.locator('#settings-table')).toBeVisible({ timeout: 30000 });

    // Pin two settings via their star buttons.
    await frame.locator('tr[data-id="vm.swappiness"] .pin-btn').click();
    await frame.locator('tr[data-id="kernel.panic"] .pin-btn').click();
    await expect(frame.locator('tr[data-id="vm.swappiness"] .pin-btn')).toHaveAttribute('aria-pressed', 'true');

    // Pinned region stays hidden until grouped mode is on.
    await expect(frame.locator('#pinned-wrap')).toBeHidden();
    await frame.locator('#group-toggle').check();
    await expect(frame.locator('#pinned-wrap')).toBeVisible();
    await expect(frame.locator('#pinned-body tr[data-id="vm.swappiness"]')).toBeVisible();
    await expect(frame.locator('#pinned-body tr[data-id="kernel.panic"]')).toBeVisible();

    // Take a snapshot, then select it: pinned rows stay put and the snapshot
    // column fills — i.e. you can keep settings on top and scroll snapshots.
    // (the user may already hold history from prior runs, so assert the count
    // grows by one rather than a fixed value.)
    const before = await frame.locator('#snapshot-select option').count();
    await frame.locator('#btn-snapshot').click();
    await expect(frame.locator('#snapshot-select option')).toHaveCount(before + 1, { timeout: 20000 });
    await frame.locator('#snapshot-select').selectOption({ index: 1 }); // newest is first after "— none —"
    await expect(frame.locator('#pinned-body tr[data-id="vm.swappiness"]')).toBeVisible();
    await expect(frame.locator('#pinned-body tr[data-id="vm.swappiness"] td.col-snapshot')).not.toBeEmpty();

    // Clean up local per-viewer state so the pins don't leak into other tests.
    await frame.locator('#pinned-body tr[data-id="vm.swappiness"] .pin-btn').click();
    await frame.locator('#group-toggle').uncheck();
});

test('detail panel docks to the right of the table and closes', async ({ page }) => {
    const frame = await login(page, USER, PASS(USER));
    await expect(frame.locator('#settings-table')).toBeVisible({ timeout: 30000 });

    await frame.locator('tr[data-id="vm.swappiness"]').click();
    const panel = frame.locator('#detail-panel');
    await expect(panel).toBeVisible();

    // Docked (in-flow, sticky) beside the table — not a fixed full-height overlay,
    // and to the right of the scrollable table region.
    const pos = await panel.evaluate((el) => getComputedStyle(el).position);
    expect(pos).toBe('sticky');
    const tableBox = await frame.locator('.table-wrap').boundingBox();
    const panelBox = await panel.boundingBox();
    expect(panelBox.x).toBeGreaterThanOrEqual(tableBox.x + tableBox.width - 2);

    // The profile column is width-capped so long recommendations wrap.
    const profMax = await frame.locator('td.col-profile').first()
        .evaluate((el) => getComputedStyle(el).maxWidth);
    expect(profMax).toBe('420px');

    await frame.locator('#detail-close').click();
    await expect(panel).toBeHidden();
});

test('non-admin user sees the tuner but editing is locked', async ({ page }) => {
    const frame = await login(page, USER, PASS(USER));
    await expect(frame.locator('#settings-table')).toBeVisible({ timeout: 30000 });
    await frame.locator('tr[data-id="vm.swappiness"]').click();
    await expect(frame.locator('#detail-content')).toContainText('Editable with administrative access');
    await expect(frame.locator('#edit-apply')).toHaveCount(0);
    await frame.locator('#btn-undo').click();
    await expect(frame.locator('#detail-content')).toContainText('requires administrative access');
});

test('admin can edit a setting, the kernel value changes, and undo restores it', async ({ page }) => {
    const orig = liveSwappiness();
    const target = String(Number(orig) + 1);

    const frame = await login(page, ADMIN, PASS(ADMIN));
    await enableAdmin(page, PASS(ADMIN));
    await expect(frame.locator('#settings-table')).toBeVisible({ timeout: 30000 });

    // detail panel shows default/recommended/range and a live edit control
    await frame.locator('tr[data-id="vm.swappiness"]').click();
    await expect(frame.locator('#detail-content')).toContainText('Default');
    await expect(frame.locator('#detail-content')).toContainText('Recommended');
    await expect(frame.locator('#edit-value')).toBeVisible({ timeout: 15000 });
    await expect(frame.locator('#edit-persist')).toBeVisible(); // sysctl class offers persist

    // out-of-range value is rejected before anything runs
    await frame.locator('#edit-value').fill('9999');
    await frame.locator('#edit-apply').click();
    await expect(frame.locator('#edit-msg')).toContainText('between 0 and 200');
    expect(liveSwappiness()).toBe(orig);

    // live-only apply (persist deliberately unchecked)
    await frame.locator('#edit-value').fill(target);
    await expect(frame.locator('#edit-preview')).toContainText(`sysctl -w vm.swappiness=${target}`);
    await frame.locator('#edit-apply').click();
    await expect(frame.locator('#edit-msg')).toContainText('Added to undo history', { timeout: 20000 });
    expect(liveSwappiness()).toBe(target); // the real kernel value changed
    await expect(frame.locator('tr[data-id="vm.swappiness"] td.col-live')).toHaveText(target);

    // undo history holds the edit and restores the previous value
    await frame.locator('#btn-undo').click();
    await expect(frame.locator('#detail-content')).toContainText(`${orig} → ${target}`);
    await frame.locator('button[data-undo]').first().click();
    await expect(frame.locator('tr[data-id="vm.swappiness"] td.col-live')).toHaveText(orig, { timeout: 20000 });
    expect(liveSwappiness()).toBe(orig); // system state restored

    // the journal remembers the rollback
    await frame.locator('#btn-undo').click();
    await expect(frame.locator('#detail-content')).toContainText('undone');
});
