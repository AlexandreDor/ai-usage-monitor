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
  await expect(page.locator('#five-hour-card')).toBeVisible();
  await expect(page.locator('#five-hour-title')).toHaveText('5-Hour Limit');
  await expect(page.locator('#weekly-title')).toHaveText('Weekly Limit');
  await expect(page.locator('.limit-card').first()).toHaveAttribute('aria-labelledby', 'five-hour-title');
  await expect(page.locator('.limit-card').last()).toHaveAttribute('aria-labelledby', 'weekly-title');
  await expect(page.locator('#five-h-bar')).toHaveAttribute('aria-label', '5-hour remaining quota');
  await expect(page.locator('#five-h-bar')).toHaveAttribute('aria-valuetext', '72% remaining');
  await expect(page.locator('#weekly-bar')).toHaveAttribute('aria-label', 'Weekly remaining quota');
  await expect(page.locator('#weekly-bar')).toHaveAttribute('aria-valuetext', '36% remaining');
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
  await expect(page.locator('#history-summary')).toHaveCount(0);
  await expect(page.locator('#history-details')).toHaveCount(0);
  await expect(page.locator('#history-table')).toHaveCount(0);
  await expect(page.locator('#history-chart')).toHaveAttribute('role', 'img');
  await expect(page.locator('#history-chart')).toHaveAttribute('aria-labelledby', 'history-label');
  await expect(page.locator('#history-chart')).not.toHaveAttribute('aria-describedby');
  await expect(page.locator('#history-chart')).not.toHaveAttribute('tabindex');
  const historyOrder = await page.locator('.history-card').evaluate(card => [
    ...card.children,
  ].map(child => child.id));
  expect(historyOrder.indexOf('history-error')).toBeLessThan(historyOrder.indexOf('history-chart'));
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
  await expect(page.locator('#five-h-pct')).toHaveText('--');
  await expect(page.locator('#five-h-bar')).toHaveClass(/unavailable/);
  await expect(page.locator('#five-h-bar')).not.toHaveAttribute('value');
  await expect(page.locator('#five-h-bar')).not.toHaveAttribute('aria-valuenow');
  await expect(page.locator('#weekly-bar')).not.toHaveAttribute('value');
  await expect(page.locator('#freshness-badge')).toBeHidden();
  await expect(page.locator('#freshness-detail')).toHaveText('Data unavailable');
  await expect(page.locator('#freshness-status')).toHaveText('Data unavailable');
  const results = await new AxeBuilder({ page }).analyze();
  expectNoAxeViolations(results, ['critical', 'serious']);
});

test('coalesces concurrent refreshes for the same source', async ({ page }) => {
  let dataRequests = 0;
  let releaseData;
  const dataResponse = new Promise(resolve => { releaseData = resolve; });
  await page.route('**/api/dashboard-heartbeat', route => route.fulfill({ status: 204 }));
  await page.route('**/data.json?*', async route => {
    dataRequests += 1;
    await dataResponse;
    await route.fulfill({ json: snapshot });
  });
  await page.route('**/history.json?*', route => route.fulfill({ json: [snapshot] }));
  await page.goto('/dashboard.html');
  await expect.poll(() => dataRequests).toBe(1);
  await page.evaluate(() => {
    window.__firstRefresh = refresh();
    window.__secondRefresh = refresh();
  });
  releaseData();
  await page.evaluate(() => Promise.all([window.__firstRefresh, window.__secondRefresh]));
  expect(dataRequests).toBe(1);
});

test('cancels a queued Gist refresh when returning to the active local source', async ({ page }) => {
  let dataRequests = 0;
  let gistRequests = 0;
  let releaseData;
  const dataResponse = new Promise(resolve => { releaseData = resolve; });
  await page.route('**/api/dashboard-heartbeat', route => route.fulfill({ status: 204 }));
  await page.route('**/data.json?*', async route => {
    dataRequests += 1;
    await dataResponse;
    await route.fulfill({ json: snapshot });
  });
  await page.route('**/history.json?*', route => route.fulfill({ json: [snapshot] }));
  await page.route('https://api.github.com/gists/**', async route => {
    gistRequests += 1;
    await route.fulfill({
      json: {
        files: {
          'data.json': { content: JSON.stringify(snapshot) },
          'history.json': { content: JSON.stringify([snapshot]) },
        },
      },
    });
  });
  await page.goto('/dashboard.html');
  await expect.poll(() => dataRequests).toBe(1);

  await page.evaluate(() => {
    GIST_ID = 'external-fixture';
    window.__gistRefresh = refresh();
    GIST_ID = '';
    window.__localRefresh = refresh();
  });
  releaseData();
  await page.evaluate(() => Promise.all([
    window.__gistRefresh,
    window.__localRefresh,
  ]));

  expect(gistRequests).toBe(0);
  expect(dataRequests).toBe(1);
  await expect(page.locator('#mode-badge')).toBeHidden();
  await expect(page.locator('body')).toHaveAttribute('data-dashboard-source', 'local');
  await expect(page.locator('#five-h-pct')).toHaveText('72%');
});

test('renders fresh external Gist data with independent source and freshness states', async ({ page }) => {
  await page.clock.install({ time: DASHBOARD_NOW });
  await page.route('**/api/dashboard-heartbeat', route => route.fulfill({ status: 204 }));
  let localRequestStarted = false;
  let releaseInitialLocal;
  const initialLocalResponse = new Promise(resolve => { releaseInitialLocal = resolve; });
  await page.route('**/data.json?*', async route => {
    localRequestStarted = true;
    await initialLocalResponse;
    await route.fulfill({ status: 503 });
  });
  await page.route('https://api.github.com/gists/**', route => route.fulfill({
    json: {
      files: {
        'data.json': { content: JSON.stringify(snapshot) },
        'history.json': { content: JSON.stringify([snapshot]) },
      },
    },
  }));
  await page.goto('/dashboard.html');
  await expect.poll(() => localRequestStarted).toBe(true);
  await page.evaluate(() => {
    GIST_ID = 'external-fixture';
    window.__externalRefresh = refresh();
  });
  releaseInitialLocal();
  await page.evaluate(() => window.__externalRefresh);

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
  await expect(page.locator('#history-summary')).toHaveCount(0);
  await expect(page.locator('#history-details')).toHaveCount(0);
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
  await expect(page.locator('#history-summary')).toHaveCount(0);
  await expect(page.locator('#history-details')).toHaveCount(0);
  await page.locator('#language-toggle').click();
  await expect(page.locator('#history-label')).toHaveText('Historique indisponible');
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
  await expect(page.locator('#history-summary')).toHaveCount(0);
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
  await expect(page.locator('#history-summary')).toHaveCount(0);
  await expect(page.locator('#error-banner')).toBeHidden();
  const results = await new AxeBuilder({ page }).analyze();
  expectNoAxeViolations(results, ['critical', 'serious']);
});

test('shows the weekly pace delta and direction as text', async ({ page }) => {
  const accessibleSnapshot = { ...snapshot, weekly_reset_at: 1786147200 };
  await page.clock.install({ time: DASHBOARD_NOW });
  await page.route('**/api/dashboard-heartbeat', route => route.fulfill({ status: 204 }));
  await page.route('**/data.json?*', route => route.fulfill({ json: accessibleSnapshot }));
  await page.route('**/history.json?*', route => route.fulfill({ json: [accessibleSnapshot] }));
  await page.goto('/dashboard.html');

  const paceDelta = page.locator('#weekly-pace-delta');
  await expect(paceDelta).toContainText('below');
  await expect(paceDelta).toContainText(' / ');
  await expect(paceDelta).not.toContainText(';');
  await expect(page.locator('#weekly-pace-delta')).toHaveAttribute('title', '');
  await expect(page.locator('body')).not.toContainText('—');
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
  expect(selection.body).toEqual(['Weekly Limit %: 40%', 'Forecast 24h: 76%', 'Forecast 6h: 10%']);
  expect(selection.caretX).toBeCloseTo(selection.expectedX, 1);
  expect(selection.mode).toBe('timeSlice');
  expect(selection.cursorRegistered).toBe(true);
});

