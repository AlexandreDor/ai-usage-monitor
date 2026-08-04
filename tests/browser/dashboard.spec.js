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

const analyticsPayload = {
  schema_version: 1,
  period: { range: '30d', from: '2026-07-05T10:00:00Z', to: '2026-08-04T10:00:00Z', timezone: 'Europe/Paris', granularity_seconds: 86400 },
  filters: { sources: [], models: [], reset_type: 'all' },
  available: { sources: ['codex', 'opencode'], models: ['gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna', 'unknown-model'] },
  freshness: { limits_last_sample_at: '2026-08-04T09:45:00Z', collectors: { codex: { status: 'ok', last_success_at: '2026-08-04T09:45:00Z' }, opencode: { status: 'ok', last_success_at: '2026-08-04T09:45:00Z' }, hermes: { status: 'disabled', last_success_at: null } } },
  limits: { samples: 2, series: [{ at: '2026-08-03T00:00:00Z', five_h_pct: 80, weekly_pct: 60 }, { at: '2026-08-04T00:00:00Z', five_h_pct: 55, weekly_pct: 52 }] },
  tokens: {
    summary: { input_tokens: 1000000, cache_read_tokens: 500000, cache_write_tokens: 0, output_tokens: 200000, reasoning_tokens: 50000, events: 2, estimated_cost_usd: 11.25, assumed_zero_tokens: 100 },
    series: [{ at: '2026-08-04T00:00:00Z', input_tokens: 1000000, cache_read_tokens: 500000, cache_write_tokens: 0, output_tokens: 200000, reasoning_tokens: 50000 }],
    breakdown: [{ source: 'codex', provider: 'openai', model: 'gpt-5.6-sol', input_tokens: 1000000, cache_read_tokens: 500000, cache_write_tokens: 0, output_tokens: 200000, estimated_cost_usd: 11.25, pricing_status: 'priced' }],
  },
  resets: { total: 1, weekly_total: 0, offset: 0, limit: 10, items: [{ window: '5h', reset_at: '2026-08-04T08:00:00Z', observed_at: '2026-08-04T08:15:00Z', observation_delay_seconds: 900, before_pct: 4, after_pct: 100 }] },
  baselines: { hermes: [{ tokens: 42 }] },
  pricing: { currency: 'USD', as_of: '2026-08-04', valuation_mode: 'current_catalog' },
  warnings: ['No catalog price; assumed zero: other/unknown-model'],
};

test('renders advanced analytics and remains local', async ({ page }) => {
  const externalRequests = [];
  const analyticsQueries = [];
  page.on('request', request => {
    if (new URL(request.url()).hostname !== '127.0.0.1') externalRequests.push(request.url());
  });
  await page.route('**/api/analytics?*', route => {
    analyticsQueries.push(new URL(route.request().url()).searchParams);
    return route.fulfill({ json: analyticsPayload });
  });
  await page.goto('/analytics.html');

  await expect(page.locator('#total-tokens')).toHaveText('1.7M');
  await expect(page.locator('#estimated-cost')).toHaveText('$11.25');
  await expect(page.locator('#allocation-total-cost')).toHaveText('$11.25');
  await expect(page.locator('#reset-count')).toHaveText('0');
  await expect(page.locator('#breakdown-body')).toContainText('gpt-5.6-sol');
  await expect(page.locator('#analytics-warnings')).toContainText('assumed zero');
  await expect(page.locator('#model-filter input')).toHaveCount(4);
  await page.getByRole('button', { name: 'GPT 5.6' }).click();
  await expect.poll(() => analyticsQueries.at(-1)?.get('models')).toBe('gpt-5.6-sol,gpt-5.6-terra,gpt-5.6-luna');
  await page.locator('#source-filter input[value="codex"]').uncheck();
  await expect.poll(() => analyticsQueries.at(-1)?.get('sources')).toBe('opencode,hermes');
  expect(externalRequests).toEqual([]);

  const results = await new AxeBuilder({ page }).analyze();
  expect(results.violations.filter(violation => violation.impact === 'critical')).toEqual([]);
});
