'use strict';

const { writeFile } = require('node:fs/promises');
const { test, expect } = require('@playwright/test');

const VIEWPORT = { width: 1440, height: 1000 };
const WARMUP_MS = 750;
const SAMPLE_MS = 2_000;
const SAMPLE_COUNT = 3;
const TRACE_CATEGORIES = [
  'devtools.timeline',
  'blink.animations',
  'cc',
  'gpu',
  'viz',
].join(',');
const BUDGETS = {
  infiniteAnimations: 0,
  paintEvents: 30,
  rasterTasks: 40,
  pipelineDraws: 40,
  taskDurationMs: 75,
};

const dashboardSnapshot = {
  five_h_pct: 72,
  weekly_pct: 36,
  scraped_at: new Date().toISOString(),
  five_h_reset_at: Math.floor(Date.now() / 1000) + 3_600,
  weekly_reset_at: Math.floor(Date.now() / 1000) + 86_400,
  sample_interval_seconds: 900,
  codex_forecast: {
    chance_24h_pct: 76,
    chance_6h_pct: 10,
    generated_at: new Date().toISOString(),
  },
};

const analyticsPayload = {
  schema_version: 1,
  period: {
    range: '30d',
    from: '2026-07-05T10:00:00Z',
    to: '2026-08-04T10:00:00Z',
    timezone: 'Europe/Paris',
    granularity_seconds: 86_400,
    sample_interval_seconds: 86_400,
  },
  filters: { sources: [], models: [], reset_type: 'all' },
  available: { sources: ['codex'], models: ['gpt-5.6-sol'] },
  freshness: {
    limits_last_sample_at: '2026-08-04T09:45:00Z',
    sample_interval_seconds: 86_400,
    collectors: {
      codex: { status: 'ok', last_success_at: '2026-08-04T09:45:00Z' },
    },
  },
  limits: {
    samples: 2,
    forecast_samples: 2,
    series: [
      { at: '2026-08-03T00:00:00Z', five_h_pct: 80, weekly_pct: 60, ideal_weekly_pct: 65, forecast_chance_24h_pct: 60, forecast_chance_6h_pct: 20 },
      { at: '2026-08-04T00:00:00Z', five_h_pct: 55, weekly_pct: 52, ideal_weekly_pct: 51, forecast_chance_24h_pct: 70, forecast_chance_6h_pct: 30 },
    ],
  },
  tokens: {
    summary: { input_tokens: 1_000, cache_read_tokens: 500, cache_write_tokens: 0, output_tokens: 200, reasoning_tokens: 50, events: 2, estimated_cost_usd: 0.01 },
    series: [{ at: '2026-08-04T00:00:00Z', input_tokens: 1_000, cache_read_tokens: 500, output_tokens: 200, reasoning_tokens: 50, estimated_cost_usd: 0.01 }],
    breakdown: [{ source: 'codex', provider: 'openai', model: 'gpt-5.6-sol', input_tokens: 1_000, cache_read_tokens: 500, output_tokens: 200, reasoning_tokens: 50, estimated_cost_usd: 0.01, pricing_status: 'priced' }],
    breakdown_pagination: { total: 1, offset: 0, limit: 50 },
  },
  resets: { total: 0, weekly_total: 0, weekly_summary: { random: {}, end_of_week: {} }, offset: 0, limit: 10, items: [] },
  baselines: {},
  pricing: { currency: 'USD', as_of: '2026-08-04', valuation_mode: 'current_catalog' },
  warnings: [],
};

function metricValue(metrics, name) {
  return metrics.metrics.find(metric => metric.name === name)?.value ?? 0;
}

function countTraceEvents(events, name) {
  return events.reduce((count, event) => count + Number(event.name === name), 0);
}

function median(values) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.floor(sorted.length / 2)];
}

async function runningInfiniteAnimations(page) {
  return page.evaluate(() => document.getAnimations({ subtree: true })
    .filter(animation => {
      const timing = animation.effect?.getTiming?.();
      return animation.playState === 'running' && timing?.iterations === Infinity;
    })
    .map(animation => animation.animationName || animation.id || 'anonymous'));
}

