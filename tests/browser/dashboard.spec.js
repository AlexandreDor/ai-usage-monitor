'use strict';

const { test, expect } = require('@playwright/test');
const AxeBuilder = require('@axe-core/playwright').default;

const snapshot = {
  five_h_pct: 72,
  weekly_pct: 36,
  scraped_at: '2026-08-03T17:30:01Z',
  five_h_reset_at: 1785778500,
  weekly_reset_at: 1767443640,
  sample_interval_seconds: 900,
};

async function mockUsage(page, history = [snapshot]) {
  await page.route('**/data.json?*', route => route.fulfill({ json: snapshot }));
  await page.route('**/history.json?*', route => route.fulfill({ json: history }));
}

test('works offline and exposes no critical accessibility violations', async ({ page }) => {
  const externalRequests = [];
  page.on('request', request => {
    if (new URL(request.url()).hostname !== '127.0.0.1') externalRequests.push(request.url());
  });
  await mockUsage(page);
  await page.goto('/dashboard.html');

  await expect(page.locator('#five-h-pct')).toHaveText('72%');
  await expect(page.locator('#weekly-pct')).toHaveText('36%');
  await expect(page.locator('#last-updated')).toHaveText('Last scraped 03/08/2026 19:30');
  await expect(page.locator('#five-h-reset')).toHaveText('03/08/2026 19:35');
  await expect(page.locator('#weekly-reset')).toHaveText('03/01/2026 13:34');
  expect(externalRequests).toEqual([]);

  const results = await new AxeBuilder({ page }).analyze();
  expect(results.violations.filter(violation => violation.impact === 'critical')).toEqual([]);
});

test('keeps metrics visible when Chart.js is unavailable', async ({ page }) => {
  await page.route('**/assets/chart.umd.min.js', route => route.abort());
  await mockUsage(page);
  await page.goto('/dashboard.html');

  await expect(page.locator('#five-h-pct')).toHaveText('72%');
  await expect(page.locator('#history-error')).toContainText('Chart.js failed to load');
  await expect(page.locator('#error-banner')).toBeHidden();
});

test('clears a previous chart when history becomes empty', async ({ page }) => {
  let history = [snapshot];
  await page.route('**/data.json?*', route => route.fulfill({ json: snapshot }));
  await page.route('**/history.json?*', route => route.fulfill({ json: history }));
  await page.goto('/dashboard.html');
  await expect(page.locator('#history-error')).toBeHidden();

  history = [];
  await page.evaluate(() => refresh());
  await expect(page.locator('#history-error')).toContainText('History is empty');
  await expect(page.locator('#history-label')).toHaveText('History unavailable');
});
