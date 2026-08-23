'use strict';

const { test, expect } = require('@playwright/test');
const AxeBuilder = require('@axe-core/playwright').default;

const DASHBOARD_NOW = new Date('2026-08-03T17:30:31Z');

function expectNoAxeViolations(results, impacts = ['critical']) {
  expect(results.violations.filter(({ impact }) => impacts.includes(impact))).toEqual([]);
}

const snapshot = {
  five_h_pct: 72,
  weekly_pct: 36,
  scraped_at: '2026-08-03T17:30:01Z',
  five_h_reset_at: 1785778500,
  weekly_reset_at: 1767443640,
  sample_interval_seconds: 900,
  codex_forecast: {
    chance_24h_pct: 76,
    chance_6h_pct: 10,
    generated_at: '2026-08-03T17:30:01Z',
  },
};

async function mockUsage(page, history = [snapshot]) {
  await page.clock.install({ time: DASHBOARD_NOW });
  await page.route('**/api/dashboard-heartbeat', route => route.fulfill({ status: 204 }));
  await page.route('**/data.json?*', route => route.fulfill({ json: snapshot }));
  await page.route('**/history.json?*', route => route.fulfill({ json: history }));
}

test('signals visible local dashboard activity without affecting rendering', async ({ page }) => {
  await page.clock.install({ time: DASHBOARD_NOW });
  const heartbeats = [];
  await page.route('**/api/dashboard-heartbeat', route => {
    heartbeats.push({
      method: route.request().method(),
      header: route.request().headers()['x-codex-dashboard-activity'],
      body: route.request().postData(),
    });
    return route.fulfill({
      status: 204,
      headers: { 'X-Codex-Dashboard-Interval-Seconds': '120' },
    });
  });
  await page.route('**/data.json?*', route => route.fulfill({ json: snapshot }));
  await page.route('**/history.json?*', route => route.fulfill({ json: [snapshot] }));
  await page.goto('/dashboard.html');

  await expect.poll(() => heartbeats.length).toBe(1);
  expect(heartbeats[0]).toEqual({ method: 'POST', header: 'visible', body: null });
  await expect.poll(() => page.evaluate(() => dashboardActiveIntervalMs)).toBe(120000);
  await expect(page.locator('#five-h-pct')).toHaveText('72%');
  await expect(page.locator('#mode-badge')).toBeHidden();
  await expect(page.locator('#mode-badge')).toHaveText('');
  await expect(page.locator('#freshness-status')).toContainText('FRESH');
  await expect(page.locator('body')).toHaveAttribute('data-dashboard-source', 'local');
  await expect(page.locator('body')).toHaveAttribute('data-freshness', 'fresh');
  await expect(page.locator('#error-banner')).toBeHidden();
});

test('works offline and exposes no serious or critical accessibility violations', async ({ page }) => {
  const externalRequests = [];
  page.on('request', request => {
    if (new URL(request.url()).hostname !== '127.0.0.1') externalRequests.push(request.url());
  });
  await mockUsage(page);
  await page.goto('/dashboard.html');

  await expect(page.locator('#five-h-pct')).toHaveText('72%');
  await expect(page.locator('#weekly-pct')).toHaveText('36%');
  await expect(page.locator('#five-hour-title')).toHaveText('5-Hour Limit');
  await expect(page.locator('#weekly-title')).toHaveText('Weekly Limit');
  await expect(page.locator('.limit-card').first()).toHaveAttribute('aria-labelledby', 'five-hour-title');
  await expect(page.locator('.limit-card').last()).toHaveAttribute('aria-labelledby', 'weekly-title');
  await expect(page.locator('#five-h-bar')).toHaveAttribute('aria-label', '5-hour remaining quota');
  await expect(page.locator('#five-h-bar')).toHaveAttribute('aria-valuetext', '72% remaining');
  await expect(page.locator('#weekly-bar')).toHaveAttribute('aria-label', 'Weekly remaining quota');
  await expect(page.locator('#weekly-bar')).toHaveAttribute('aria-valuetext', '36% remaining');
  await expect(page.locator('#weekly-pace-actual')).toHaveText('Actual remaining: 36%');
  await expect(page.locator('#weekly-pace-ideal')).toHaveText('Ideal remaining: Unavailable');
  await expect(page.locator('#weekly-pace-delta')).toHaveText('Weekly pace unavailable');
  await expect(page.locator('#freshness-status')).toHaveAttribute('role', 'status');
  await expect(page.locator('#freshness-status')).toHaveAttribute('aria-live', 'polite');
  await expect(page.locator('#freshness-status')).toHaveAttribute('aria-atomic', 'true');
  await expect(page.locator('#freshness-status')).toHaveText('FRESH less than a minute');
  await expect(page.locator('#freshness-badge')).toHaveText('FRESH');
  await expect(page.locator('#freshness-badge')).toHaveClass(/badge/);
  await expect(page.locator('#freshness-badge')).toBeVisible();
  await expect(page.locator('#freshness-detail')).toHaveText('less than a minute');
  await expect(page.locator('#last-updated')).toHaveText('Last scraped 03/08/2026 19:30');
  await expect(page.locator('#five-h-reset')).toHaveText('03/08/2026 19:35');
  await expect(page.locator('#weekly-reset')).toHaveText('03/01/2026 13:34');
  await expect(page.locator('#forecast-24h')).toHaveText('76%');
  await expect(page.locator('#forecast-6h')).toHaveText('10%');
  await expect(page.locator('#forecast-24h')).toHaveClass(/threshold-reached/);
  await expect(page.locator('#forecast-24h')).toHaveAttribute('title', 'Highlight threshold reached: 50%');
  await expect(page.locator('.forecast-link')).toHaveAttribute('href', 'https://codex.lunarwerx.com/');
  await expect(page.locator('.forecast-link')).toHaveAttribute('target', '_blank');
  await expect(page.locator('.forecast-link')).toHaveAttribute('rel', 'noopener noreferrer');
  await expect(page.locator('.dashboard-links .external-link')).toHaveAttribute('href', 'https://github.com/AlexandreDor/ai-usage-monitor');
  await expect(page.locator('.dashboard-links a').first()).toHaveAttribute('href', 'https://github.com/AlexandreDor/ai-usage-monitor');
  await expect(page.locator('.dashboard-links a').last()).toHaveAttribute('href', 'analytics.html');
  await expect(page.locator('#history-summary')).toContainText('1 sample from');
  await expect(page.locator('#history-table-body tr')).toHaveCount(1);
  await expect(page.locator('#history-chart')).toHaveAttribute('role', 'img');
  await expect(page.locator('#history-chart')).toHaveAttribute('aria-labelledby', 'history-label');
  await expect(page.locator('#history-chart')).toHaveAttribute('aria-describedby', 'history-summary history-table-caption');
  await expect(page.locator('#history-chart')).not.toHaveAttribute('tabindex');
  const historyOrder = await page.locator('.history-card').evaluate(card => [
    ...card.children,
  ].map(child => child.id));
  expect(historyOrder.indexOf('history-chart')).toBeLessThan(historyOrder.indexOf('history-summary'));
  expect(historyOrder.indexOf('history-summary')).toBeLessThan(historyOrder.indexOf('history-details'));
  expect(externalRequests).toEqual([]);
  await expect(page.locator('body')).not.toContainText('—');

  const results = await new AxeBuilder({ page }).analyze();
  expectNoAxeViolations(results, ['critical', 'serious']);
});

