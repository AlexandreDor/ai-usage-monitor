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
    summary: { input_tokens: 1000000, cache_read_tokens: 500000, cache_write_tokens: 25000, output_tokens: 200000, reasoning_tokens: 50000, events: 2, estimated_cost_usd: 11.25, assumed_zero_tokens: 100 },
    series: [{ at: '2026-08-04T00:00:00Z', input_tokens: 1000000, cache_read_tokens: 500000, cache_write_tokens: 25000, output_tokens: 200000, reasoning_tokens: 50000, estimated_cost_usd: 11.25 }],
    breakdown: [{ source: 'codex', provider: 'openai', model: 'gpt-5.6-sol', input_tokens: 1000000, cache_read_tokens: 500000, cache_write_tokens: 25000, output_tokens: 200000, estimated_cost_usd: 11.25, pricing_status: 'priced' }],
  },
  resets: { total: 2, weekly_total: 2, weekly_summary: { random: { count: 1, gained_vs_ideal_pct_points: 30.004, lost_vs_ideal_pct_points: 0 }, end_of_week: { count: 1, unused_pct_points: 5 } }, offset: 0, limit: 10, items: [{ window: 'weekly', category: 'random', reset_at: '2026-08-04T08:00:00Z', observed_at: '2026-08-04T08:15:00Z', observation_delay_seconds: 900, before_pct: 28, after_pct: 100, ideal_weekly_pace_pct: 58.004, pace_delta_pct_points: 30.004, unused_pct_points: 0 }] },
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
  await expect(page.locator('#estimated-cost')).toHaveText('€9.68');
  await expect(page.locator('#allocation-total-cost')).toHaveText('€9.68');
  await expect(page.locator('#estimated-cost')).toHaveAttribute('title', 'Converted from USD using fixed rate: 1 USD = €0.86');
  await expect(page.locator('#random-reset-count')).toHaveText('2');
  await expect(page.locator('#random-reset-impact')).toHaveText('1 random · 1 end of week');
  await expect(page.locator('#end-week-reset-count')).toHaveText('1');
  await expect(page.locator('#toggle-token-overlay')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('#tokens-chart-card')).toBeHidden();
  await expect.poll(() => page.evaluate(() => limitsChart.data.datasets.length)).toBe(5);
  await page.locator('#toggle-token-overlay').click();
  await expect(page.locator('#toggle-token-overlay')).toHaveAttribute('aria-pressed', 'false');
  await expect(page.locator('#tokens-chart-card')).toBeVisible();
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
  await expect(page.locator('.back-link')).toHaveCount(1);
  await expect(page.locator('#assumed-zero-tokens, #period-label, #granularity-label')).toHaveCount(0);
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

test('renders detailed analytics, reset markers, application series and cost mode', async ({ page }) => {
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
  await expect(page.locator('#breakdown-body tr td')).toHaveCount(11);
  await expect(page.locator('#reset-pagination')).toBeVisible();
  await expect(page.locator('#reset-page-label')).toHaveText('1–50 of 55');
  await expect(page.locator('#collector-grid')).toContainText('database unavailable');
  await expect(page.locator('#token-metric-toggle')).toHaveAttribute('aria-pressed', 'false');
  await expect(page.locator('#tokens-chart-card')).toBeHidden();
  await expect(page.locator('#resets-body tr').first().locator('td')).toHaveCount(5);

  await expect.poll(() => page.evaluate(() => limitsChart.data.datasets.filter(dataset => dataset.resetMarker).length)).toBe(2);
  await expect.poll(() => page.evaluate(() => tokensChart.data.datasets.length)).toBe(2);
  await page.locator('#token-metric-toggle').click();
  await expect(page.locator('#token-metric-toggle')).toHaveAttribute('aria-pressed', 'true');
  await expect.poll(() => page.evaluate(() => limitsChart.data.datasets.find(dataset => dataset.label === 'codex')?.data[0]?.y)).toBe(11.25);
  await page.locator('#toggle-token-overlay').click();
  await expect(page.locator('#tokens-chart-card')).toBeVisible();
  await expect.poll(() => page.evaluate(() => tokensChart.data.datasets[0].data[0].y)).toBe(11.25);

  await page.locator('#resets-next').click();
  await expect(page.locator('#reset-page-label')).toContainText('51–55');
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

  await expect.poll(() => page.evaluate(() => limitsChart.data.datasets.some(dataset => dataset.label === '5-hour remaining'))).toBe(false);
  await expect(page.locator('#limits-data-body tr').first()).toContainText('—');
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
  await expect(page.locator('.nav-link')).toContainText('Analytics avancées');
  await expect(page.locator('.page-nav')).toHaveCount(0);
});