const analyticsPayload = {
  schema_version: 1,
  period: { range: '30d', from: '2026-07-05T10:00:00Z', to: '2026-08-04T10:00:00Z', timezone: 'Europe/Paris', granularity_seconds: 86400 },
  filters: { sources: [], models: [], reset_type: 'all' },
  available: {
    sources: ['codex', 'opencode'],
    models: ['gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna', 'gpt-6-luna', 'gpt-6-sol', 'gpt-6.1-sol', 'gpt-6-astra', 'gpt-5.5', 'gpt-5.4', 'unknown-model'],
  },
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
  await page.locator('#weekly-limit-value-models').getByRole('button', { name: /All models/ }).click();

  await expect(page.locator('#total-tokens')).toHaveText('1.73M');
  await expect(page.locator('#assumed-zero-tokens')).toHaveCount(0);
  await expect(page.locator('#estimated-cost')).toHaveText('€9.68');
  await expect(page.locator('#allocation-total-cost')).toHaveText('€9.68');
  await expect(page.locator('#estimated-cost')).toHaveAttribute('title', 'Converted from USD using fixed rate: 1 USD = €0.86');
  await expect.poll(() => analyticsQueries[0]?.get('models')).toBe('gpt-5.6-luna,gpt-5.6-terra,gpt-5.6-sol,gpt-6-luna,gpt-6-sol,gpt-6.1-sol,gpt-6-astra');
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
  await expect(page.locator('#weekly-limit-value-summary')).toContainText('1 displayed estimate');
  await page.locator('#weekly-limit-value-card details summary').click();
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
  await expect(page.locator('#model-filter [data-filter-value]')).toHaveCount(10);
  for (const model of ['gpt-6-sol', 'gpt-6-luna', 'gpt-6.1-sol']) {
    await expect(page.locator(`#model-filter [data-filter-value="${model}"]`)).toHaveAttribute('aria-pressed', 'true');
  }
  for (const model of ['gpt-5.5', 'gpt-5.4', 'unknown-model']) {
    await expect(page.locator(`#model-filter [data-filter-value="${model}"]`)).toHaveAttribute('aria-pressed', 'false');
  }
  await expect(page.locator('#model-explorer')).toBeHidden();
  await expect(page.locator('#toggle-model-explorer')).toHaveAttribute('aria-expanded', 'false');
  await page.locator('#toggle-model-explorer').click();
  await page.getByRole('button', { name: 'GPT', exact: true }).click();
  await expect(page.locator('#apply-model-selection')).toBeDisabled();
  expect(analyticsQueries).toHaveLength(1);
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

test('stages model changes across searches and applies them with one request', async ({ page }) => {
  const queries = [];
  await page.route('**/api/analytics?*', route => {
    queries.push(new URL(route.request().url()).searchParams);
    return route.fulfill({ json: analyticsPayload });
  });
  await page.goto('/analytics.html');
  await expect(page.locator('#model-selection-summary')).toHaveText('7 of 10 selected');
  await expect(page.locator('#model-apply-bar')).toBeHidden();
  await expect(page.locator('#model-explorer')).toBeHidden();
  await page.locator('#toggle-model-explorer').click();
  await expect(page.locator('#model-search')).toBeFocused();
  await page.locator('#model-search').fill('  GPT-5.  ');
  await expect(page.locator('#model-filter [data-filter-value]:visible')).toHaveCount(5);
  await page.locator('[data-model-family="older"]').click();
  await expect(page.locator('#model-filter [data-filter-value]:visible')).toHaveCount(2);
  await page.locator('#select-visible-models').click();
  await expect(page.locator('#model-selection-summary')).toHaveText('9 of 10 selected');
  await page.locator('#model-search').fill('no-such-model');
  await expect(page.locator('#model-search-empty')).toContainText('No matching models');
  await expect(page.locator('#select-visible-models')).toBeDisabled();
  await expect(page.locator('#model-selection-tray [data-remove-model]')).toHaveCount(9);
  await page.locator('#model-selection-tray [data-remove-model="gpt-6-sol"]').click();
  await expect(page.locator('#model-draft-status')).toHaveText('3 changes ready to apply.');
  expect(queries).toHaveLength(1);
  await page.locator('#apply-model-selection').click();
  await expect.poll(() => queries.length).toBe(2);
  expect(queries[1].get('models').split(',')).toEqual(analyticsPayload.available.models.filter(model => !['gpt-6-sol', 'unknown-model'].includes(model)));
  expect(queries[1].get('breakdown_offset')).toBe('0');
  await expect(page.locator('#apply-model-selection')).toBeDisabled();
  await expect(page.locator('#model-search')).toHaveValue('no-such-model');
  await expect(page.locator('#model-apply-bar')).toBeHidden();
  await expect(page.locator('#toggle-model-explorer')).toBeFocused();
  await expect(page.locator('[data-model-family="older"]')).toHaveAttribute('aria-pressed', 'true');
});

test('keeps a model draft through refresh, translation and collapse and cancels explicitly', async ({ page }) => {
  const queries = [];
  await page.route('**/api/analytics?*', route => {
    queries.push(new URL(route.request().url()).searchParams);
    return route.fulfill({ json: analyticsPayload });
  });
  await page.goto('/analytics.html');
  await expect(page.locator('#model-selection-summary')).toHaveText('7 of 10 selected');
  await page.locator('#toggle-model-explorer').click();
  await page.locator('#clear-model-selection').click();
  await expect(page.locator('#apply-model-selection')).toBeDisabled();
  await expect(page.locator('#model-draft-status')).toContainText('Select at least one');
  await page.locator('[data-range="7d"]').click();
  await expect.poll(() => queries.length).toBe(2);
  expect(queries[1].get('models').split(',')).toHaveLength(7);
  await expect(page.locator('#model-explorer')).toBeVisible();
  await expect(page.locator('#model-selection-summary')).toHaveText('0 of 10 selected');
  await page.locator('#language-toggle').click();
  await expect(page.locator('#model-search')).toHaveAttribute('placeholder', 'Rechercher par nom de modèle…');
  await expect(page.locator('#model-draft-status')).toContainText('Sélectionnez au moins un modèle');
  await page.locator('#model-filter [data-filter-value="gpt-6.1-sol"]').focus();
  await page.keyboard.press('Space');
  await expect(page.locator('#model-filter [data-filter-value="gpt-6.1-sol"]')).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(page.locator('#model-explorer')).toBeHidden();
  await expect(page.locator('#toggle-model-explorer')).toBeFocused();
  await expect(page.locator('#apply-model-selection')).toBeVisible();
  await expect(page.locator('#apply-model-selection')).toBeEnabled();
  await page.locator('#model-selection-tray button').click();
  await expect(page.locator('#toggle-model-explorer')).toBeFocused();
  await expect(page.locator('#apply-model-selection')).toBeDisabled();
  await page.locator('#reset-model-selection').click();
  await expect(page.locator('#model-selection-summary')).toHaveText('7 sélectionnés sur 10');
  await expect(page.locator('#model-apply-bar')).toBeHidden();
  await expect(page.locator('#toggle-model-explorer')).toBeFocused();
  await page.locator('#toggle-model-explorer').click();
  await expect(page.locator('#model-search')).toBeFocused();
  await page.locator('#select-all-models').click();
  await page.locator('#toggle-model-explorer').click();
  await page.locator('#apply-model-selection').click();
  await expect.poll(() => queries.length).toBe(3);
  expect(queries[2].get('models').split(',')).toHaveLength(10);
  const results = await new AxeBuilder({ page }).include('.model-filter').analyze();
  expectNoAxeViolations(results, ['serious', 'critical']);
});

test('makes the model explorer usable on mobile and with an empty archive', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  let models = [];
  await page.route('**/api/analytics?*', route => route.fulfill({ json: {
    ...analyticsPayload, available: { ...analyticsPayload.available, models },
  } }));
  await page.goto('/analytics.html');
  await expect(page.locator('#model-explorer')).toBeHidden();
  await page.locator('#toggle-model-explorer').click();
  await expect(page.locator('#model-search-empty')).toContainText('Models will appear here');
  await expect(page.locator('#model-selection-summary')).toHaveText('0 of 0 selected');
  await expect(page.locator('#model-selection-tray button')).toHaveCount(0);
  await expect(page.locator('#select-gpt')).toBeDisabled();
  await expect(page.locator('#select-all-models')).toBeDisabled();
  models = [...analyticsPayload.available.models, 'a-very-long-local-model-identifier-that-should-wrap-rather-than-break-the-layout:latest'];
  await page.locator('[data-range="7d"]').click();
  await expect(page.locator('#model-selection-summary')).toHaveText('7 of 11 selected');
  await page.locator('#select-all-models').click();
  for (const id of ['model-filter', 'model-selection-tray']) {
    const layout = await page.locator(`#${id}`).evaluate(element => ({
      maxHeight: getComputedStyle(element).maxHeight,
      overflowY: getComputedStyle(element).overflowY,
      scrollHeight: element.scrollHeight,
      clientHeight: element.clientHeight,
    }));
    expect(layout.maxHeight).toBe('none');
    expect(layout.overflowY).toBe('visible');
    expect(layout.scrollHeight).toBeLessThanOrEqual(layout.clientHeight);
  }
  await page.locator('#reset-model-selection').click();
  await page.locator('[data-model-family="other"]').click();
  await page.locator('#model-search').fill('very-long');
  await page.locator('#select-visible-models').click();
  await expect(page.locator('#model-selection-tray [data-remove-model]')).toHaveCount(8);
  const layout = await page.locator('.model-filter').evaluate(element => ({
    left: element.getBoundingClientRect().left,
    right: element.getBoundingClientRect().right,
    viewport: innerWidth,
    overflow: element.scrollWidth > element.clientWidth,
  }));
  expect(layout.left).toBeGreaterThanOrEqual(0);
  expect(layout.right).toBeLessThanOrEqual(layout.viewport);
  expect(layout.overflow).toBe(false);
  const results = await new AxeBuilder({ page }).include('.model-filter').analyze();
  expectNoAxeViolations(results, ['serious', 'critical']);
});