test('hides the freshness badge when no valid snapshot is available', async ({ page }) => {
  await page.route('**/api/dashboard-heartbeat', route => route.fulfill({ status: 204 }));
  await page.route('**/data.json?*', route => route.fulfill({ status: 503 }));
  await page.route('**/history.json?*', route => route.fulfill({ status: 503 }));
  await page.goto('/dashboard.html');

  await expect(page.locator('body')).toHaveAttribute('data-freshness', 'unavailable');
  await expect(page.locator('#five-h-bar')).not.toHaveAttribute('value');
  await expect(page.locator('#weekly-bar')).not.toHaveAttribute('value');
  await expect(page.locator('#freshness-badge')).toBeHidden();
  await expect(page.locator('#freshness-detail')).toHaveText('Data unavailable');
  await expect(page.locator('#freshness-status')).toHaveText('Data unavailable');
  const results = await new AxeBuilder({ page }).analyze();
  expectNoAxeViolations(results, ['critical', 'serious']);
});

test('renders fresh external Gist data with independent source and freshness states', async ({ page }) => {
  await page.clock.install({ time: DASHBOARD_NOW });
  await page.route('**/api/dashboard-heartbeat', route => route.fulfill({ status: 204 }));
  await page.route('**/data.json?*', route => route.fulfill({ status: 503 }));
  await page.route('https://api.github.com/gists/**', route => route.fulfill({
    json: {
      files: {
        'data.json': { content: JSON.stringify(snapshot) },
        'history.json': { content: JSON.stringify([snapshot]) },
      },
    },
  }));
  await page.goto('/dashboard.html');
  await page.evaluate(async () => {
    GIST_ID = 'external-fixture';
    await refresh();
  });

  await expect(page.locator('#mode-badge')).toHaveText('EXTERNAL');
  await expect(page.locator('body')).toHaveAttribute('data-dashboard-source', 'external');
  await expect(page.locator('body')).toHaveAttribute('data-freshness', 'fresh');
  await expect(page.locator('#freshness-status')).toContainText('FRESH');
  await expect(page.locator('#error-banner')).toBeHidden();
});

test('becomes stale without a request and exposes age and collection delay', async ({ page }) => {
  const shortIntervalSnapshot = { ...snapshot, sample_interval_seconds: 60 };
  await page.clock.install({ time: DASHBOARD_NOW });
  const dataRequests = [];
  await page.route('**/api/dashboard-heartbeat', route => route.fulfill({ status: 204 }));
  await page.route('**/data.json?*', route => {
    dataRequests.push(route.request().url());
    return route.fulfill({ json: shortIntervalSnapshot });
  });
  await page.route('**/history.json?*', route => route.fulfill({ json: [shortIntervalSnapshot] }));
  await page.goto('/dashboard.html');
  await expect(page.locator('body')).toHaveAttribute('data-freshness', 'fresh');
  const requestsBefore = dataRequests.length;

  await page.clock.runFor(91_000);

  await expect(page.locator('body')).toHaveAttribute('data-freshness', 'stale');
  await expect(page.locator('#freshness-status')).toContainText('STALE 2 min; collection delayed by less than a minute');
  await expect(page.locator('#freshness-badge')).toHaveText('STALE');
  await expect(page.locator('#freshness-badge')).toHaveClass(/badge/);
  await expect(page.locator('#freshness-badge')).toBeVisible();
  await page.locator('#language-toggle').click();
  await expect(page.locator('#freshness-badge')).toHaveText('PÉRIMÉ');
  await expect(page.locator('#freshness-detail')).toContainText('2 min ; collecte en retard');
  await expect(page.locator('#five-h-pct')).toHaveText('72%');
  expect(dataRequests).toHaveLength(requestsBefore);
  const results = await new AxeBuilder({ page }).analyze();
  expectNoAxeViolations(results, ['critical', 'serious']);
});

test('keeps stale values and source through a refresh error, then recovers', async ({ page }) => {
  let currentSnapshot = { ...snapshot, sample_interval_seconds: 60 };
  let failRefresh = false;
  await page.clock.install({ time: DASHBOARD_NOW });
  await page.route('**/api/dashboard-heartbeat', route => route.fulfill({ status: 204 }));
  await page.route('**/data.json?*', route => failRefresh
    ? route.fulfill({ status: 503 })
    : route.fulfill({ json: currentSnapshot }));
  await page.route('**/history.json?*', route => route.fulfill({ json: [currentSnapshot] }));
  await page.goto('/dashboard.html');
  await page.clock.runFor(91_000);
  await expect(page.locator('body')).toHaveAttribute('data-freshness', 'stale');

  failRefresh = true;
  await page.evaluate(() => refresh());
  await expect(page.locator('#error-banner')).toContainText('Refresh failed; showing the last valid data. HTTP 503');
  await expect(page.locator('#mode-badge')).toBeHidden();
  await expect(page.locator('body')).toHaveAttribute('data-freshness', 'stale');
  await expect(page.locator('#five-h-pct')).toHaveText('72%');

  failRefresh = false;
  currentSnapshot = { ...currentSnapshot, five_h_pct: 1, scraped_at: 'not-a-timestamp' };
  await page.evaluate(() => refresh());
  await expect(page.locator('#error-banner')).toContainText('Invalid or missing collection timestamp');
  await expect(page.locator('#five-h-pct')).toHaveText('72%');
  await expect(page.locator('#mode-badge')).toBeHidden();

  currentSnapshot = {
    ...currentSnapshot,
    five_h_pct: 68,
    scraped_at: await page.evaluate(() => new Date().toISOString()),
  };
  await page.evaluate(() => refresh());
  await expect(page.locator('#five-h-pct')).toHaveText('68%');
  await expect(page.locator('body')).toHaveAttribute('data-freshness', 'fresh');
  await expect(page.locator('#freshness-status')).toContainText('FRESH');
  await expect(page.locator('#error-banner')).toBeHidden();

  await page.locator('#language-toggle').click();
  await expect(page.locator('#freshness-badge')).toHaveText('À JOUR');
  await expect(page.locator('#freshness-detail')).toHaveText('moins d’une minute');
  await expect(page.locator('#freshness-status')).not.toContainText('—');
});

test('keeps metrics visible when Chart.js is unavailable', async ({ page }) => {
  await page.route('**/assets/chart.umd.min.js', route => route.abort());
  await mockUsage(page);
  await page.goto('/dashboard.html');

  await expect(page.locator('#five-h-pct')).toHaveText('72%');
  await expect(page.locator('#history-error')).toContainText('Chart.js failed to load');
  await expect(page.locator('body')).toHaveAttribute('data-history-state', 'chart-unavailable');
  await expect(page.locator('#history-summary')).toContainText('1 sample from');
  await expect(page.locator('#history-table-body tr')).toHaveCount(1);
  await expect(page.locator('#history-chart')).toBeHidden();
  await expect(page.locator('#error-banner')).toBeHidden();
  const results = await new AxeBuilder({ page }).analyze();
  expectNoAxeViolations(results, ['critical', 'serious']);
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
  await expect(page.locator('body')).toHaveAttribute('data-history-state', 'unavailable');
  await expect(page.locator('#history-summary')).toContainText('History unavailable');
  await expect(page.locator('#history-table-body tr')).toHaveCount(0);
  await page.locator('#language-toggle').click();
  await expect(page.locator('#history-label')).toHaveText('Historique indisponible');
  await expect(page.locator('#history-summary')).toContainText('Historique indisponible');
  const results = await new AxeBuilder({ page }).analyze();
  expectNoAxeViolations(results, ['critical', 'serious']);
});

