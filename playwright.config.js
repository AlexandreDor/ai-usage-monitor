'use strict';

const { defineConfig } = require('@playwright/test');
const { mkdtempSync, rmSync, writeFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');

// Browser fixtures never need to read configuration or write heartbeats in the
// user's runtime. Each test invocation gets private disposable server state.
const runtime = mkdtempSync(join(tmpdir(), 'codex-browser-tests-'));
const environmentFile = join(runtime, 'test.env');
writeFileSync(environmentFile, '', { mode: 0o600 });
process.on('exit', () => rmSync(runtime, { recursive: true, force: true }));

module.exports = defineConfig({
  testDir: './tests/browser',
  fullyParallel: false,
  preserveOutput: 'always',
  retries: 0,
  use: {
    baseURL: 'http://127.0.0.1:4173',
    browserName: 'chromium',
  },
  webServer: {
    command: 'local/serve.sh --port 4173',
    env: {
      CODEX_MONITOR_ENV_FILE: environmentFile,
      CODEX_MONITOR_RUNTIME_DIR: runtime,
      DASHBOARD_ANALYTICS_DATABASE: join(runtime, 'usage-history.sqlite3'),
    },
    url: 'http://127.0.0.1:4173/dashboard.html',
    reuseExistingServer: false,
  },
});
