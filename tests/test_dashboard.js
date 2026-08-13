'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

function fail(message) {
  throw new Error(message);
}

const elements = new Map();
function element(id) {
  if (!elements.has(id)) {
    const classes = new Set();
    elements.set(id, {
      id,
      hidden: false,
      textContent: '',
      title: '',
      value: 0,
      classList: {
        add: (...names) => names.forEach(name => classes.add(name)),
        remove: (...names) => names.forEach(name => classes.delete(name)),
        toggle: (name, force) => force ? classes.add(name) : classes.delete(name),
        contains: name => classes.has(name),
      },
      getContext: () => ({}),
    });
  }
  return elements.get(id);
}

let fetchQueue = [];
const fetchCalls = [];
let heartbeatFailure = false;
let heartbeatIntervalSeconds = '120';
let destroyed = 0;
function FakeChart(_context, config) {
  this.config = config;
  this.data = config.data;
  this.options = config.options;
  this.update = () => {};
  this.destroy = () => { destroyed += 1; };
}
FakeChart.Interaction = { modes: {} };
FakeChart.register = () => {};

const documentListeners = new Map();
const windowListeners = new Map();
let intervalStarts = 0;
let intervalStops = 0;
const timeoutDelays = [];
const timeoutCallbacks = [];
const documentObject = {
  visibilityState: 'visible',
  getElementById: element,
  addEventListener: (name, callback) => documentListeners.set(name, callback),
};
const context = vm.createContext({
  console,
  Date,
  Error,
  Intl,
  Map,
  Number,
  Chart: FakeChart,
  document: documentObject,
  addEventListener: (name, callback) => windowListeners.set(name, callback),
  fetch: async (url, options = {}) => {
    fetchCalls.push({ url, options });
    if (url === 'api/dashboard-heartbeat') {
      if (heartbeatFailure) throw new Error('heartbeat failed');
      return {
        ok: true,
        status: 204,
        headers: { get: name => name === 'X-Codex-Dashboard-Interval-Seconds' ? heartbeatIntervalSeconds : null },
        json: async () => ({}),
      };
    }
    if (!fetchQueue.length) return new Promise(() => {});
    const value = fetchQueue.shift();
    if (value instanceof Error) throw value;
    return { ok: true, status: 200, json: async () => value };
  },
  setTimeout: (callback, delay) => {
    timeoutCallbacks.push(callback);
    timeoutDelays.push(delay);
    return timeoutDelays.length;
  },
  clearTimeout: () => {},
  setInterval: () => { intervalStarts += 1; return intervalStarts; },
  clearInterval: timer => { if (timer !== null) intervalStops += 1; },
});
context.window = context;

const preferencesSource = fs.readFileSync(path.join(__dirname, '..', 'local', 'assets', 'preferences.js'), 'utf8');
vm.runInContext(preferencesSource, context, { filename: 'preferences.js' });
const interactionsSource = fs.readFileSync(path.join(__dirname, '..', 'local', 'assets', 'chart-interactions.js'), 'utf8');
vm.runInContext(interactionsSource, context, { filename: 'chart-interactions.js' });
const source = fs.readFileSync(path.join(__dirname, '..', 'local', 'assets', 'dashboard.js'), 'utf8');
vm.runInContext(source, context, { filename: 'dashboard.js' });

function evaluate(expression) {
  return vm.runInContext(expression, context);
}