test('keeps the accessible history fallback when Chart.js update or destroy throws', async ({ page }) => {
  let history = [snapshot];
  await page.clock.install({ time: DASHBOARD_NOW });
  await page.route('**/api/dashboard-heartbeat', route => route.fulfill({ status: 204 }));
  await page.route('**/data.json?*', route => route.fulfill({ json: snapshot }));
  await page.route('**/history.json?*', route => route.fulfill({ json: history }));
  await page.goto('/dashboard.html');
  await expect.poll(() => page.evaluate(() => Boolean(chart))).toBe(true);

  await page.evaluate(() => {
    chart.update = () => { throw new Error('chart update exploded'); };
  });
  await page.evaluate(() => refresh());
  await expect(page.locator('#history-error')).toContainText('Chart.js failed to load');
  await expect(page.locator('body')).toHaveAttribute('data-history-state', 'chart-unavailable');
  await expect(page.locator('#history-summary')).toContainText('1 sample from');
  await expect(page.locator('#history-table-body tr')).toHaveCount(1);
  await expect(page.locator('#error-banner')).toBeHidden();

  await page.evaluate(historyData => renderHistory(historyData), [snapshot]);
  await page.evaluate(() => {
    chart.destroy = () => { throw new Error('chart destroy exploded'); };
  });
  history = [];
  await page.evaluate(() => refresh());
  await expect(page.locator('#history-error')).toContainText('History is empty');
  await expect(page.locator('body')).toHaveAttribute('data-history-state', 'unavailable');
  await expect(page.locator('#history-label')).toHaveText('History unavailable');
  await expect(page.locator('#history-summary')).toContainText('History unavailable');
  await expect(page.locator('#history-table-body tr')).toHaveCount(0);
  await expect(page.locator('#error-banner')).toBeHidden();
  const results = await new AxeBuilder({ page }).analyze();
  expectNoAxeViolations(results, ['critical', 'serious']);
});

test('shows weekly pace values and direction as text', async ({ page }) => {
  const accessibleSnapshot = { ...snapshot, weekly_reset_at: 1786147200 };
  await page.clock.install({ time: DASHBOARD_NOW });
  await page.route('**/api/dashboard-heartbeat', route => route.fulfill({ status: 204 }));
  await page.route('**/data.json?*', route => route.fulfill({ json: accessibleSnapshot }));
  await page.route('**/history.json?*', route => route.fulfill({ json: [accessibleSnapshot] }));
  await page.goto('/dashboard.html');

  await expect(page.locator('#weekly-pace-actual')).toHaveText('Actual remaining: 36%');
  await expect(page.locator('#weekly-pace-ideal')).toContainText('Ideal remaining:');
  await expect(page.locator('#weekly-pace-delta')).toContainText('below');
  await expect(page.locator('#weekly-pace-delta')).toHaveAttribute('title', '');
  await expect(page.locator('body')).not.toContainText('—');
});

test('opens and closes the history table with keyboard focus', async ({ page }) => {
  await mockUsage(page);
  await page.goto('/dashboard.html');

  const summary = page.locator('#history-details summary');
  await summary.focus();
  await expect(page.locator('#history-details summary')).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(page.locator('#history-details')).toHaveAttribute('open', '');
  await expect(page.locator('#history-table')).toBeVisible();
  await page.keyboard.press('Space');
  await expect(page.locator('#history-details')).not.toHaveAttribute('open');
  await expect(page.locator('#history-details summary')).toBeFocused();
  const focusStyle = await summary.evaluate(element => getComputedStyle(element).outlineStyle);
  expect(focusStyle).not.toBe('none');
});

test('explores the nearest dashboard time slice across the full chart height', async ({ page }) => {
  const history = [
    { ...snapshot, scraped_at: '2026-08-01T00:00:00Z', five_h_pct: 90, weekly_pct: 70 },
    { ...snapshot, scraped_at: '2026-08-02T00:00:00Z', five_h_pct: 60, weekly_pct: 40 },
    { ...snapshot, scraped_at: '2026-08-03T00:00:00Z', five_h_pct: 30, weekly_pct: 20 },
  ];
  await mockUsage(page, history);
  await page.goto('/dashboard.html');
  await expect.poll(() => page.evaluate(() => Boolean(chart))).toBe(true);
  await page.locator('#history-chart').scrollIntoViewIfNeeded();

  const target = await page.evaluate(() => ({
    x: chart.scales.x.getPixelForValue(Date.parse('2026-08-02T00:00:00Z')),
    y: chart.chartArea.top + 1,
  }));
  const box = await page.locator('#history-chart').boundingBox();
  await page.mouse.move(box.x + target.x, box.y + target.y);

  await expect.poll(() => page.evaluate(() => chart.tooltip.dataPoints?.map(item => item.dataset.label))).toEqual([
    '5h Limit %',
    'Weekly Limit %',
    'Forecast 24h',
    'Forecast 6h',
  ]);
  const selection = await page.evaluate(() => ({
    title: chart.tooltip.title,
    body: chart.tooltip.body.map(item => item.lines[0]),
    caretX: chart.tooltip.caretX,
    expectedX: chart.scales.x.getPixelForValue(Date.parse('2026-08-02T00:00:00Z')),
    mode: chart.options.interaction.mode,
    cursorRegistered: Boolean(Chart.registry.plugins.get('timeSliceCursor')),
  }));
  expect(selection.title).toEqual(['02/08/2026 02:00']);
  expect(selection.body).toEqual(['5h Limit %: 60%', 'Weekly Limit %: 40%', 'Forecast 24h: 76%', 'Forecast 6h: 10%']);
  expect(selection.caretX).toBeCloseTo(selection.expectedX, 1);
  expect(selection.mode).toBe('timeSlice');
  expect(selection.cursorRegistered).toBe(true);
});