test('hides analytics warning containers when the API returns no warnings', async ({ page }) => {
  await page.route('**/api/analytics?*', route => route.fulfill({ json: { ...analyticsPayload, warnings: [] } }));
  await page.goto('/analytics.html');

  await expect(page.locator('#analytics-warnings')).toBeHidden();
  await expect(page.locator('#analytics-price-warnings')).toBeHidden();
});

test('falls back once to all models when GPT is unavailable', async ({ page }) => {
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
  expect(queries[0].get('models')).toBe('gpt-5.6-luna,gpt-5.6-terra,gpt-5.6-sol,gpt-6-luna,gpt-6-sol,gpt-6.1-sol,gpt-6-astra');
  expect(queries[1].get('models')).toBe('legacy-model,unknown-model');
  await expect(page.locator('#analytics-error')).toContainText('No supported GPT model is available');
  await page.waitForTimeout(100);
  expect(queries).toHaveLength(2);
});

test('selects GPT when models appear after an initially empty archive', async ({ page }) => {
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
  availableModels = ['gpt-6.1-sol', 'gpt-5.5', 'legacy-model'];
  await page.locator('[data-range="7d"]').click();

  await expect.poll(() => queries.length).toBe(2);
  await expect(page.locator('#model-filter [data-filter-value="gpt-6.1-sol"]')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('#model-filter [data-filter-value="gpt-5.5"]')).toHaveAttribute('aria-pressed', 'false');
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
  await page.locator('#limits-chart-card details summary').click();
  await expect(page.locator('#limits-data-body tr').first().locator('td')).toHaveCount(6);
  await expect(page.locator('#breakdown-body tr td')).toHaveCount(11);
  await expect(page.locator('#reset-pagination')).toBeVisible();
  await expect(page.locator('#reset-page-label')).toHaveText('1–50 of 55');
  await expect(page.locator('#collector-grid')).toContainText('database unavailable');
  await expect(page.locator('#token-metric-toggle')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('#tokens-chart-card')).toBeHidden();
  await expect(page.locator('#reset-filter')).toHaveValue('weekly');
  await expect.poll(() => page.evaluate(() => new URLSearchParams(queryString()).get('reset_type'))).toBe('weekly');
  await expect(page.locator('#resets-body tr').first().locator('td')).toHaveCount(8);
  await expect(page.locator('#resets-body tr').first().locator('td').last()).toHaveText('Forecast 24h: 64% · Forecast 6h: 22%');

  await expect.poll(() => page.evaluate(() => limitsChart.data.datasets.filter(dataset => dataset.resetMarker).length)).toBe(2);
  await expect.poll(() => page.evaluate(() => tokensChart.data.datasets.length)).toBe(2);
  await expect.poll(() => page.evaluate(() => limitsChart.data.datasets.find(dataset => dataset.label === 'codex')?.data[0]?.y)).toBe(11.25);
  await expect.poll(() => page.evaluate(() => limitsChart.data.datasets.find(dataset => dataset.label === 'Ideal weekly pace')?.data[1]?.y)).toBe(51.2);
  await expect.poll(() => page.evaluate(() => limitsChart.data.datasets.filter(dataset => dataset.valueKind === 'percent').length)).toBe(5);
  await expect.poll(() => page.evaluate(() => limitsChart.data.datasets.find(dataset => dataset.datasetKey === 'five-hour')?.hidden)).toBe(true);
  await expect.poll(() => page.evaluate(() => limitsChart.data.datasets.find(dataset => dataset.datasetKey === 'reset-5h')?.hidden)).toBe(true);
  await page.evaluate(() => {
    const index = limitsChart.data.datasets.findIndex(dataset => dataset.datasetKey === 'five-hour');
    limitsChart.show(index);
    limitsChart.update('none');
  });
  await expect.poll(() => page.evaluate(() => limitsChart.isDatasetVisible(limitsChart.data.datasets.findIndex(dataset => dataset.datasetKey === 'five-hour')))).toBe(true);
  await page.evaluate(() => refresh());
  await expect.poll(() => page.evaluate(() => limitsChart.isDatasetVisible(limitsChart.data.datasets.findIndex(dataset => dataset.datasetKey === 'five-hour')))).toBe(true);
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
  await expect(page.locator('#breakdown-section-status')).toContainText('temporary pagination failure');
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
  await page.locator('#limits-chart-card details summary').click();
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
  await expect(page.locator('#analytics-local-only')).toBeHidden();
  await expect(page.locator('#analytics-error')).toContainText('last successful data');
});

for (const status of [404, 503]) {
  test(`distinguishes missing analytics API from an archive failure (${status})`, async ({ page }) => {
    await page.route('**/api/analytics?*', route => route.fulfill({ status,
      json: { error: status === 503 ? 'analytics archive cannot be read' : 'HTTP 404' } }));
    await page.goto('/analytics.html');
    await expect(page.locator('#analytics-error')).toBeVisible();
    if (status === 404) await expect(page.locator('#analytics-local-only')).toBeVisible();
    else await expect(page.locator('#analytics-local-only')).toBeHidden();
  });
}

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



