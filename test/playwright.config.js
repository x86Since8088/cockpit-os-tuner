// Playwright config for the System Tuner E2E tests.
// Target a LIVE Cockpit; the cert is self-signed on the default localhost
// target, so TLS errors are ignored for it. Override the target with
// TUNER_BASE_URL when running against another host.
const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
    testDir: '.',
    timeout: 60000,
    workers: 1,           // one live Cockpit + shared kernel state -> serial
    retries: 0,
    reporter: [['list']],
    use: {
        baseURL: process.env.TUNER_BASE_URL || 'https://localhost:9090',
        ignoreHTTPSErrors: true,
        screenshot: 'only-on-failure',
        trace: 'retain-on-failure',
    },
    outputDir: './.artifacts',
});