const analyticsPayload = {
  schema_version: 1,
  period: { range: '30d', from: '2026-07-05T10:00:00Z', to: '2026-08-04T10:00:00Z', timezone: 'Europe/Paris', granularity_seconds: 86400 },
  filters: { sources: [], models: [], reset_type: 'all' },
  available: { sources: ['codex', 'opencode'], models: ['gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna', 'unknown-model'] },
  freshness: { limits_last_sample_at: '2026-08-04T09:45:00Z', collectors: { codex: { status: 'ok', last_success_at: '2026-08-04T09:45:00Z' }, opencode: { status: 'ok', last_success_at: '2026-08-04T09:45:00Z' }, hermes: { status: 'disabled', last_success_at: null } } },
  limits: { samples: 2, forecast_samples: 2, series: [{ at: '2026-08-03T00:00:00Z', five_h_pct: 80, weekly_pct: 60, ideal_weekly_pct: 65.5, forecast_chance_24h_pct: 60, forecast_chance_6h_pct: 20, forecast_generated_at: '2026-08-02T23:55:00Z', forecast_samples: 1 }, { at: '2026-08-04T00:00:00Z', five_h_pct: 55, weekly_pct: 52, ideal_weekly_pct: 51.2, forecast_chance_24h_pct: 70, forecast_chance_6h_pct: 30, forecast_generated_at: '2026-08-03T23:55:00Z', forecast_samples: 1 }] },
  weekly_limit_value: { currency: 'USD', window_seconds: 43200, point_interval_seconds: 21600, minimum_quota_delta_pct_points: 0.5, series: [{ at: '2026-08-04T00:00:00Z', window_start: '2026-08-03T12:00:00Z', window_seconds: 43200, limit_id: 'fixture', quota_consumed_pct_points: 2, consumed_fraction: 0.02, observed_cost_usd: 1.5, raw_value_usd: 75, value_usd: 75, quality: 'good', reason: null }], unavailable_reasons: {} },
  tokens: {
    summary: { input_tokens: 1000000, cache_read_tokens: 500000, cache_write_tokens: 25000, output_tokens: 200000, reasoning_tokens: 50000, events: 2, estimated_cost_usd: 11.25, assumed_zero_tokens: 100 },
    series: [{ at: '2026-08-04T00:00:00Z', input_tokens: 1000000, cache_read_tokens: 500000, cache_write_tokens: 25000, output_tokens: 200000, reasoning_tokens: 50000, estimated_cost_usd: 11.25 }],
    breakdown: [{ source: 'codex', provider: 'openai', model: 'gpt-5.6-sol', input_tokens: 1000000, cache_read_tokens: 500000, cache_write_tokens: 25000, output_tokens: 200000, estimated_cost_usd: 11.25, pricing_status: 'priced' }],
    breakdown_pagination: { total: 1, offset: 0, limit: 50 },
  },
  resets: { total: 2, weekly_total: 2, weekly_summary: { random: { count: 1, gained_vs_ideal_pct_points: 30.004, lost_vs_ideal_pct_points: 0 }, end_of_week: { count: 1, unused_pct_points: 5 } }, offset: 0, limit: 10, items: [{ window: 'weekly', category: 'random', reset_at: '2026-08-04T08:00:00Z', observed_at: '2026-08-04T08:15:00Z', observation_delay_seconds: 900, before_pct: 28, after_pct: 100, forecast_chance_24h_pct: 64, forecast_chance_6h_pct: 22, forecast_sample_at: '2026-08-04T07:45:00Z', ideal_weekly_pace_pct: 58.004, pace_delta_pct_points: 30.004, unused_pct_points: 0 }] },
  baselines: { hermes: [{ tokens: 42 }] },
  pricing: { currency: 'USD', as_of: '2026-08-04', valuation_mode: 'current_catalog' },
  warnings: [
    'No catalog price; assumed zero: other/unknown-model',
    'codex collector: delayed',
  ],
};

const enhancedAnalyticsPayload = {
  ...analyticsPayload,
  freshness: {
    ...analyticsPayload.freshness,
    limits_age_seconds: 120,
    limits_status: 'fresh',
    sample_interval_seconds: 900,
    collectors: {
      ...analyticsPayload.freshness.collectors,
      codex: {
        ...analyticsPayload.freshness.collectors.codex,
        last_attempt_at: '2026-08-04T09:45:00Z',
        age_seconds: 120,
      },
      opencode: {
        ...analyticsPayload.freshness.collectors.opencode,
        last_attempt_at: '2026-08-04T09:45:00Z',
        age_seconds: 120,
      },
      hermes: {
        ...analyticsPayload.freshness.collectors.hermes,
        last_attempt_at: '2026-08-04T09:45:00Z',
        last_error: 'database unavailable',
        status: 'error',
      },
    },
  },
  limits: {
    ...analyticsPayload.limits,
    reset_markers: [
      { window: '5h', at: '2026-08-03T05:00:00Z' },
      { window: 'weekly', at: '2026-08-04T08:00:00Z' },
    ],
  },
  tokens: {
    ...analyticsPayload.tokens,
    series_by_source: [
      { source: 'codex', at: '2026-08-04T00:00:00Z', input_tokens: 1000000, output_tokens: 200000, estimated_cost_usd: 11.25 },
      { source: 'opencode', at: '2026-08-04T00:00:00Z', input_tokens: 100, output_tokens: 0, estimated_cost_usd: 0 },
    ],
  },
  resets: {
    ...analyticsPayload.resets,
    total: 55,
    limit: 50,
  },
};