test('shows seven GPT curves by default and lets users enable the aggregate', async ({ page }) => {
  const value = analyticsPayload.weekly_limit_value;
  const names = ['gpt-5.6-luna', 'gpt-5.6-terra', 'gpt-5.6-sol', 'gpt-6-luna', 'gpt-6-sol', 'gpt-6.1-sol', 'gpt-6-astra'];
  const payload = { ...analyticsPayload, weekly_limit_value: { ...value, by_model: names.map((model, index) => ({
    ...value, providers: model === 'gpt-5.6-sol' ? ['auto', 'openai', 'openai-codex'] : ['openai'], model, series: [{ ...value.series[0], value_usd: 100 + index * 25, raw_value_usd: 100 + index * 25 }],
  })) } };
  await page.route('**/api/analytics?*', route => route.fulfill({ json: payload }));
  await page.goto('/analytics.html');
  const controls = page.locator('#weekly-limit-value-models');
  await expect(controls.getByRole('button', { name: /All models/ })).toHaveAttribute('aria-pressed', 'false');
  await expect(controls.locator('button[aria-pressed="true"]')).toHaveCount(7);
  await expect(controls.getByRole('button', { name: 'gpt-6.1-sol', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect.poll(() => page.evaluate(() => weeklyLimitValueChart.data.datasets.map(item => item.data[0].y))).toEqual([100, 125, 150, 175, 200, 225, 250]);
  await expect.poll(() => page.evaluate(() => new Set(weeklyLimitValueChart.data.datasets.map(item => item.borderColor)).size)).toBe(7);
  await page.locator('#weekly-limit-value-card details summary').click();
  await expect(page.locator('#weekly-limit-value-data-body tr')).toHaveCount(7);
  await expect(page.locator('#weekly-limit-value-data-body')).toContainText('gpt-6.1-sol');
  await expect(page.locator('#weekly-limit-value-data-body')).toContainText('gpt-6-astra');
  await expect(controls.getByRole('button', { name: 'gpt-5.6-sol', exact: true })).toBeVisible();
  const sol = controls.getByRole('button', { name: 'gpt-5.6-sol', exact: true });
  await expect(sol).toHaveAttribute('title', 'auto, openai, openai-codex');
  await expect.poll(() => page.evaluate(() => weeklyLimitValueChart.data.datasets.map(item => item.borderColor))).toEqual(['#a78bfa', '#34d399', '#fbbf24', '#60a5fa', '#f97316', '#e879f9', '#fb7185']);
  await sol.click();
  await expect(sol).toHaveAttribute('aria-pressed', 'false');
  await expect(sol).toBeFocused();
  await expect.poll(() => page.evaluate(() => weeklyLimitValueChart.data.datasets.length)).toBe(6);
  await sol.press('Space');
  await expect(sol).toHaveAttribute('aria-pressed', 'true');
  await expect.poll(() => page.evaluate(() => weeklyLimitValueChart.data.datasets.length)).toBe(7);
  await page.setViewportSize({ width: 390, height: 844 });
  await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  for (let index = 0; index < names.length; index += 1) {
    await controls.locator('button[aria-pressed="true"]').first().click();
  }
  await expect(page.locator('#weekly-limit-value-empty')).toBeVisible();
  await controls.getByRole('button', { name: /All models/ }).click();
  await expect.poll(() => page.evaluate(() => weeklyLimitValueChart.data.datasets[0].data[0].y)).toBe(75);
});

test('keeps missing GPT estimates visible without inventing curve points', async ({ page }) => {
  const value = analyticsPayload.weekly_limit_value;
  const payload = { ...analyticsPayload, weekly_limit_value: { ...value, by_model: [
    { ...value, provider: 'openai', model: 'gpt-5.6-terra', series: [{ ...value.series[0], value_usd: null, raw_value_usd: null, quality: 'unavailable', reason: 'mixed_models', mixed_model_reason: 'mixed_model_insufficient_samples', mixed_model_sample_count: 2, mixed_model_minimum_samples: 8 }], unavailable_reasons: { mixed_models: 1 } },
  ] } };
  await page.route('**/api/analytics?*', route => route.fulfill({ json: payload }));
  await page.goto('/analytics.html');
  const controls = page.locator('#weekly-limit-value-models');
  await expect(controls.getByRole('button', { name: /All models/ })).toHaveAttribute('aria-pressed', 'false');
  await expect(controls.locator('button[aria-pressed="true"]')).toHaveCount(7);
  await expect(controls.getByText('No estimate', { exact: true })).toHaveCount(7);
  await expect.poll(() => page.evaluate(() => weeklyLimitValueDatasets.every(item => item.data.length === 0))).toBe(true);
  await page.locator('#weekly-limit-value-card details summary').click();
  await expect(page.locator('#weekly-limit-value-data-body')).toContainText('2 prior non-overlapping windows available; 8 required');
});

test('labels mixed-window inference as shared-quota and low confidence', async ({ page }) => {
  const value = analyticsPayload.weekly_limit_value;
  const inferred = {
    ...value.series[0], value_usd: 125, raw_value_usd: 125,
    quality: 'low_confidence', reason: null, inferred: true,
    attribution: 'mixed_model_regression', training_sample_count: 8,
  };
  const payload = { ...analyticsPayload, weekly_limit_value: { ...value, by_model: [
    { ...value, provider: 'openai', model: 'gpt-5.6-sol', series: [inferred], unavailable_reasons: {} },
  ] } };
  await page.route('**/api/analytics?*', route => route.fulfill({ json: payload }));
  await page.goto('/analytics.html');
  await page.locator('#weekly-limit-value-card details summary').click();
  const row = page.locator('#weekly-limit-value-data-body tr').filter({ hasText: 'gpt-5.6-sol' });
  await expect(row).toContainText('Low confidence');
  await expect(row).toContainText('Inferred from shared quota');
  await expect(row.locator('.value-inferred')).toHaveAttribute('title', /8 prior non-overlapping windows/);
  await expect.poll(() => page.evaluate(() => weeklyLimitValueChart.data.datasets
    .find(item => item.label === 'gpt-5.6-sol').pointStyle[0])).toBe('star');
});

test('distinguishes carried weekly values from newly calculated points', async ({ page }) => {
  const value = analyticsPayload.weekly_limit_value;
  const direct = { ...value.series[0], at: '2026-08-03T18:00:00Z', value_usd: 125, raw_value_usd: 125 };
  const carried = {
    ...direct, at: '2026-08-04T00:00:00Z', raw_value_usd: null,
    quality: 'low_confidence', reason: null, carried: true,
    carried_from_reason: 'reset_in_window', source_at: direct.at,
    mixed_model_reason: 'mixed_model_insufficient_samples', mixed_model_sample_count: 2, mixed_model_minimum_samples: 8,
    source_age_seconds: 21600, source_method: 'exclusive_model_window', source_quality: 'good',
  };
  const payload = { ...analyticsPayload, weekly_limit_value: { ...value, by_model: [
    { ...value, provider: 'openai', model: 'gpt-5.6-sol', series: [direct, carried], unavailable_reasons: {} },
  ] } };
  await page.route('**/api/analytics?*', route => route.fulfill({ json: payload }));
  await page.goto('/analytics.html');
  await page.locator('#weekly-limit-value-card details summary').click();
  const row = page.locator('#weekly-limit-value-data-body tr').filter({ hasText: 'Carried from' });
  await expect(row).toContainText('Low confidence');
  await expect(row.locator('.value-carried')).toHaveAttribute('title', /Direct exclusive-window estimate.*6h old.*reset/i);
  await expect.poll(() => page.evaluate(() => {
    const dataset = weeklyLimitValueChart.data.datasets.find(item => item.label === 'gpt-5.6-sol');
    return [dataset.pointStyle[1], dataset.pointBackgroundColor[1], dataset.segment.borderDash({ p0DataIndex: 0, p1DataIndex: 1 })];
  })).toEqual(['circle', 'transparent', [6, 4]]);
});

test('shows uncertain model values and sensitivity ranges including unbounded carry', async ({ page }) => {
  const value = analyticsPayload.weekly_limit_value;
  const uncertain = {
    ...value.series[0], value_usd: 60, raw_value_usd: 60, inferred: true,
    quality: 'high_uncertainty', reason: null, value_lower_usd: 35, value_upper_usd: 150,
    uncertainty_method: 'assumed_1_point_quota_error_sensitivity',
    coefficient_fraction_per_usd: 1 / 60, coefficient_error_bound_fraction_per_usd: 0.01,
  };
  const carried = { ...uncertain, value_upper_usd: null, carried: true, source_at: uncertain.at,
    source_age_seconds: 3600, source_quality: 'high_uncertainty', source_method: 'mixed_model_regression',
    carried_from_reason: 'mixed_model_target_absent' };
  const payload = { ...analyticsPayload, weekly_limit_value: { ...value, by_model: [
    { model: 'gpt-5.6-luna', providers: ['openai'], series: [uncertain], unavailable_reasons: {} },
    { model: 'gpt-5.6-terra', providers: ['openai'], series: [carried], unavailable_reasons: {} },
  ] } };
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.route('**/api/analytics?*', route => route.fulfill({ json: payload }));
  await page.goto('/analytics.html');
  await page.locator('#weekly-limit-value-card details summary').click();
  const table = page.locator('#weekly-limit-value-data-body');
  await expect(table.locator('tr').filter({ hasText: 'gpt-5.6-luna' })).toContainText('$35.00–$150.00');
  const terra = table.locator('tr').filter({ hasText: 'gpt-5.6-terra' });
  await expect(terra).toContainText('$35.00–unbounded');
  await expect(terra.locator('.value-carried')).toContainText('High uncertainty');
  await expect.poll(() => page.evaluate(() => weeklyLimitValueChart.data.datasets.slice(0, 2)
    .map(d => d.pointStyle[0]))).toEqual(['crossRot', 'crossRot']);
  await expect(page.locator('#weekly-limit-value-quality')).toContainText('not statistical confidence intervals');
  expect(errors).toEqual([]);
});

test('defers closed chart tables and refreshes opened tables with keyboard access', async ({ page }) => {
  let current = analyticsPayload;
  await page.route('**/api/analytics?*', route => route.fulfill({ json: current }));
  await page.goto('/analytics.html');
  await expect(page.locator('#total-tokens')).toHaveText('1.73M');
  for (const id of ['limits-data-body', 'weekly-limit-value-data-body', 'tokens-data-body']) {
    await expect(page.locator(`#${id} tr`)).toHaveCount(0);
  }
  const summary = page.locator('#limits-chart-card details summary');
  await summary.focus();
  await summary.press('Enter');
  await expect(page.locator('#limits-data-body tr')).toHaveCount(2);
  current = { ...analyticsPayload, limits: { ...analyticsPayload.limits, series: [{ ...analyticsPayload.limits.series[0], weekly_pct: 13 }] } };
  await page.evaluate(() => refresh());
  await expect(page.locator('#limits-data-body tr')).toHaveCount(1);
  await expect(page.locator('#limits-data-body')).toContainText('13%');
  await summary.press('Space');
  current = analyticsPayload;
  await page.evaluate(() => refresh());
  await expect(page.locator('#limits-data-body tr')).toHaveCount(0);
  await summary.press('Enter');
  await expect(page.locator('#limits-data-body tr')).toHaveCount(2);
});

test('progressively loads compatible sections and scopes pagination to the affected section', async ({ page }) => {
  const requests = [];
  let releaseWeekly;
  const weeklyReady = new Promise(resolve => { releaseWeekly = resolve; });
  const base = { ...analyticsPayload, revision: 'fixture-1', pending_sections: ['weekly', 'resets'] };
  delete base.weekly_limit_value;
  await page.route('**/api/analytics?*', async route => {
    const query = new URL(route.request().url()).searchParams;
    requests.push(query);
    const section = query.get('sections');
    if (section === 'weekly') {
      await weeklyReady;
      return route.fulfill({ json: { period: base.period, revision: base.revision, weekly_limit_value: analyticsPayload.weekly_limit_value } });
    }
    if (section === 'resets') return route.fulfill({ json: { period: base.period, revision: base.revision, resets: { ...enhancedAnalyticsPayload.resets, offset: Number(query.get('reset_offset') || 0) } } });
    if (section === 'breakdown') return route.fulfill({ json: { period: base.period, revision: base.revision, tokens: analyticsPayload.tokens } });
    return route.fulfill({ json: base });
  });
  await page.goto('/analytics.html');
  await expect(page.locator('#total-tokens')).toHaveText('1.73M');
  await expect(page.locator('#analytics-loading')).toBeHidden();
  await expect(page.locator('#weekly-section-status')).toContainText('Loading');
  await expect(page.locator('#resets-body tr')).toHaveCount(1);
  expect(requests[0].get('sections')).toBe('base');
  for (const query of requests.slice(1)) expect(query.get('at')).toBe(String(Date.parse(base.period.to) / 1000));
  releaseWeekly();
  await expect(page.locator('#weekly-section-status')).toBeHidden();
  await expect.poll(() => page.evaluate(() => weeklyLimitValueDatasets.length)).toBe(7);
  const before = requests.length;
  await page.locator('#resets-next').click();
  await expect(page.locator('#reset-page-label')).toHaveText('51–55 of 55');
  expect(requests.slice(before).map(query => query.get('sections'))).toEqual(['resets']);
  await page.evaluate(() => refresh({ section: 'breakdown' }));
  expect(requests.at(-1).get('sections')).toBe('breakdown');
});

test('falls back to one coherent response after repeated revision mismatches', async ({ page }) => {
  let bases = 0;
  const requests = [];
  await page.route('**/api/analytics?*', route => {
    const section = new URL(route.request().url()).searchParams.get('sections');
    requests.push(section);
    if (section === 'base') {
      bases += 1;
      const base = { ...analyticsPayload, revision: `base-${bases}`, pending_sections: ['weekly', 'resets'] };
      delete base.weekly_limit_value;
      return route.fulfill({ json: base });
    }
    if (section === 'weekly') return route.fulfill({ json: { period: analyticsPayload.period, revision: 'changed', weekly_limit_value: analyticsPayload.weekly_limit_value } });
    if (section === 'full') return route.fulfill({ json: { ...analyticsPayload, resets: enhancedAnalyticsPayload.resets } });
    return route.fulfill({ status: 500, json: { error: 'reset calculation failed' } });
  });
  await page.goto('/analytics.html');
  await expect.poll(() => requests.filter(section => section === 'full').length).toBe(1);
  await expect(page.locator('#analytics-error')).toBeHidden();
  await expect(page.locator('#weekly-section-status')).toBeHidden();
  await expect(page.locator('#resets-section-status')).toBeHidden();
  await expect(page.locator('#total-tokens')).toHaveText('1.73M');
  expect(bases).toBe(2);
  expect(requests.filter(section => section === 'weekly')).toHaveLength(2);
});

test('anchors all-history sections to server time when the browser clock is behind', async ({ page }) => {
  const serverNow = new Date('2026-10-09T02:30:00Z');
  await page.clock.install({ time: new Date(serverNow.getTime() - 3600000) });
  const queries = [];
  const period = { ...analyticsPayload.period, range: 'all', to: serverNow.toISOString() };
  const base = { ...analyticsPayload, period, revision: 'clock-skew', pending_sections: ['weekly', 'resets'] };
  delete base.weekly_limit_value;
  await page.route('**/api/analytics?*', route => {
    const query = new URL(route.request().url()).searchParams;
    queries.push(query);
    if (query.get('sections') === 'base') return route.fulfill({ json: base });
    const anchored = query.get('at') === String(serverNow.getTime() / 1000);
    const componentPeriod = anchored ? period : { ...period, to: new Date(serverNow.getTime() + 1000).toISOString() };
    return route.fulfill({ json: { period: componentPeriod, revision: base.revision,
      weekly_limit_value: analyticsPayload.weekly_limit_value, resets: enhancedAnalyticsPayload.resets } });
  });
  await page.goto('/analytics.html?range=all');
  await expect.poll(() => queries.length).toBe(3);
  await expect(page.locator('#weekly-section-status')).toBeHidden();
  await expect(page.locator('#resets-section-status')).toBeHidden();
  await expect(page.locator('#analytics-error')).toBeHidden();
  for (const query of queries.slice(1)) expect(query.get('at')).toBe(String(serverNow.getTime() / 1000));
});

test('keeps a failed coherent fallback bounded and visible', async ({ page }) => {
  const requests = [];
  await page.route('**/api/analytics?*', route => {
    const section = new URL(route.request().url()).searchParams.get('sections');
    requests.push(section);
    if (section === 'full') return route.fulfill({ status: 503, json: { error: 'analytics archive cannot be read' } });
    if (section === 'base') {
      const base = { ...analyticsPayload, revision: 'base', pending_sections: ['weekly'] };
      delete base.weekly_limit_value;
      return route.fulfill({ json: base });
    }
    return route.fulfill({ json: { period: analyticsPayload.period, revision: 'changed' } });
  });
  await page.goto('/analytics.html');
  await expect(page.locator('#analytics-error')).toContainText('analytics archive cannot be read');
  await expect(page.locator('#analytics-local-only')).toBeHidden();
  expect(requests).toEqual(['base', 'weekly', 'base', 'weekly', 'full']);
  await expect(page.locator('#weekly-section-status')).toContainText('analytics archive cannot be read');
  await expect(page.locator('#resets-section-status')).toBeHidden();
});

test('labels retained old sections while a coherent fallback loads and after it fails', async ({ page }) => {
  let phase = 'initial';
  let fullRequested = false;
  let releaseFull;
  const fullReady = new Promise(resolve => { releaseFull = resolve; });
  const nextPeriod = { ...analyticsPayload.period, range: '24h', from: '2026-10-08T02:30:00Z', to: '2026-10-09T02:30:00Z' };
  await page.route('**/api/analytics?*', async route => {
    const section = new URL(route.request().url()).searchParams.get('sections');
    if (phase === 'initial') return route.fulfill({ json: { ...analyticsPayload, resets: enhancedAnalyticsPayload.resets } });
    if (section === 'base') {
      const base = { ...analyticsPayload, period: nextPeriod, revision: 'next', pending_sections: ['weekly', 'resets'] };
      delete base.weekly_limit_value;
      return route.fulfill({ json: base });
    }
    if (section === 'full') {
      fullRequested = true;
      await fullReady;
      return route.fulfill({ status: 503, json: { error: 'analytics archive cannot be read' } });
    }
    return route.fulfill({ json: { period: nextPeriod, revision: 'different',
      weekly_limit_value: analyticsPayload.weekly_limit_value, resets: enhancedAnalyticsPayload.resets } });
  });
  await page.goto('/analytics.html');
  await expect(page.locator('#resets-body tr')).toHaveCount(1);
  const oldSections = await page.evaluate(() => JSON.stringify([weeklyValueData, displayedResetData]));
  phase = 'changed';
  await page.evaluate(() => { state.range = '24h'; void refresh(); });
  await expect.poll(() => fullRequested).toBe(true);
  for (const card of ['weekly-limit-value-card', 'reset-history-card']) {
    await expect(page.locator(`#${card}`)).toHaveAttribute('aria-busy', 'true');
  }
  releaseFull();
  await expect(page.locator('#analytics-error')).toContainText('analytics archive cannot be read');
  for (const section of ['weekly', 'resets']) {
    await expect(page.locator(`#${section}-section-status`)).toContainText('Showing the last successful data');
  }
  expect(await page.evaluate(() => JSON.stringify([weeklyValueData, displayedResetData]))).toBe(oldSections);
});

test('retains explicit unavailable models and validated filters through reload and local navigation', async ({ page }) => {
  const queries = [];
  await mockUsage(page);
  await page.route('**/api/analytics?*', route => {
    queries.push(new URL(route.request().url()).searchParams);
    return route.fulfill({ json: analyticsPayload });
  });
  await page.goto('/analytics.html?range=7d&sources=codex&models=retired-model&reset_type=5h');
  await expect(page.locator('#total-tokens')).toHaveText('1.73M');
  const unavailable = page.locator('#model-filter button').filter({ hasText: 'retired-model' });
  await expect(unavailable).toHaveAttribute('aria-pressed', 'true');
  await expect(unavailable).toHaveAttribute('title', 'Unavailable in this archive');
  expect(queries[0].get('models')).toBe('retired-model');
  await page.reload();
  await expect(unavailable).toHaveAttribute('aria-pressed', 'true');
  await page.getByRole('link', { name: 'Live limits' }).click();
  await page.getByRole('link', { name: 'Advanced analytics' }).click();
  await expect(unavailable).toHaveAttribute('aria-pressed', 'true');
  expect(queries.at(-1).get('range')).toBe('7d');
  expect(queries.at(-1).get('sources')).toBe('codex');
  expect(queries.at(-1).get('reset_type')).toBe('5h');
  await page.goto('/analytics.html?range=invalid&sources=not-real&models=&from_date=2026-02-31&to_date=2026-03-02');
  await expect(page.locator('#total-tokens')).toHaveText('1.73M');
  expect(queries.at(-1).get('from_date')).toBeNull();
  expect(queries.at(-1).get('sources')).toBe('codex,opencode,hermes');
});

test('remembers applied model batches while pending changes stay scoped to the page', async ({ page }) => {
  const queries = [];
  await page.route('**/api/analytics?*', route => {
    queries.push(new URL(route.request().url()).searchParams);
    return route.fulfill({ json: analyticsPayload });
  });
  await page.goto('/analytics.html?range=7d');
  await expect(page.locator('#model-selection-summary')).toHaveText('7 of 10 selected');
  await expect(page.locator('[data-range="7d"]')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('[data-range="30d"]')).toHaveAttribute('aria-pressed', 'false');
  await page.locator('#toggle-model-explorer').click();
  await page.locator('#model-selection-tray [data-remove-model="gpt-6-sol"]').click();
  await page.locator('#model-filter [data-filter-value="gpt-5.5"]').click();
  await page.locator('[data-range="90d"]').click();
  await expect.poll(() => queries.length).toBe(2);
  expect(queries[1].get('models').split(',')).toContain('gpt-6-sol');
  expect(queries[1].get('models').split(',')).not.toContain('gpt-5.5');
  await expect(page.locator('#model-draft-status')).toHaveText('2 changes ready to apply.');
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem('codex-usage-monitor.analytics-filters')).models)).toBeUndefined();
  await page.locator('#apply-model-selection').click();
  await expect.poll(() => queries.length).toBe(3);
  const selected = queries[2].get('models').split(',');
  expect(selected).toContain('gpt-5.5');
  expect(selected).not.toContain('gpt-6-sol');
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem('codex-usage-monitor.analytics-filters')).models)).toEqual(selected);
  expect(new URL(page.url()).searchParams.get('models').split(',')).toEqual(selected);
  await page.reload();
  await expect(page.locator('#model-selection-summary')).toHaveText('7 of 10 selected');
  await expect(page.locator('#model-selection-tray [data-remove-model="gpt-5.5"]')).toBeVisible();
  await expect(page.locator('#model-selection-tray [data-remove-model="gpt-6-sol"]')).toHaveCount(0);
  await expect(page.locator('#model-apply-bar')).toBeHidden();
});

