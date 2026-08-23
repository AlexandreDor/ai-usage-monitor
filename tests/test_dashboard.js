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
      innerHTML: '',
      title: '',
      value: 0,
      attributes: new Map(),
      setAttribute: function setAttribute(name, value) { this.attributes.set(name, String(value)); },
      getAttribute: function getAttribute(name) { return this.attributes.get(name) ?? null; },
      removeAttribute: function removeAttribute(name) { this.attributes.delete(name); },
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
  body: { dataset: {} },
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
  if (evaluate('dashboardSource') !== 'local') fail('local data failure did not preserve the source mode');
  if (!element('mode-badge').hidden || element('mode-badge').textContent !== '') fail('local source badge was displayed');
  if (documentObject.body.dataset.freshness !== 'unavailable') fail('missing initial data did not remain unavailable');
  if (!element('error-banner').textContent.includes('no valid data is available')) fail('initial failure did not explain that no valid data exists');
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

  evaluate(`renderSource('local'); scheduleRefresh({scraped_at: new Date().toISOString(), sample_interval_seconds: 900})`);
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

  if (evaluate('normalizedSampleIntervalSeconds(undefined)') !== 900) fail('missing sample interval did not use the fallback');
  if (evaluate('normalizedSampleIntervalSeconds(30)') !== 60) fail('short sample interval did not use the Analytics minimum');
  if (evaluate('normalizedSampleIntervalSeconds(86401)') !== 900) fail('oversized sample interval did not use the fallback');
  const thresholdAt = Date.parse('2026-08-03T12:00:00Z');
  context.thresholdAt = thresholdAt;
  let freshness = evaluate(`classifySnapshotFreshness(
    {scraped_at:'2026-08-03T12:00:00Z', sample_interval_seconds:60},
    thresholdAt + 120000
  )`);
  if (freshness.status !== 'fresh' || freshness.ageSeconds !== 120) fail('exact freshness threshold was not fresh');
  freshness = evaluate(`classifySnapshotFreshness(
    {scraped_at:'2026-08-03T12:00:00Z', sample_interval_seconds:60},
    thresholdAt + 121000
  )`);
  if (freshness.status !== 'stale' || freshness.lateBySeconds !== 1) fail('stale threshold or overdue age is incorrect');
  freshness = evaluate(`classifySnapshotFreshness(
    {scraped_at:'2026-08-03T12:00:00Z', sample_interval_seconds:60},
    thresholdAt - 60000
  )`);
  if (freshness.status !== 'fresh' || freshness.ageSeconds !== 0) fail('future timestamp did not clamp its age to zero');
  if (evaluate(`formatElapsedDuration(59)`) !== 'less than a minute') fail('sub-minute duration is incorrect');
  if (evaluate(`formatElapsedDuration(60)`) !== '1 min') fail('minute duration is incorrect');
  if (evaluate(`formatElapsedDuration(3660)`) !== '1 h 1 min') fail('hour duration is incorrect');
  if (evaluate(`formatElapsedDuration(90000)`) !== '1 d 1 h') fail('day duration is incorrect');
  let rejectedInvalidTimestamp = false;
  try {
    evaluate(`classifySnapshotFreshness({scraped_at:'invalid'})`);
  } catch (_error) {
    rejectedInvalidTimestamp = true;
  }
  if (!rejectedInvalidTimestamp) fail('invalid collection timestamp was accepted');

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
  if (element('five-h-bar').getAttribute('aria-label') !== '5-hour remaining quota') fail('5-hour gauge label is incomplete');
  if (element('five-h-bar').getAttribute('aria-valuetext') !== '80% remaining') fail('5-hour gauge value text is incorrect');
  if (element('weekly-bar').getAttribute('aria-label') !== 'Weekly remaining quota') fail('weekly gauge label is incomplete');
  if (element('weekly-bar').getAttribute('aria-valuetext') !== '70% remaining') fail('weekly gauge value text is incorrect');

  evaluate(`renderData({
    five_h_pct: 80,
    weekly_pct: 70,
    scraped_at: '2026-08-03T17:30:01Z',
    weekly_reset_at: 1786147200,
  }, { schedule: false })`);
  if (!element('weekly-pace-actual').textContent.includes('Actual remaining: 70%')) fail('actual weekly pace is not visible');
  if (!element('weekly-pace-ideal').textContent.includes('Ideal remaining:')) fail('ideal weekly pace is not visible');
  if (!element('weekly-pace-delta').textContent.includes('above')) fail('weekly pace direction is not visible');

  evaluate(`renderHistory([
    {scraped_at:'2026-08-02T00:00:00Z', five_h_pct:70, weekly_pct:60, weekly_reset_at:1786147200},
    {scraped_at:'2026-08-01T00:00:00Z', five_h_pct:80, weekly_pct:90, weekly_reset_at:1786147200},
    {scraped_at:'2026-08-01T00:00:00Z', five_h_pct:81, weekly_pct:91, weekly_reset_at:1786147200},
  ])`);
  if (!element('history-summary').textContent.includes('2 samples')) fail('history summary does not use normalized samples');
  if ((element('history-table-body').innerHTML.match(/<tr>/g) || []).length !== 2) fail('history table did not deduplicate rows');
  if (!element('history-table-body').innerHTML.includes('81%')) fail('history table is missing the latest deduplicated value');

  evaluate(`renderData({
    five_h_pct: null,
    weekly_pct: null,
    scraped_at: '2026-08-03T17:30:01Z',
  }, { schedule: false })`);
  if (element('five-h-bar').getAttribute('aria-valuetext') !== 'Remaining quota unavailable') fail('unavailable 5-hour gauge was not announced');
  if (element('weekly-bar').getAttribute('aria-valuetext') !== 'Remaining quota unavailable') fail('unavailable weekly gauge was not announced');
  if (element('weekly-pace-delta').textContent !== 'Weekly pace unavailable') fail('unavailable pace was not announced');

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
  if (!element('history-summary').textContent.includes('History unavailable')) fail('empty history summary is not explicit');
  if (element('history-table-body').innerHTML !== '') fail('empty history left stale table rows');
  if (evaluate('document.body.dataset.historyState') !== 'unavailable') fail('empty history state is not distinct');

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
  if (!element('history-summary').textContent.includes('1 sample')) fail('chart failure discarded the valid history summary');
  if ((element('history-table-body').innerHTML.match(/<tr>/g) || []).length !== 1) fail('chart failure discarded the valid history table');
  if (evaluate('document.body.dataset.historyState') !== 'chart-unavailable') fail('chart failure state is not distinct');

  evaluate(`CodexPreferences.set({ language: 'fr' })`);
  if (!element('history-summary').textContent.includes('échantillon')) fail('history summary was not translated without refetch');
  if (element('five-h-bar').getAttribute('aria-label') !== 'Quota restant sur 5 heures') fail('gauge label was not translated without refetch');
  if (!element('weekly-pace-actual').textContent.includes('Restant réel')) fail('pace detail was not translated without refetch');

  console.log('PASS: dashboard JavaScript tests');
})().catch(error => {
  console.error(`FAIL: ${error.message}`);
  process.exitCode = 1;
});