const paginatedBreakdown = Array.from({ length: 55 }, (_value, index) => ({
  source: 'opencode',
  provider: 'fixture-provider',
  model: `fixture-model-${String(index).padStart(2, '0')}`,
  input_tokens: index + 1,
  cache_read_tokens: 0,
  cache_write_tokens: 0,
  output_tokens: 0,
  reasoning_tokens: 0,
  total_tokens: index + 1,
  estimated_cost_usd: 0,
  pricing_status: 'assumed-zero',
}));

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

  await expect(page.locator('#total-tokens')).toHaveText('1.73M');
  await expect(page.locator('#assumed-zero-tokens')).toHaveCount(0);
  await expect(page.locator('#estimated-cost')).toHaveText('€9.68');
  await expect(page.locator('#allocation-total-cost')).toHaveText('€9.68');
  await expect(page.locator('#estimated-cost')).toHaveAttribute('title', 'Converted from USD using fixed rate: 1 USD = €0.86');
  await expect.poll(() => analyticsQueries[0]?.get('models')).toBe('gpt-5.6-luna,gpt-5.6-sol,gpt-5.6-terra');
  await expect(page.locator('#weekly-reset-count')).toHaveText('2');
  await expect(page.locator('#weekly-reset-impact')).toHaveText('1 random · 1 end of week');
  await expect(page.locator('#random-reset-count')).toHaveText('1');
  await expect(page.locator('#random-reset-impact')).toHaveText('30.004 pts gained · 0 pts lost vs ideal pace');
  await expect(page.locator('#end-week-reset-count')).toHaveText('1');
  await expect(page.locator('.metric-card')).toHaveCount(10);
  await expect(page.locator('#token-metric-toggle')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('#limits-chart-card #token-metric-toggle')).toHaveCount(1);
  await expect(page.locator('#toggle-token-overlay')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('#tokens-chart-card')).toBeHidden();
  await expect(page.locator('#weekly-limit-value-card')).toBeVisible();
  await expect(page.locator('#weekly-limit-value-window')).toContainText('one point / 6 h');
  await expect(page.locator('#weekly-limit-value-summary')).toContainText('1 valid twelve-hour estimate');
  await expect(page.locator('#weekly-limit-value-data-body tr')).toHaveCount(1);
  await expect.poll(() => page.evaluate(() => weeklyLimitValueChart.data.datasets[0].data[0].y)).toBe(75);
  await expect.poll(() => page.evaluate(() => weeklyLimitValueChart.data.datasets[0].valueKind)).toBe('usd');
  await expect.poll(() => page.evaluate(() => weeklyLimitValueChart.options.scales.y.ticks.callback(75))).toBe('$75.00');
  await expect.poll(() => page.evaluate(() => limitsChart.data.datasets.find(dataset => dataset.yAxisID === 'tokens')?.data[0]?.y)).toBe(11.25);
  await page.locator('#toggle-token-overlay').click();
  await expect(page.locator('#toggle-token-overlay')).toHaveAttribute('aria-pressed', 'false');
  await expect(page.locator('#tokens-chart-card')).toBeVisible();
  await expect(page.locator('#tokens-chart-card #token-metric-toggle')).toHaveCount(1);
  await expect(page.locator('#limits-chart-card #token-metric-toggle')).toHaveCount(0);
  await expect(page.locator('#resets-body')).toContainText('Random');
  await expect(page.locator('#breakdown-body')).toContainText('gpt-5.6-sol');
  await expect(page.locator('#analytics-warnings')).toContainText('codex collector: delayed');
  await expect(page.locator('#analytics-warnings')).not.toContainText('assumed zero');
  await expect(page.locator('#analytics-price-warnings')).toContainText('assumed zero');
  await expect(page.locator('#collector-grid')).not.toContainText('{value}');
  await expect(page.locator('#collector-grid')).toContainText(/Last success .+/);
  await expect(page.locator('#collector-grid')).toContainText('No successful collection yet');
  await expect(page.getByText('No catalog price; assumed zero: other/unknown-model')).toHaveCount(1);
  const warningPosition = await page.evaluate(() => {
    const grid = document.querySelector('.analytics-grid');
    const priceWarnings = document.querySelector('#analytics-price-warnings');
    const footer = document.querySelector('.analytics-footer');
    return {
      afterDataHealth: Boolean(grid && priceWarnings && grid.nextElementSibling === priceWarnings),
      beforeFooter: Boolean(priceWarnings && footer && (priceWarnings.compareDocumentPosition(footer) & Node.DOCUMENT_POSITION_FOLLOWING)),
      marginTop: priceWarnings ? getComputedStyle(priceWarnings).marginTop : '',
    };
  });
  expect(warningPosition).toEqual({ afterDataHealth: true, beforeFooter: true, marginTop: '18px' });
  await expect(page.locator('#source-filter input, #model-filter input')).toHaveCount(0);
  await expect(page.locator('#model-filter [data-filter-value]')).toHaveCount(4);
  await page.getByRole('button', { name: 'GPT 5.6' }).click();
  await expect.poll(() => analyticsQueries.at(-1)?.get('models')).toBe('gpt-5.6-sol,gpt-5.6-terra,gpt-5.6-luna');
  await page.locator('#source-filter [data-filter-value="codex"]').click();
  await expect.poll(() => analyticsQueries.at(-1)?.get('sources')).toBe('opencode,hermes');
  await expect(page.locator('.page-nav')).toHaveCount(0);
  await expect(page.locator('.analytics-nav .back-link')).toHaveCount(2);
  await expect(page.locator('.back-link[href="dashboard.html"]')).toHaveCount(1);
  await expect(page.locator('.analytics-nav .external-link')).toHaveAttribute('href', 'https://github.com/AlexandreDor/ai-usage-monitor');
  await expect(page.locator('.analytics-nav .external-link')).toHaveAttribute('rel', 'noopener noreferrer');
  await expect(page.locator('#period-label, #granularity-label')).toHaveCount(0);
  const chartBounds = await page.evaluate(() => ({
    limitsMin: limitsChart.options.scales.x.min,
    limitsMax: limitsChart.options.scales.x.max,
    tokensMin: tokensChart.options.scales.x.min,
    tokensMax: tokensChart.options.scales.x.max,
  }));
  expect(chartBounds).toEqual({
    limitsMin: Date.parse('2026-08-03T00:00:00Z'),
    limitsMax: Date.parse('2026-08-04T10:00:00Z'),
    tokensMin: Date.parse('2026-08-04T00:00:00Z'),
    tokensMax: Date.parse('2026-08-04T10:00:00Z'),
  });
  await page.evaluate(() => window.scrollTo(0, 0));
  const layout = await page.evaluate(() => Object.fromEntries([
    ['selector', document.querySelector('.filter-panel')],
    ['metrics', document.querySelector('.metric-grid')],
    ['limits', document.querySelector('#limits-chart-card')],
    ['resets', document.querySelector('#reset-history-card')],
    ['allocation', document.querySelector('#allocation-card')],
    ['health', document.querySelector('#freshness-panel')],
    ['pricingWarning', document.querySelector('#analytics-price-warnings')],
  ].map(([name, element]) => [name, element.getBoundingClientRect().top])));
  expect(layout.selector).toBeLessThan(layout.metrics);
  expect(layout.metrics).toBeLessThan(layout.limits);
  expect(layout.limits).toBeLessThan(layout.resets);
  expect(layout.resets).toBeLessThan(layout.allocation);
  expect(layout.allocation).toBeLessThan(layout.health);
  expect(layout.health).toBeLessThan(layout.pricingWarning);
  const filterBehavior = await page.evaluate(() => {
    const panel = document.querySelector('.filter-panel');
    const initialTop = panel.getBoundingClientRect().top;
    window.scrollTo(0, 400);
    return {
      position: getComputedStyle(panel).position,
      movesWithPage: panel.getBoundingClientRect().top < initialTop,
    };
  });
  expect(filterBehavior).toEqual({ position: 'static', movesWithPage: true });
  expect(externalRequests).toEqual([]);

  const results = await new AxeBuilder({ page }).analyze();
  expect(results.violations.filter(violation => violation.impact === 'critical')).toEqual([]);
});

test('hides analytics warning containers when the API returns no warnings', async ({ page }) => {
  await page.route('**/api/analytics?*', route => route.fulfill({ json: { ...analyticsPayload, warnings: [] } }));
  await page.goto('/analytics.html');

  await expect(page.locator('#analytics-warnings')).toBeHidden();
  await expect(page.locator('#analytics-price-warnings')).toBeHidden();
});

test('falls back once to all models when GPT 5.6 is unavailable', async ({ page }) => {
  const queries = [];
  const payload = {
    ...analyticsPayload,
    available: { ...analyticsPayload.available, models: ['legacy-model', 'unknown-model'] },
  };
  await page.route('**/api/analytics?*', route => {
    queries.push(new URL(route.request().url()).searchParams);
    return route.fulfill({ json: payload });
  });
  await page.goto('/analytics.html');

  await expect.poll(() => queries.length).toBe(2);
  expect(queries[0].get('models')).toBe('gpt-5.6-luna,gpt-5.6-sol,gpt-5.6-terra');
  expect(queries[1].get('models')).toBe('legacy-model,unknown-model');
  await expect(page.locator('#analytics-error')).toContainText('No GPT 5.6 Sol, Terra, or Luna model is available');
  await page.waitForTimeout(100);
  expect(queries).toHaveLength(2);
});