test('keeps remembered and drafted unavailable models visible through catalog refreshes', async ({ page }) => {
  let models = [...analyticsPayload.available.models];
  const queries = [];
  await page.route('**/api/analytics?*', route => {
    queries.push(new URL(route.request().url()).searchParams);
    return route.fulfill({ json: { ...analyticsPayload, available: { ...analyticsPayload.available, models } } });
  });
  await page.goto('/analytics.html?models=retired-model');
  const retiredChip = page.locator('#model-selection-tray [data-remove-model="retired-model"]');
  await expect(retiredChip).toHaveAttribute('title', 'Unavailable in this archive');
  await expect(page.locator('#model-selection-summary')).toHaveText('1 of 11 selected');
  await page.locator('#toggle-model-explorer').click();
  await page.locator('#model-search').fill('retired');
  await expect(page.locator('#model-filter [data-filter-value]:visible')).toHaveCount(1);
  await page.locator('#select-gpt').click();
  await page.locator('#reset-model-selection').click();
  await expect(retiredChip).toBeVisible();
  await page.locator('#model-search').fill('');
  await page.locator('#model-filter [data-filter-value="gpt-6-sol"]').click();
  models = models.filter(model => model !== 'gpt-6-sol');
  await page.locator('[data-range="7d"]').click();
  await expect.poll(() => queries.length).toBe(2);
  expect(queries[1].get('models')).toBe('retired-model');
  await expect(page.locator('#model-selection-tray [data-remove-model="gpt-6-sol"]')).toHaveAttribute('title', 'Unavailable in this archive');
  await expect(page.locator('#model-draft-status')).toHaveText('1 changes ready to apply.');
  await page.locator('#apply-model-selection').click();
  await expect.poll(() => queries.length).toBe(3);
  expect(queries[2].get('models').split(',').sort()).toEqual(['gpt-6-sol', 'retired-model']);
  await page.reload();
  await expect(retiredChip).toBeVisible();
  await expect(page.locator('#model-selection-tray [data-remove-model="gpt-6-sol"]')).toBeVisible();
  await expect(page.locator('#model-apply-bar')).toBeHidden();
});

