'use strict';

const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './tests/browser',
  fullyParallel: false,
  retries: 0,
  use: {
    baseURL: 'http://127.0.0.1:4173',
    browserName: 'chromium',
  },
  webServer: {
    command: 'local/serve.sh --port 4173',
    url: 'http://127.0.0.1:4173/dashboard.html',
    reuseExistingServer: false,
  },
});