test('selects GPT 5.6 when models appear after an initially empty archive', async ({ page }) => {
  const queries = [];
  let availableModels = [];
  await page.route('**/api/analytics?*', route => {
    queries.push(new URL(route.request().url()).searchParams);
    return route.fulfill({
      json: {
        ...analyticsPayload,
        available: { ...analyticsPayload.available, models: availableModels },
      },
    });
  });
  await page.goto('/analytics.html');

  await expect.poll(() => queries.length).toBe(1);
  await expect(page.locator('#analytics-error')).toBeHidden();
  availableModels = ['gpt-5.6-sol', 'legacy-model'];
  await page.locator('[data-range="7d"]').click();

  await expect.poll(() => queries.length).toBe(2);
  await expect(page.locator('#model-filter [data-filter-value="gpt-5.6-sol"]')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('#model-filter [data-filter-value="legacy-model"]')).toHaveAttribute('aria-pressed', 'false');
  await expect(page.locator('#analytics-error')).toBeHidden();
});

test('keeps the complete dashboard above the fold at 1920x1080', async ({ page }) => {
  await page.setViewportSize({ width: 1920, height: 1080 });
  await mockUsage(page);
  await page.goto('/dashboard.html');

  const layout = await page.evaluate(() => {
    const history = document.querySelector('.history-card').getBoundingClientRect();
    const preferences = document.querySelector('.preference-controls').getBoundingClientRect();
    const links = document.querySelector('.dashboard-links').getBoundingClientRect();
    const overlaps = !(preferences.right <= links.left || preferences.left >= links.right || preferences.bottom <= links.top || preferences.top >= links.bottom);
    return {
      viewportHeight: window.innerHeight,
      scrollHeight: document.documentElement.scrollHeight,
      historyBottom: history.bottom,
      historyVisible: history.top >= 0 && history.bottom <= window.innerHeight,
      navigationOverlap: overlaps,
    };
  });
  expect(layout.scrollHeight).toBeLessThanOrEqual(layout.viewportHeight);
  expect(layout.historyBottom).toBeLessThanOrEqual(layout.viewportHeight);
  expect(layout.historyVisible).toBe(true);
  expect(layout.navigationOverlap).toBe(false);
});

test('renders detailed analytics, reset markers and cost mode by default', async ({ page }) => {
  await page.route('**/api/analytics?*', route => {
    const query = new URL(route.request().url()).searchParams;
    const offset = Number(query.get('reset_offset') || 0);
    return route.fulfill({ json: { ...enhancedAnalyticsPayload, resets: { ...enhancedAnalyticsPayload.resets, offset } } });
  });
  await page.goto('/analytics.html');

  await expect(page.locator('#input-tokens')).toHaveText('1M');
  await expect(page.locator('#cache-read-tokens')).toHaveText('500K');
  await expect(page.locator('#cache-write-tokens')).toHaveText('25K');
  await expect(page.locator('#reasoning-tokens')).toHaveText('50K');
  await expect(page.locator('#limits-chart-summary')).toContainText('2 reset markers');
  await expect(page.locator('#limits-chart-summary')).toContainText('2 forecast samples');
  await expect(page.locator('#limits-data-body tr').first().locator('td')).toHaveCount(6);
  await expect(page.locator('#breakdown-body tr td')).toHaveCount(11);
  await expect(page.locator('#reset-pagination')).toBeVisible();
  await expect(page.locator('#reset-page-label')).toHaveText('1–50 of 55');
  await expect(page.locator('#collector-grid')).toContainText('database unavailable');
  await expect(page.locator('#token-metric-toggle')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('#tokens-chart-card')).toBeHidden();
  await expect(page.locator('#resets-body tr').first().locator('td')).toHaveCount(8);
  await expect(page.locator('#resets-body tr').first().locator('td').last()).toHaveText('Forecast 24h: 64% · Forecast 6h: 22%');

  await expect.poll(() => page.evaluate(() => limitsChart.data.datasets.filter(dataset => dataset.resetMarker).length)).toBe(2);
  await expect.poll(() => page.evaluate(() => tokensChart.data.datasets.length)).toBe(2);
  await expect.poll(() => page.evaluate(() => limitsChart.data.datasets.find(dataset => dataset.label === 'codex')?.data[0]?.y)).toBe(11.25);
  await expect.poll(() => page.evaluate(() => limitsChart.data.datasets.find(dataset => dataset.label === 'Ideal weekly pace')?.data[1]?.y)).toBe(51.2);
  await expect.poll(() => page.evaluate(() => limitsChart.data.datasets.filter(dataset => dataset.valueKind === 'percent').length)).toBe(5);
  await page.locator('#toggle-token-overlay').click();
  await expect(page.locator('#tokens-chart-card')).toBeVisible();
  await expect(page.locator('#tokens-chart-card #token-metric-toggle')).toHaveCount(1);
  await page.locator('#token-metric-toggle').click();
  await expect(page.locator('#token-metric-toggle')).toHaveAttribute('aria-pressed', 'false');
  await expect.poll(() => page.evaluate(() => limitsChart.data.datasets.some(dataset => dataset.yAxisID === 'tokens'))).toBe(false);
  await expect.poll(() => page.evaluate(() => tokensChart.data.datasets[0].data[0].y)).toBe(1200000);
  await page.locator('#toggle-token-overlay').click();
  await expect(page.locator('#tokens-chart-card')).toBeHidden();
  await expect(page.locator('#limits-chart-card #token-metric-toggle')).toHaveCount(1);
  await expect.poll(() => page.evaluate(() => limitsChart.data.datasets.find(dataset => dataset.label === 'codex')?.data[0]?.y)).toBe(1200000);

  await page.locator('#resets-next').click();
  await expect(page.locator('#reset-page-label')).toContainText('51–55');
});

test('paginates the model breakdown with keyboard controls and keeps localization in place', async ({ page }) => {
  const queries = [];
  await page.route('**/api/analytics?*', route => {
    const query = new URL(route.request().url()).searchParams;
    queries.push(query);
    const requestedOffset = Number(query.get('breakdown_offset') || 0);
    const offset = Math.min(requestedOffset, 50);
    return route.fulfill({
      json: {
        ...analyticsPayload,
        tokens: {
          ...analyticsPayload.tokens,
          breakdown: paginatedBreakdown.slice(offset, offset + 50),
          breakdown_pagination: { total: 55, offset, limit: 50 },
        },
      },
    });
  });
  await page.goto('/analytics.html');

  await expect(page.locator('#breakdown-pagination')).toBeVisible();
  await expect(page.locator('#breakdown-pagination')).toHaveAttribute('aria-label', 'Model breakdown pagination');
  await expect(page.locator('#breakdown-page-label')).toHaveText('1–50 of 55');
  await expect(page.locator('#breakdown-body tr')).toHaveCount(50);
  await page.locator('#breakdown-next').focus();
  await page.keyboard.press('Enter');
  await expect.poll(() => queries.at(-1)?.get('breakdown_offset')).toBe('50');
  await expect(page.locator('#breakdown-page-label')).toHaveText('51–55 of 55');
  await expect(page.locator('#breakdown-body tr')).toHaveCount(5);
  await expect(page.locator('#breakdown-next')).toBeDisabled();
  await expect(page.locator('#breakdown-next')).toBeFocused();

  await page.locator('#language-toggle').click();
  await expect(page.locator('#breakdown-page-label')).toHaveText('51–55 sur 55');
  await expect(page.locator('#breakdown-pagination')).toHaveAttribute('aria-label', 'Pagination de la ventilation par modèle');
  await page.locator('#breakdown-previous').focus();
  await page.keyboard.press('Space');
  await expect.poll(() => queries.at(-1)?.get('breakdown_offset')).toBe('0');
  await expect(page.locator('#breakdown-page-label')).toHaveText('1–50 sur 55');
  await expect(page.locator('#breakdown-previous')).toBeFocused();

  await page.locator('#breakdown-next').click();
  await expect.poll(() => queries.at(-1)?.get('breakdown_offset')).toBe('50');
  await page.locator('#source-filter [data-filter-value="codex"]').click();
  await expect.poll(() => queries.at(-1)?.get('breakdown_offset')).toBe('0');
});