test('coalesces rapid filter changes and exposes comparison and filtered CSV exports', async ({ page }) => {
  const queries = [];
  await page.route('**/api/analytics?*', route => {
    const query = new URL(route.request().url()).searchParams;
    queries.push(query);
    return route.fulfill({ json: { ...analyticsPayload, comparison: query.get('compare') === 'previous' ? {
      period: analyticsPayload.period, tokens: { summary: { input_tokens: 1000000, estimated_cost_usd: 10 } },
    } : undefined } });
  });
  await page.goto('/analytics.html');
  await expect(page.locator('#total-tokens')).toHaveText('1.73M');
  await page.evaluate(() => {
    document.querySelector('[data-range="7d"]').click();
    document.querySelector('[data-range="90d"]').click();
    document.querySelector('[data-range="1y"]').click();
  });
  await expect.poll(() => queries.at(-1).get('range')).toBe('1y');
  expect(queries).toHaveLength(2);
  await page.locator('#compare-previous').check();
  await expect(page.locator('#comparison-summary')).toContainText('+725,000');
  await expect(page.locator('#comparison-summary')).toContainText('+€1.08');
  await page.locator('.analytics-tools summary').click();
  await page.locator('#csv-dataset').selectOption('breakdown');
  const href = await page.locator('#csv-download').getAttribute('href');
  const params = new URL(href, 'http://localhost').searchParams;
  expect(params.get('dataset')).toBe('breakdown');
  expect(params.get('range')).toBe('1y');
  expect(params.get('models')).toContain('gpt-6.1-sol');
  expect(params.has('breakdown_offset')).toBe(false);
  const downloaded = page.waitForEvent('download');
  await page.locator('#csv-download').click();
  const download = await downloaded;
  // Chromium downloads bypass page request routing; endpoint CSV content is covered by HTTP tests.
  expect(new URL(download.url()).pathname).toBe('/api/analytics.csv');
  expect(new URL(download.url()).searchParams.get('dataset')).toBe('breakdown');
  const axe = await new AxeBuilder({ page }).analyze();
  expectNoAxeViolations(axe, ['critical', 'serious']);
});