(async () => {
  await new Promise(resolve => setImmediate(resolve));
  const firstHeartbeat = fetchCalls.find(call => call.url === 'api/dashboard-heartbeat');
  if (!firstHeartbeat) fail('visible local dashboard did not send an initial heartbeat');
  if (firstHeartbeat.options.method !== 'POST') fail('heartbeat did not use POST');
  if (firstHeartbeat.options.headers['X-Codex-Dashboard-Activity'] !== 'visible') fail('heartbeat activity header is missing');
  if (intervalStarts !== 1) fail('heartbeat interval was not started exactly once');
  if (evaluate('dashboardActiveIntervalMs') !== 120000) fail('dashboard ignored the configured active interval');

  evaluate('dashboardData = null; mainFailure = null; lastObservedScrapedAt = null; resetRefreshRetry()');
  fetchQueue = [new Error('data unavailable')];
  await evaluate('refresh()');
  if (evaluate('dashboardMode') !== 'error') fail('local data failure did not set the visual error mode');
  if (timeoutDelays[timeoutDelays.length - 1] !== 5000) fail('initial local failure did not retry after five seconds');

  evaluate('resetRefreshRetry()');
  const persistentFailureDelays = [];
  for (let attempt = 0; attempt < 7; attempt += 1) {
    fetchQueue = [new Error('still unavailable')];
    await evaluate('refresh()');
    persistentFailureDelays.push(timeoutDelays[timeoutDelays.length - 1]);
  }
  if (persistentFailureDelays.join(',') !== '5000,10000,20000,40000,80000,120000,120000') {
    fail(`persistent local failures used unexpected backoff: ${persistentFailureDelays.join(',')}`);
  }

  evaluate('dashboardActiveIntervalMs = DEFAULT_ACTIVE_REFRESH_INTERVAL_MS; refreshRetryDelayMs = 160000; mainFailure = "data unavailable"');
  heartbeatIntervalSeconds = '120';
  await evaluate('sendDashboardHeartbeat()');
  if (timeoutDelays[timeoutDelays.length - 1] !== 120000) fail('heartbeat interval change did not cap and reschedule an active retry');
  if (evaluate('refreshRetryDelayMs') !== 120000) fail('retry backoff exceeded the updated active interval');

  const oldScrapedAt = '2000-01-01T00:00:00Z';
  evaluate('lastObservedScrapedAt = null; resetRefreshRetry()');
  const unchangedSnapshotDelays = [];
  for (let attempt = 0; attempt < 7; attempt += 1) {
    evaluate(`scheduleRefresh({scraped_at: '${oldScrapedAt}', sample_interval_seconds: 900})`);
    unchangedSnapshotDelays.push(timeoutDelays[timeoutDelays.length - 1]);
  }
  if (unchangedSnapshotDelays.join(',') !== '5000,10000,20000,40000,80000,120000,120000') {
    fail(`unchanged stale snapshot used unexpected backoff: ${unchangedSnapshotDelays.join(',')}`);
  }

  evaluate(`scheduleRefresh({scraped_at: new Date().toISOString(), sample_interval_seconds: 900})`);
  const recoveredDelay = timeoutDelays[timeoutDelays.length - 1];
  if (recoveredDelay < 124000 || recoveredDelay > 126000) fail('new snapshot did not restore the active refresh deadline');
  if (evaluate('refreshRetryDelayMs') !== 5000) fail('new snapshot did not reset retry backoff');

  evaluate(`dashboardMode = 'local'; scheduleRefresh({scraped_at: new Date().toISOString(), sample_interval_seconds: 900})`);
  const configuredDelay = timeoutDelays[timeoutDelays.length - 1];
  if (configuredDelay < 124000 || configuredDelay > 126000) fail('local refresh did not use the configured active interval');
  const scheduledRefresh = timeoutCallbacks[timeoutCallbacks.length - 1];
  fetchQueue = [
    { five_h_pct: 77, weekly_pct: 66, scraped_at: '2026-08-13T14:02:00Z', sample_interval_seconds: 120 },
    [{ five_h_pct: 77, weekly_pct: 66, scraped_at: '2026-08-13T14:02:00Z' }],
  ];
  await scheduledRefresh();
  if (evaluate('dashboardData.scraped_at') !== '2026-08-13T14:02:00Z') fail('scheduled local refresh did not update the rendered snapshot');
  if (!element('last-updated').textContent.includes('13/08/2026 16:02')) fail('scheduled local refresh did not update Last scraped');
  heartbeatIntervalSeconds = 'invalid';
  await evaluate('sendDashboardHeartbeat()');
  if (evaluate('dashboardActiveIntervalMs') !== 120000) fail('dashboard accepted an invalid active interval');

  let resolveHiddenData;
  const hiddenData = new Promise(resolve => { resolveHiddenData = resolve; });
  fetchQueue = [
    hiddenData,
    [{ five_h_pct: 65, weekly_pct: 55, scraped_at: new Date().toISOString() }],
  ];
  const hiddenRefresh = evaluate('refresh()');
  documentObject.visibilityState = 'hidden';
  documentListeners.get('visibilitychange')();
  if (intervalStops !== 1) fail('hidden dashboard did not stop its heartbeat interval');
  const hiddenTimeoutCount = timeoutDelays.length;
  resolveHiddenData({ five_h_pct: 65, weekly_pct: 55, scraped_at: new Date().toISOString() });
  await hiddenRefresh;
  if (timeoutDelays.length !== hiddenTimeoutCount) fail('request completion recreated a refresh timer while the dashboard was hidden');
  const hiddenHeartbeatCount = fetchCalls.filter(call => call.url === 'api/dashboard-heartbeat').length;
  const hiddenDataFetchCount = fetchCalls.filter(call => call.url.startsWith('data.json?')).length;
  documentObject.visibilityState = 'visible';
  documentListeners.get('visibilitychange')();
  await new Promise(resolve => setImmediate(resolve));
  if (fetchCalls.filter(call => call.url === 'api/dashboard-heartbeat').length !== hiddenHeartbeatCount + 1) fail('visible dashboard did not resume heartbeat immediately');
  if (intervalStarts !== 2) fail('visible dashboard did not restart heartbeat interval');
  if (fetchCalls.filter(call => call.url.startsWith('data.json?')).length !== hiddenDataFetchCount + 1) fail('visible dashboard did not refresh data immediately');

  heartbeatFailure = true;
  await evaluate('sendDashboardHeartbeat()');
  if (evaluate('mainFailure') !== null) fail('heartbeat failure polluted the dashboard error state');
  heartbeatFailure = false;
  const heartbeatCount = fetchCalls.filter(call => call.url === 'api/dashboard-heartbeat').length;
  const retryDelayBeforeExternalFailure = evaluate('refreshRetryDelayMs');
  evaluate("GIST_ID = 'external-fixture'; stopDashboardHeartbeat(); startDashboardHeartbeat()");
  await new Promise(resolve => setImmediate(resolve));
  if (fetchCalls.filter(call => call.url === 'api/dashboard-heartbeat').length !== heartbeatCount) fail('external dashboard sent a local heartbeat');
  fetchQueue = [new Error('gist unavailable')];
  await evaluate('refresh()');
  const externalRetryDelay = timeoutDelays[timeoutDelays.length - 1];
  if (externalRetryDelay < 5000 || externalRetryDelay > 900000) fail('external failure did not retain regular scheduling');
  if (evaluate('refreshRetryDelayMs') !== retryDelayBeforeExternalFailure) fail('external failure consumed local retry backoff');
  evaluate("GIST_ID = ''");

  if (evaluate(`formatParisDateTime('2026-01-03T12:34:00Z')`) !== '03/01/2026 13:34') {
    fail('winter timestamp is not formatted in Paris time');
  }
  if (evaluate(`formatParisDateTime('2026-08-03T17:30:00Z')`) !== '03/08/2026 19:30') {
    fail('summer timestamp is not formatted in Paris time');
  }
  if (evaluate(`formatParisDateTime('invalid')`) !== '-') fail('invalid timestamp did not use fallback');
  if (evaluate('formatParisUnixTimestamp(0)') !== '-') fail('invalid reset timestamp did not use fallback');

  const points = evaluate(`normalizeHistory([
    {scraped_at:'2026-08-01T00:00:00Z', weekly_pct:90, weekly_reset_at:1786147200},
    {scraped_at:'2026-08-02T00:00:00Z', weekly_pct:70, weekly_reset_at:1786147200}
  ])`);
  context.testPoints = points;
  const ideals = evaluate('chartDatasets(testPoints)[2].data.map(point => point.y)');
  if (ideals.length !== 2 || ideals[0] === ideals[1]) fail('ideal pace is not calculated per point');

  if (evaluate('historyTitle(testPoints)') !== 'History / 01/08 02:00 - 02/08 02:00') {
    fail('history title is not formatted in Paris time');
  }

  evaluate(`renderHistory([
    {scraped_at:'2026-08-01T00:00:00Z', five_h_pct:80},
    {scraped_at:'2026-08-02T00:00:00Z', five_h_pct:70},
  ])`);
  if (evaluate('chart.config.options.scales.x.min') !== Date.parse('2026-08-01T00:00:00Z')) {
    fail('chart start bound does not match the first point');
  }
  if (evaluate('chart.config.options.scales.x.max') !== Date.parse('2026-08-02T00:00:00Z')) {
    fail('chart end bound does not match the last point');
  }
  if (evaluate(`chart.config.options.scales.x.ticks.callback(Date.parse('2026-08-03T17:30:00Z'))`) !== '03/08 19:30') {
    fail('chart axis is not formatted in Paris time');
  }
  if (evaluate(`chart.config.options.plugins.tooltip.callbacks.title([{parsed:{x:Date.parse('2026-08-03T17:30:00Z')}}])`) !== '03/08/2026 19:30') {
    fail('chart tooltip is not formatted in Paris time');
  }
  if (evaluate('chart.config.options.interaction.mode') !== 'timeSlice') fail('dashboard does not use the shared time-slice interaction');
  if (evaluate('chart.data.datasets.every(dataset => dataset.valueKind === "percent")') !== true) fail('dashboard datasets do not declare percent units');

  const forecastPoints = evaluate(`normalizeHistory([
    {scraped_at:'2026-08-01T00:00:00Z', five_h_pct:80, codex_forecast:{chance_24h_pct:55,chance_6h_pct:20,generated_at:'2026-08-01T00:00:00Z'}},
    {scraped_at:'2026-08-02T00:00:00Z', five_h_pct:70},
  ])`);
  context.forecastPoints = forecastPoints;
  if (evaluate('chartDatasets(forecastPoints).length') !== 5) fail('Forecast datasets are missing');
  if (evaluate('chartDatasets(forecastPoints)[3].data[1].y') !== null) fail('missing Forecast sample did not create a chart gap');

  evaluate(`renderData({
    five_h_pct: 80,
    weekly_pct: 70,
    scraped_at: '2026-08-03T17:30:01Z',
    five_h_reset_at: 1785778500,
    weekly_reset_at: 1767443640,
  })`);
  if (element('last-updated').textContent !== 'Last scraped 03/08/2026 19:30') fail('last update is not formatted in Paris time');
  if (element('five-h-reset').textContent !== '03/08/2026 19:35') fail('five-hour reset is not formatted in Paris time');
  if (element('weekly-reset').textContent !== '03/01/2026 13:34') fail('weekly reset is not formatted in Paris time');

  evaluate(`renderForecast({
    sample_interval_seconds: 900,
    codex_forecast: {
      chance_24h_pct: 76,
      chance_6h_pct: 10,
      generated_at: new Date().toISOString(),
    },
  })`);
  if (element('forecast-24h').textContent !== '76%') fail('24-hour forecast chance is not rendered');
  if (element('forecast-6h').textContent !== '10%') fail('6-hour forecast chance is not rendered');
  if (!element('forecast-status').textContent.startsWith('Forecast updated ')) fail('forecast freshness is not rendered');
  if (!element('forecast-24h').classList.contains('threshold-reached')) fail('fallback 24-hour threshold was not highlighted');
  if (element('forecast-6h').classList.contains('threshold-reached')) fail('fallback 6-hour threshold highlighted below threshold');
  if (element('forecast-24h').title !== 'Highlight threshold reached: 50%') fail('threshold highlight title is missing');

  evaluate(`renderForecast({
    sample_interval_seconds: 900,
    codex_forecast: {
      chance_24h_pct: 60,
      chance_6h_pct: 35,
      generated_at: new Date().toISOString(),
      highlight_threshold_24h_pct: 60,
      highlight_threshold_6h_pct: 35,
    },
  })`);
  if (!element('forecast-24h').classList.contains('threshold-reached')) fail('24-hour equality did not highlight');
  if (!element('forecast-6h').classList.contains('threshold-reached')) fail('6-hour equality did not highlight');

  evaluate(`renderForecast({
    sample_interval_seconds: 900,
    codex_forecast: {
      chance_24h_pct: 76,
      chance_6h_pct: 10,
      generated_at: '2000-01-01T00:00:00Z',
    },
  })`);
  if (element('forecast-24h').textContent !== '--') fail('stale forecast remained visible');
  if (element('forecast-status').textContent !== 'Forecast unavailable') fail('stale forecast was not marked unavailable');
  if (element('forecast-24h').classList.contains('threshold-reached')) fail('stale Forecast retained threshold highlight');

  evaluate(`renderForecast({
    sample_interval_seconds: 900,
    codex_forecast: {
      chance_24h_pct: 76,
      chance_6h_pct: 10,
      generated_at: '2999-01-01T00:00:00Z',
    },
  })`);
  if (element('forecast-24h').textContent !== '--') fail('future forecast remained visible');
  if (element('forecast-status').textContent !== 'Forecast unavailable') fail('future forecast was not marked unavailable');

  fetchQueue = [
    { five_h_pct: 80, weekly_pct: 70, scraped_at: '2026-08-03T00:00:00Z' },
    [],
  ];
  await evaluate('fetchLocal()');
  if (destroyed !== 1) fail('empty history did not destroy the previous chart');
  if (element('history-error').hidden) fail('empty history error is not visible');

  evaluate('chart = null');
  context.Chart = function BrokenChart() { throw new Error('graph exploded'); };
  fetchQueue = [
    { five_h_pct: 42, weekly_pct: 24, scraped_at: '2026-08-03T00:00:00Z' },
    [{ scraped_at: '2026-08-03T00:00:00Z', five_h_pct: 42 }],
  ];
  await evaluate('fetchLocal()');
  if (element('five-h-pct').textContent !== '42%') fail('chart failure prevented main data rendering');
  if (element('history-error').hidden) fail('chart failure was not isolated and reported');
  if (!element('error-banner').hidden) fail('chart failure polluted the main error state');

  console.log('PASS: dashboard JavaScript tests');
})().catch(error => {
  console.error(`FAIL: ${error.message}`);
  process.exitCode = 1;
});