test('keeps the newest breakdown response when pagination requests finish out of order', async ({ page }) => {
  const queries = [];
  let releaseDelayedResponse;
  let delayedResponseFinished = false;
  const delayedResponse = new Promise(resolve => { releaseDelayedResponse = resolve; });
  await page.route('**/api/analytics?*', async route => {
    const query = new URL(route.request().url()).searchParams;
    queries.push(query);
    const offset = Number(query.get('breakdown_offset') || 0);
    if (offset === 50) await delayedResponse;
    await route.fulfill({
      json: {
        ...analyticsPayload,
        tokens: {
          ...analyticsPayload.tokens,
          breakdown: paginatedBreakdown.slice(offset, offset + 50),
          breakdown_pagination: { total: 55, offset, limit: 50 },
        },
      },
    });
    if (offset === 50) delayedResponseFinished = true;
  });
  await page.goto('/analytics.html');

  await page.locator('#breakdown-next').click();
  await expect.poll(() => queries.some(query => query.get('breakdown_offset') === '50')).toBe(true);
  await page.locator('#source-filter [data-filter-value="codex"]').click();
  await expect.poll(() => queries.at(-1)?.get('breakdown_offset')).toBe('0');
  await expect(page.locator('#breakdown-page-label')).toHaveText('1–50 of 55');

  releaseDelayedResponse();
  await expect.poll(() => delayedResponseFinished).toBe(true);
  await expect(page.locator('#breakdown-page-label')).toHaveText('1–50 of 55');
  await expect(page.locator('#breakdown-body tr').first()).toContainText('fixture-model-00');
});

test('retries a failed breakdown page without skipping it', async ({ page }) => {
  const requestedOffsets = [];
  let pageTwoAttempts = 0;
  await page.route('**/api/analytics?*', route => {
    const query = new URL(route.request().url()).searchParams;
    const offset = Number(query.get('breakdown_offset') || 0);
    requestedOffsets.push(offset);
    if (offset === 50 && ++pageTwoAttempts === 1) {
      return route.fulfill({ status: 500, json: { error: 'temporary pagination failure' } });
    }
    return route.fulfill({
      json: {
        ...analyticsPayload,
        tokens: {
          ...analyticsPayload.tokens,
          breakdown: paginatedBreakdown.slice(offset, offset + 50),
          breakdown_pagination: { total: 55, offset, limit: 50 },
        },
      },
    });
  });
  await page.goto('/analytics.html');

  await page.locator('#breakdown-next').click();
  await expect(page.locator('#analytics-error')).toContainText('temporary pagination failure');
  await page.locator('#breakdown-next').click();
  await expect.poll(() => requestedOffsets.slice(-2)).toEqual([50, 50]);
  await expect(page.locator('#breakdown-page-label')).toHaveText('51–55 of 55');
});

test('keeps a filter reset on the first page when its request fails', async ({ page }) => {
  await page.route('**/api/analytics?*', route => {
    const query = new URL(route.request().url()).searchParams;
    const offset = Number(query.get('breakdown_offset') || 0);
    const sources = query.get('sources');
    if (offset === 0 && sources === 'opencode,hermes') {
      return route.fulfill({ status: 500, json: { error: 'temporary filter failure' } });
    }
    return route.fulfill({
      json: {
        ...analyticsPayload,
        tokens: {
          ...analyticsPayload.tokens,
          breakdown: paginatedBreakdown.slice(offset, offset + 50),
          breakdown_pagination: { total: 55, offset, limit: 50 },
        },
      },
    });
  });
  await page.goto('/analytics.html');
  await page.locator('#breakdown-next').click();
  await expect(page.locator('#breakdown-page-label')).toHaveText('51–55 of 55');

  await page.locator('#source-filter [data-filter-value="codex"]').click();
  await expect(page.locator('#analytics-error')).toContainText('temporary filter failure');
  await expect.poll(() => page.evaluate(() => new URLSearchParams(queryString()).get('breakdown_offset'))).toBe('0');
});

test('groups visible Analytics units and excludes missing values and reset markers', async ({ page }) => {
  const payload = {
    ...enhancedAnalyticsPayload,
    limits: {
      ...enhancedAnalyticsPayload.limits,
      series: enhancedAnalyticsPayload.limits.series.map((point, index) => index === 1 ? { ...point, weekly_pct: null } : point),
    },
  };
  await page.route('**/api/analytics?*', route => route.fulfill({ json: payload }));
  await page.goto('/analytics.html');

  const moveToSlice = async () => {
    await page.locator('#limits-chart').scrollIntoViewIfNeeded();
    const target = await page.evaluate(() => ({
      x: limitsChart.scales.x.getPixelForValue(Date.parse('2026-08-04T00:00:00Z')),
      y: limitsChart.chartArea.bottom - 1,
    }));
    const box = await page.locator('#limits-chart').boundingBox();
    await page.mouse.move(box.x + target.x, box.y + target.y);
  };
  await moveToSlice();

  await expect.poll(() => page.evaluate(() => limitsChart.tooltip.body?.map(item => item.lines[0]))).toEqual([
    '5-hour remaining: 55%',
    'Ideal weekly pace: 51.2%',
    'Forecast 24h: 70%',
    'Forecast 6h: 30%',
    'codex: €9.68',
    'opencode: €0.0000',
  ]);
  expect(await page.evaluate(() => limitsChart.tooltip.dataPoints.some(item => item.dataset.resetMarker))).toBe(false);

  await page.evaluate(() => {
    const index = limitsChart.data.datasets.findIndex(dataset => dataset.label === '5-hour remaining');
    limitsChart.hide(index);
    limitsChart.update('none');
  });
  await moveToSlice();
  await expect.poll(() => page.evaluate(() => limitsChart.tooltip.body?.map(item => item.lines[0]))).toEqual([
    'Ideal weekly pace: 51.2%',
    'Forecast 24h: 70%',
    'Forecast 6h: 30%',
    'codex: €9.68',
    'opencode: €0.0000',
  ]);

  await page.evaluate(() => {
    const index = limitsChart.data.datasets.findIndex(dataset => dataset.label === '5-hour remaining');
    limitsChart.show(index);
    limitsChart.update('none');
  });
  await page.locator('#token-metric-toggle').click();
  await moveToSlice();
  await expect.poll(() => page.evaluate(() => limitsChart.tooltip.body?.map(item => item.lines[0]))).toEqual([
    '5-hour remaining: 55%',
    'Ideal weekly pace: 51.2%',
    'Forecast 24h: 70%',
    'Forecast 6h: 30%',
    'codex: 1,200,000 tokens',
    'opencode: 100 tokens',
  ]);
});