test('shares validated time-zone and dated exchange-rate preferences across pages', async ({ page }) => {
  const queries = [];
  await mockUsage(page);
  await page.route('**/api/analytics?*', route => {
    queries.push(new URL(route.request().url()).searchParams);
    return route.fulfill({ json: analyticsPayload });
  });
  await page.goto('/analytics.html');
  await expect(page.locator('#estimated-cost')).toHaveText('€9.68');
  await page.locator('.advanced-preferences summary').click();
  const rate = page.locator('[data-preference-input="usdToEurRate"]');
  await rate.fill('0.9');
  await rate.blur();
  await expect(page.locator('#estimated-cost')).toHaveText('€10.13');
  const date = page.locator('[data-preference-input="rateDate"]');
  await date.fill('2026-10-07');
  await date.blur();
  await expect(page.locator('#pricing-note')).toContainText('2026-10-07');
  const zone = page.locator('[data-preference-input="timezone"]');
  await zone.fill('UTC');
  await zone.blur();
  await expect.poll(() => queries.at(-1).get('timezone')).toBe('UTC');
  await zone.fill('Invalid/Zone');
  await zone.blur();
  await expect.poll(() => page.evaluate(() => CodexPreferences.timezone())).toBe('UTC');
  await page.getByRole('link', { name: 'Live limits' }).click();
  await page.locator('.advanced-preferences summary').click();
  await expect(page.locator('[data-preference-input="timezone"]')).toHaveValue('UTC');
  await expect(page.locator('[data-preference-input="usdToEurRate"]')).toHaveValue('0.9');
  await expect(page.locator('[data-preference-input="rateDate"]')).toHaveValue('2026-10-07');
});

test('opens accessible data tables when Chart construction fails and limits diagnostics to safe fields', async ({ page }) => {
  await page.route('**/assets/chart.umd.min.js', route => route.fulfill({ contentType: 'application/javascript', body: 'window.Chart = function() { throw new Error("broken chart"); };' }));
  await page.route('**/api/analytics?*', route => route.fulfill({ json: analyticsPayload }));
  await page.route('**/api/diagnostics', route => route.fulfill({ json: {
    schema_version: 1,
    monitor: { status: 'healthy', consecutive_failures: 0, raw_error: '/secret/path token=SECRET' },
    archive: { status: 'ok', snapshots: 42, token_events: 7 },
    anomalies: [{ window: 'weekly', type: 'quota_increase', detected_at: '2026-10-07T00:00:00Z', before_pct: 10, after_pct: 20, path: 'SECRET' }],
    raw: 'SECRET',
  } }));
  await page.goto('/analytics.html');
  await expect(page.locator('#limits-chart-wrap')).toBeHidden();
  await expect(page.locator('#limits-data-body tr')).toHaveCount(2);
  await expect(page.locator('#tokens-chart-card')).toBeVisible();
  await expect(page.locator('#tokens-data-body tr')).toHaveCount(1);
  await expect(page.locator('#limits-chart-summary')).toContainText('data table is open');
  await expect(page.locator('#diagnostics-body')).toContainText('42');
  await expect(page.locator('#diagnostics-body')).not.toContainText('SECRET');
  await expect(page.locator('#diagnostics-body')).not.toContainText('/secret/path');
});

test('loads components and exports custom dates ending today without a future anchor', async ({ page }) => {
  const queries = [];
  const today = new Date().toISOString().slice(0, 10);
  const tomorrowMidnight = new Date(`${today}T00:00:00Z`);
  tomorrowMidnight.setUTCDate(tomorrowMidnight.getUTCDate() + 1);
  const period = { ...analyticsPayload.period, range: 'custom', from: `${today}T00:00:00Z`, to: tomorrowMidnight.toISOString() };
  const base = { ...analyticsPayload, period, revision: 'custom-today', pending_sections: ['weekly', 'resets'] };
  delete base.weekly_limit_value;
  await page.route('**/api/analytics?*', route => {
    const query = new URL(route.request().url()).searchParams;
    queries.push(query);
    if (query.has('at') && Number(query.get('at')) > Date.now() / 1000) return route.fulfill({ status: 400, json: { error: 'future anchors are invalid' } });
    if (query.get('sections') === 'weekly') return route.fulfill({ json: { period, revision: base.revision, weekly_limit_value: analyticsPayload.weekly_limit_value } });
    if (query.get('sections') === 'resets') return route.fulfill({ json: { period, revision: base.revision, resets: analyticsPayload.resets } });
    return route.fulfill({ json: base });
  });
  await page.goto(`/analytics.html?range=custom&from_date=${today}&to_date=${today}`);
  await expect(page.locator('#total-tokens')).toHaveText('1.73M');
  await expect(page.locator('#resets-body tr')).toHaveCount(1);
  await expect(page.locator('#weekly-section-status')).toBeHidden();
  await expect.poll(() => queries.map(query => query.get('sections')).sort()).toEqual(['base', 'resets', 'weekly']);
  for (const query of queries) {
    expect(query.has('at')).toBe(false);
    expect(query.get('from_date')).toBe(today);
    expect(query.get('to_date')).toBe(today);
  }
  const csv = new URL(await page.locator('#csv-download').getAttribute('href'), 'http://localhost');
  expect(csv.searchParams.has('at')).toBe(false);
  expect(csv.searchParams.get('from_date')).toBe(today);
  expect(csv.searchParams.get('to_date')).toBe(today);
  await expect(page.locator('#analytics-error')).toBeHidden();
});

test('localizes retained weekly and reset data while replacement components are pending', async ({ page }) => {
  let pending = false;
  let release;
  const ready = new Promise(resolve => { release = resolve; });
  await page.route('**/api/analytics?*', async route => {
    const section = new URL(route.request().url()).searchParams.get('sections');
    if (!pending) return route.fulfill({ json: analyticsPayload });
    if (section === 'base') {
      const base = { ...analyticsPayload, pending_sections: ['weekly', 'resets'] };
      delete base.weekly_limit_value;
      return route.fulfill({ json: base });
    }
    await ready;
    return route.fulfill({ json: section === 'weekly' ? { period: analyticsPayload.period, weekly_limit_value: analyticsPayload.weekly_limit_value } : { period: analyticsPayload.period, resets: analyticsPayload.resets } });
  });
  await page.goto('/analytics.html');
  await expect(page.locator('#resets-body')).toContainText('Random');
  const aggregate = page.locator('#weekly-limit-value-models button[data-weekly-model="aggregate"]');
  await aggregate.click();
  await page.locator('#weekly-limit-value-card details summary').click();
  await expect(page.locator('#weekly-limit-value-data-body tr')).toHaveCount(1);
  pending = true;
  await page.evaluate(() => { refresh(); });
  await expect(page.locator('#weekly-section-status')).toContainText('Loading');
  await expect(page.locator('#resets-section-status')).toContainText('Loading');
  await page.locator('#language-toggle').click();
  await expect(aggregate).toContainText('Tous les modèles');
  await expect(page.locator('#weekly-limit-value-data-body')).toContainText('Tous les modèles');
  await expect(page.locator('#resets-body')).toContainText('Aléatoire');
  release();
  await expect(page.locator('#weekly-section-status')).toBeHidden();
  await expect(page.locator('#resets-section-status')).toBeHidden();
});