async function measureIdleRendering(page) {
  const infiniteAnimations = await runningInfiniteAnimations(page);
  const session = await page.context().newCDPSession(page);
  const traceEvents = [];
  let tracing = false;

  try {
    await session.send('Performance.enable');
    session.on('Tracing.dataCollected', ({ value }) => traceEvents.push(...value));
    const traceComplete = new Promise(resolve => session.once('Tracing.tracingComplete', resolve));
    await session.send('Tracing.start', {
      categories: TRACE_CATEGORIES,
      transferMode: 'ReportEvents',
    });
    tracing = true;
    const before = await session.send('Performance.getMetrics');
    await page.waitForTimeout(SAMPLE_MS);
    const after = await session.send('Performance.getMetrics');
    await session.send('Tracing.end');
    tracing = false;
    await traceComplete;

    return {
      infiniteAnimations,
      paintEvents: countTraceEvents(traceEvents, 'Paint'),
      rasterTasks: countTraceEvents(traceEvents, 'RasterTask'),
      pipelineDraws: countTraceEvents(traceEvents, 'Graphics.Pipeline.Draw'),
      taskDurationMs: Number(((metricValue(after, 'TaskDuration') - metricValue(before, 'TaskDuration')) * 1_000).toFixed(2)),
    };
  } finally {
    if (tracing) {
      await session.send('Tracing.end').catch(() => {});
    }
    await session.detach().catch(() => {});
  }
}

async function expectIdleRenderingWithinBudget(page, browser, testInfo, pageName) {
  await page.waitForTimeout(WARMUP_MS);
  const samples = [];
  for (let index = 0; index < SAMPLE_COUNT; index += 1) {
    samples.push(await measureIdleRendering(page));
  }
  const measurements = {
    infiniteAnimations: [...new Set(samples.flatMap(sample => sample.infiniteAnimations))],
    paintEvents: median(samples.map(sample => sample.paintEvents)),
    rasterTasks: median(samples.map(sample => sample.rasterTasks)),
    pipelineDraws: median(samples.map(sample => sample.pipelineDraws)),
    taskDurationMs: median(samples.map(sample => sample.taskDurationMs)),
  };
  const report = {
    page: pageName,
    browserVersion: browser.version(),
    viewport: page.viewportSize(),
    warmupMs: WARMUP_MS,
    sampleMs: SAMPLE_MS,
    sampleCount: SAMPLE_COUNT,
    samples,
    measurements,
    budgets: BUDGETS,
  };
  const reportBody = `${JSON.stringify(report, null, 2)}\n`;
  const reportPath = testInfo.outputPath('client-performance.json');
  await writeFile(reportPath, reportBody, 'utf8');

  await testInfo.attach(`${pageName}-client-performance.json`, {
    path: reportPath,
    contentType: 'application/json',
  });

  expect.soft(measurements.infiniteAnimations, 'running infinite animations').toHaveLength(BUDGETS.infiniteAnimations);
  expect.soft(measurements.paintEvents, 'Paint events').toBeLessThanOrEqual(BUDGETS.paintEvents);
  expect.soft(measurements.rasterTasks, 'RasterTask events').toBeLessThanOrEqual(BUDGETS.rasterTasks);
  expect.soft(measurements.pipelineDraws, 'Graphics.Pipeline.Draw events').toBeLessThanOrEqual(BUDGETS.pipelineDraws);
  expect.soft(measurements.taskDurationMs, 'renderer TaskDuration (ms)').toBeLessThanOrEqual(BUDGETS.taskDurationMs);
}

test.use({ viewport: VIEWPORT });

test('dashboard remains within the idle rendering budget', { tag: '@performance' }, async ({ page, browser }, testInfo) => {
  await page.route('**/api/dashboard-heartbeat', route => route.fulfill({ status: 204 }));
  await page.route('**/data.json?*', route => route.fulfill({ json: dashboardSnapshot }));
  await page.route('**/history.json?*', route => route.fulfill({ json: [dashboardSnapshot] }));
  await page.goto('/dashboard.html');
  await expect(page.locator('#five-h-pct')).toHaveText('72%');
  await expect.poll(() => page.evaluate(() => Boolean(chart))).toBe(true);

  await expectIdleRenderingWithinBudget(page, browser, testInfo, 'dashboard');
});

test('analytics remains within the idle rendering budget', { tag: '@performance' }, async ({ page, browser }, testInfo) => {
  await page.route('**/api/analytics?*', route => route.fulfill({ json: analyticsPayload }));
  await page.goto('/analytics.html');
  await expect(page.locator('#analytics-loading')).toBeHidden();
  await expect.poll(() => page.evaluate(() => Boolean(limitsChart))).toBe(true);

  await expectIdleRenderingWithinBudget(page, browser, testInfo, 'analytics');
});