test('retains a touch selection while allowing vertical page scrolling', async ({ browser }) => {
  const context = await browser.newContext({ hasTouch: true, isMobile: true, viewport: { width: 390, height: 700 } });
  const page = await context.newPage();
  try {
    await page.route('**/api/analytics?*', route => route.fulfill({ json: enhancedAnalyticsPayload }));
    await page.goto('/analytics.html');
    await page.locator('#limits-chart').scrollIntoViewIfNeeded();
    const target = await page.evaluate(() => ({
      x: limitsChart.scales.x.getPixelForValue(Date.parse('2026-08-04T00:00:00Z')),
      y: (limitsChart.chartArea.top + limitsChart.chartArea.bottom) / 2,
    }));
    let box = await page.locator('#limits-chart').boundingBox();
    await page.touchscreen.tap(box.x + target.x, box.y + target.y);
    await expect.poll(() => page.evaluate(() => limitsChart.tooltip.dataPoints?.length || 0)).toBeGreaterThan(0);
    await page.waitForTimeout(50);
    expect(await page.evaluate(() => limitsChart.tooltip.dataPoints?.length || 0)).toBeGreaterThan(0);

    const beforeScroll = await page.evaluate(() => window.scrollY);
    box = await page.locator('#limits-chart').boundingBox();
    const client = await context.newCDPSession(page);
    const x = box.x + box.width / 2;
    const y = box.y + box.height * 0.75;
    await client.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y }] });
    await client.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x, y: y - 140 }] });
    await client.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await expect.poll(() => page.evaluate(() => window.scrollY)).toBeGreaterThan(beforeScroll);
  } finally {
    await context.close();
  }
});

test('does not render a 5-hour series when Codex returns null', async ({ page }) => {
  await page.route('**/api/analytics?*', route => route.fulfill({
    json: {
      ...analyticsPayload,
      limits: {
        ...analyticsPayload.limits,
        series: analyticsPayload.limits.series.map(point => ({ ...point, five_h_pct: null })),
      },
    },
  }));
  await page.goto('/analytics.html');

  await expect.poll(() => page.evaluate(() => typeof limitsChart !== 'undefined' && limitsChart !== null)).toBe(true);
  await expect.poll(() => page.evaluate(() => limitsChart.data.datasets.some(dataset => dataset.label === '5-hour remaining'))).toBe(false);
  await expect(page.locator('#limits-data-body tr').first()).toContainText('-');
  await expect(page.locator('#resets-body tr').first()).toContainText('N/A —');
});

test('shows N/A when no recent Forecast exists before a reset', async ({ page }) => {
  await page.route('**/api/analytics?*', route => route.fulfill({
    json: {
      ...analyticsPayload,
      resets: {
        ...analyticsPayload.resets,
        items: analyticsPayload.resets.items.map(item => ({
          ...item,
          forecast_chance_24h_pct: null,
          forecast_chance_6h_pct: null,
          forecast_sample_at: null,
        })),
      },
    },
  }));
  await page.goto('/analytics.html');

  await expect(page.locator('#resets-body tr').first().locator('td').last()).toHaveText('N/A');
});

test('keeps the last valid analytics payload after an API failure', async ({ page }) => {
  let requests = 0;
  await page.route('**/api/analytics?*', route => {
    requests += 1;
    if (requests === 1) return route.fulfill({ json: analyticsPayload });
    return route.fulfill({ status: 503, contentType: 'application/json', body: JSON.stringify({ error: 'analytics archive is not available yet' }) });
  });
  await page.goto('/analytics.html');
  await expect(page.locator('#total-tokens')).toHaveText('1.73M');
  await page.evaluate(() => refresh());
  await expect(page.locator('#total-tokens')).toHaveText('1.73M');
  await expect(page.locator('#analytics-local-only')).toBeVisible();
  await expect(page.locator('#analytics-error')).toContainText('last successful data');
});

test('provides a non-chart fallback and supports custom dates', async ({ page }) => {
  const queries = [];
  await page.route('**/assets/chart.umd.min.js', route => route.abort());
  await page.route('**/api/analytics?*', route => {
    queries.push(new URL(route.request().url()).searchParams);
    return route.fulfill({ json: analyticsPayload });
  });
  await page.goto('/analytics.html');
  await expect(page.locator('#total-tokens')).toHaveText('1.73M');
  await expect(page.locator('#limits-chart-summary')).toContainText('2 limit samples');
  await expect(page.locator('#limits-chart-wrap')).toBeHidden();
  await page.locator('[data-range="custom"]').click();
  await page.locator('#from-date').fill('2026-03-29');
  await page.locator('#to-date').fill('2026-03-30');
  await page.locator('#apply-dates').click();
  await expect.poll(() => queries.at(-1)?.get('from_date')).toBe('2026-03-29');
  await expect.poll(() => queries.at(-1)?.get('to_date')).toBe('2026-03-30');
});

test('switches locale and currency and persists the preference across pages', async ({ page }) => {
  await mockUsage(page);
  await page.route('**/api/analytics?*', route => route.fulfill({ json: analyticsPayload }));
  await page.goto('/analytics.html');

  await expect(page.locator('.preference-controls select')).toHaveCount(0);
  await expect(page.locator('#language-toggle')).toHaveAttribute('data-selected', 'en');
  await expect(page.locator('#currency-toggle')).toHaveAttribute('data-selected', 'EUR');
  await page.locator('#currency-toggle').click();
  await expect(page.locator('#currency-toggle')).toHaveAttribute('data-selected', 'USD');
  await expect(page.locator('#estimated-cost')).toHaveText('$11.25');
  await expect(page.locator('#estimated-cost')).toHaveAttribute('title', '');

  await page.locator('#language-toggle').click();
  await expect(page.locator('#language-toggle')).toHaveAttribute('data-selected', 'fr');
  await expect(page.locator('html')).toHaveAttribute('lang', 'fr');
  await expect(page.locator('h1')).toHaveText('Analytics avancées');
  await expect(page.locator('#analytics-price-warnings')).toContainText('Aucun prix catalogue');
  await expect(page.locator('#estimated-cost')).toHaveText('11,25 $');
  await page.locator('#currency-toggle').click();
  await expect(page.locator('#currency-toggle')).toHaveAttribute('data-selected', 'EUR');
  await expect(page.locator('#estimated-cost')).toHaveText('9,68 €');
  await expect(page.locator('#estimated-cost')).toHaveAttribute('title', 'Converti depuis USD avec le taux fixe : 1 USD = 0,86 €');
  const frenchResults = await new AxeBuilder({ page }).analyze();
  expect(frenchResults.violations.filter(violation => violation.impact === 'critical')).toEqual([]);

  await page.goto('/dashboard.html');
  await expect(page.locator('#language-toggle')).toHaveAttribute('data-selected', 'fr');
  await expect(page.locator('#currency-toggle')).toHaveAttribute('data-selected', 'EUR');
  await expect(page.locator('h1')).toHaveText('Limites Codex');
  await expect(page.locator('.nav-link[href="analytics.html"]')).toContainText('Analytics avancées');
  await expect(page.locator('.dashboard-links .external-link')).toContainText('Dépôt GitHub');
  await expect(page.locator('.page-nav')).toHaveCount(0);
});