test('localizes safe diagnostic fields statuses errors and warnings when preferences change', async ({ page }) => {
  await page.route('**/api/analytics?*', route => route.fulfill({ json: analyticsPayload }));
  await page.route('**/api/diagnostics', route => route.fulfill({ json: {
    schema_version: 1,
    monitor: { status: 'degraded', last_success_at: '2026-10-07T00:00:00Z', consecutive_failures: 3, error_code: 'collection_failed', error_message: 'Collection or alert delivery failed.', raw_error: '/private/path token=SECRET' },
    archive: { status: 'healthy', snapshots: 42 },
    anomalies: [{ window: 'weekly', type: 'quota_increase', detected_at: '2026-10-07T00:00:00Z', before_pct: 10, after_pct: 20 }],
    warnings: ['Monitor health is stale.', 'Archive could not be read safely.'],
  } }));
  await page.goto('/analytics.html');
  await expect(page.locator('#diagnostics-body')).toContainText('Last success');
  await page.locator('#language-toggle').click();
  const panel = page.locator('#diagnostics-body');
  await expect(panel).toContainText('Moniteur · État: dégradé');
  await expect(panel).toContainText('Dernière réussite');
  await expect(panel).toContainText('Échecs consécutifs: 3');
  await expect(panel).toContainText('La collecte ou l’envoi des alertes a échoué.');
  await expect(panel).toContainText('L’état du moniteur est périmé.');
  await expect(panel).toContainText('L’archive n’a pas pu être lue en toute sécurité.');
  await expect(panel).toContainText('Hebdomadaire · Quota en hausse');
  await expect(panel).not.toContainText('Last success');
  await expect(panel).not.toContainText('Monitor health is stale.');
  await expect(panel).not.toContainText('SECRET');
  await expect(panel).not.toContainText('/private/path');
});

for (const action of ['reset filter', 'breakdown pagination']) {
  test(`keeps the latest ${action} when an older base response arrives late`, async ({ page }) => {
    let baseCount = 0;
    let releaseOldBase;
    const heldBase = new Promise(resolve => { releaseOldBase = resolve; });
    const queries = [];
    const resetsFor = filter => ({ ...analyticsPayload.resets, total: 1, offset: 0, items: [{
      window: filter === '5h' ? '5h' : 'weekly', category: 'scheduled',
      reset_at: analyticsPayload.period.from, observed_at: analyticsPayload.period.from,
      before_pct: 0, after_pct: 100,
    }] });
    const tokensFor = offset => ({ ...analyticsPayload.tokens,
      breakdown: [{ ...analyticsPayload.tokens.breakdown[0], model: `page-${offset}` }],
      breakdown_pagination: { total: 100, limit: 50, offset },
    });
    await page.route('**/api/analytics?*', async route => {
      const query = new URL(route.request().url()).searchParams;
      queries.push(query);
      const section = query.get('sections');
      const resets = resetsFor(query.get('reset_type'));
      const tokens = tokensFor(Number(query.get('breakdown_offset') || 0));
      if (section === 'base') {
        baseCount += 1;
        if (baseCount === 2) await heldBase;
        const base = { ...analyticsPayload, revision: 'stable', tokens, resets, pending_sections: ['weekly', 'resets'] };
        delete base.weekly_limit_value;
        return route.fulfill({ json: base });
      }
      return route.fulfill({ json: { period: analyticsPayload.period, revision: 'stable',
        ...(section === 'resets' ? { resets } : section === 'breakdown' ? { tokens } : { weekly_limit_value: analyticsPayload.weekly_limit_value }),
      } });
    });
    await page.goto('/analytics.html');
    await expect(page.locator('#resets-body tr')).toHaveCount(1);
    await expect(page.locator('#breakdown-body')).toContainText('page-0');
    await page.evaluate(() => { window.heldRefresh = refresh(); });
    await expect.poll(() => baseCount).toBe(2);
    if (action === 'reset filter') {
      await page.selectOption('#reset-filter', '5h');
      await expect.poll(() => page.evaluate(() => displayedResetData?.items[0]?.window)).toBe('5h');
    } else {
      await page.locator('#breakdown-next').click();
      await expect(page.locator('#breakdown-body')).toContainText('page-50');
    }
    releaseOldBase();
    await page.evaluate(() => window.heldRefresh);
    expect(baseCount).toBe(3);
    if (action === 'reset filter') {
      await expect(page.locator('#reset-filter')).toHaveValue('5h');
      expect(await page.evaluate(() => displayedResetData.items[0].window)).toBe('5h');
    } else {
      await expect(page.locator('#breakdown-body')).toContainText('page-50');
      expect(await page.evaluate(() => state.breakdownOffset)).toBe(50);
    }
    expect(queries.filter(query => query.get('sections') === 'base').at(-1).get(action === 'reset filter' ? 'reset_type' : 'breakdown_offset')).toBe(action === 'reset filter' ? '5h' : '50');
  });
}

test('normalizes browser timezone aliases before Analytics and CSV requests', async ({ page }) => {
  const queries = [];
  await page.route('**/api/analytics?*', route => {
    const query = new URL(route.request().url()).searchParams;
    queries.push(query);
    if (query.get('timezone') === 'PST') return route.fulfill({ status: 400, json: { error: 'invalid IANA zone' } });
    return route.fulfill({ json: analyticsPayload });
  });
  await page.goto('/analytics.html');
  await expect(page.locator('#total-tokens')).toHaveText('1.73M');
  await page.locator('.advanced-preferences summary').click();
  const timezoneInput = page.locator('[data-preference-input="timezone"]');
  await timezoneInput.fill('PST');
  await timezoneInput.blur();
  await expect(timezoneInput).toHaveValue('America/Los_Angeles');
  await expect.poll(() => queries.at(-1).get('timezone')).toBe('America/Los_Angeles');
  await expect(page.locator('#analytics-error')).toBeHidden();
  const csv = new URL(await page.locator('#csv-download').getAttribute('href'), 'http://localhost');
  expect(csv.searchParams.get('timezone')).toBe('America/Los_Angeles');
  await page.reload();
  await expect.poll(() => queries.at(-1).get('timezone')).toBe('America/Los_Angeles');
  await expect(page.locator('#total-tokens')).toHaveText('1.73M');
});

for (const storageMode of ['URL', 'local storage']) {
  test(`rejects restored ${storageMode} model filters above the API limit`, async ({ page }) => {
    const models = Array.from({ length: 51 }, (_, index) => `model-${index}`);
    const queries = [];
    if (storageMode === 'local storage') await page.addInitScript(models => {
      localStorage.setItem('codex-usage-monitor.analytics-filters', JSON.stringify({ models }));
    }, models);
    await page.route('**/api/analytics?*', route => {
      const query = new URL(route.request().url()).searchParams;
      queries.push(query);
      if ((query.get('models') || '').split(',').length > 50) return route.fulfill({ status: 400, json: { error: 'model filter is invalid' } });
      return route.fulfill({ json: analyticsPayload });
    });
    await page.goto(`/analytics.html${storageMode === 'URL' ? `?models=${models.join(',')}` : ''}`);
    await expect(page.locator('#total-tokens')).toHaveText('1.73M');
    expect(queries[0].get('models').split(',').length).toBeLessThanOrEqual(50);
    await expect(page.locator('#analytics-error')).toBeHidden();
    await expect(page.locator('#analytics-warnings')).toContainText('exceeds 50 models');
  });
}