test('analytics loads dense history within client budgets', { tag: '@performance' }, async ({ page, browser }, testInfo) => {
  const end = Date.now();
  const at = index => new Date(end - (1800 - index) * 900_000).toISOString();
  const payload = JSON.parse(JSON.stringify(analyticsPayload));
  payload.period.from = at(0);
  payload.period.to = new Date(end).toISOString();
  payload.limits.series = Array.from({ length: 1800 }, (_, index) => ({ at: at(index), five_h_pct: 100 - index % 90, weekly_pct: 100 - index % 95, ideal_weekly_pct: 100 - index % 96, forecast_chance_24h_pct: index % 100, forecast_chance_6h_pct: index % 80 }));
  payload.limits.samples = 1800;
  payload.tokens.series = Array.from({ length: 400 }, (_, index) => ({ at: at(index * 4), input_tokens: 1000, output_tokens: 200, cache_read_tokens: 500, total_tokens: 1700, estimated_cost_usd: 0.015 + index / 1000 }));
  payload.tokens.series_by_source = payload.tokens.series.map(point => ({ ...point, source: 'codex' }));
  payload.weekly_limit_value = {
    series: Array.from({ length: 75 }, (_, index) => ({ at: at(index * 24), value_usd: 150, raw_value_usd: 150, quality: 'good', observed_cost_usd: 3, quota_consumed_pct_points: 2 })),
    by_model: ['gpt-5.6-luna', 'gpt-5.6-terra', 'gpt-5.6-sol', 'gpt-6-luna', 'gpt-6-sol', 'gpt-6.1-sol', 'gpt-6-astra'].map((model, offset) => ({ model, providers: ['openai'], series: Array.from({ length: 75 }, (_, index) => ({ at: at(index * 24), value_usd: 100 + offset * 20 + index, raw_value_usd: 100 + offset * 20 + index, observed_cost_usd: 2, quota_consumed_pct_points: 2, quality: 'good' })) })),
  };
  await page.addInitScript(() => {
    window.performanceFormatterCounts = {};
    for (const name of ['DateTimeFormat', 'NumberFormat']) {
      const Original = Intl[name];
      Intl[name] = new Proxy(Original, { construct(target, args) {
        window.performanceFormatterCounts[name] = (window.performanceFormatterCounts[name] || 0) + 1;
        return Reflect.construct(target, args);
      } });
    }
  });
  await page.route('**/api/analytics?*', route => route.fulfill({ json: payload }));
  const samples = [];
  for (let index = 0; index < 3; index += 1) {
    const session = await page.context().newCDPSession(page);
    await session.send('Performance.enable');
    const before = await session.send('Performance.getMetrics');
    await page.goto('/analytics.html');
    await page.waitForFunction(() => typeof limitsChart !== 'undefined' && limitsChart && weeklyLimitValueChart && document.getElementById('analytics-loading').hidden);
    const after = await session.send('Performance.getMetrics');
    const state = await page.evaluate(() => ({
      readyMs: performance.now(),
      domNodes: document.querySelectorAll('*').length,
      closedTableRows: [...document.querySelectorAll('details.chart-data-details:not([open]) tbody')].reduce((sum, body) => sum + body.rows.length, 0),
      formatterCounts: window.performanceFormatterCounts,
      points: limitsChart.data.datasets.find(dataset => dataset.datasetKey === 'weekly')?.data.length ?? limitPoints.length,
    }));
    samples.push({ ...state, taskDurationMs: (metricValue(after, 'TaskDuration') - metricValue(before, 'TaskDuration')) * 1000 });
    await session.detach();
  }
  const report = { browserVersion: browser.version(), fixture: { limits: 1800, tokenBuckets: 400, weeklyModelPoints: 525 }, samples };
  const path = testInfo.outputPath('analytics-loading-performance.json');
  await writeFile(path, `${JSON.stringify(report, null, 2)}\n`);
  await testInfo.attach('analytics-loading-performance', { path, contentType: 'application/json' });
  expect(median(samples.map(sample => sample.readyMs))).toBeLessThan(5000);
  expect(median(samples.map(sample => sample.taskDurationMs))).toBeLessThan(2000);
  for (const sample of samples) {
    expect(sample.closedTableRows).toBe(0);
    expect(sample.domNodes).toBeLessThan(3000);
    expect(sample.formatterCounts.DateTimeFormat).toBeLessThan(40);
    expect(sample.formatterCounts.NumberFormat).toBeLessThan(40);
    expect(sample.points).toBe(1800);
  }
});
