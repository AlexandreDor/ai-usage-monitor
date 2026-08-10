'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

function fail(message) {
  throw new Error(message);
}

const elements = new Map();
function domNode(tagName = 'div', id = '') {
  const attributes = new Map();
  const classes = new Set();
  return {
    id,
    tagName: tagName.toUpperCase(),
    hidden: false,
    textContent: '',
    title: '',
    value: 0,
    colSpan: 1,
    children: [],
    classList: {
      add: (...names) => names.forEach(name => classes.add(name)),
      remove: (...names) => names.forEach(name => classes.delete(name)),
      toggle: (name, force) => force ? classes.add(name) : classes.delete(name),
      contains: name => classes.has(name),
    },
    setAttribute: (name, value) => attributes.set(name, String(value)),
    getAttribute: name => attributes.get(name) ?? null,
    removeAttribute: name => attributes.delete(name),
    appendChild(child) {
      this.children.push(child);
      return child;
    },
    replaceChildren(...children) {
      this.children = children;
    },
    getContext: () => ({}),
  };
}

function element(id) {
  if (!elements.has(id)) elements.set(id, domNode('div', id));
  return elements.get(id);
}

let fetchQueue = [];
let destroyed = 0;
const timerDelays = [];
function FakeChart(_context, config) {
  this.config = config;
  this.data = config.data;
  this.options = config.options;
  this.update = () => {};
  this.destroy = () => { destroyed += 1; };
}

const context = vm.createContext({
  console,
  Date,
  Error,
  Intl,
  Map,
  Number,
  Chart: FakeChart,
  document: { getElementById: element, createElement: tagName => domNode(tagName) },
  fetch: async () => {
    if (!fetchQueue.length) return new Promise(() => {});
    const value = fetchQueue.shift();
    return { ok: true, status: 200, json: async () => value };
  },
  setTimeout: (_callback, delay) => {
    timerDelays.push(delay);
    return timerDelays.length;
  },
  clearTimeout: () => {},
  setInterval: () => 1,
});

const preferencesSource = fs.readFileSync(path.join(__dirname, '..', 'local', 'assets', 'preferences.js'), 'utf8');
vm.runInContext(preferencesSource, context, { filename: 'preferences.js' });
const source = fs.readFileSync(path.join(__dirname, '..', 'local', 'assets', 'dashboard.js'), 'utf8');
vm.runInContext(source, context, { filename: 'dashboard.js' });

function evaluate(expression) {
  return vm.runInContext(expression, context);
}

(async () => {
  if (element('freshness-badge').textContent !== '-' || element('freshness-detail').textContent !== 'Waiting for data') {
    fail('dashboard did not retain a distinct waiting state before the first response');
  }
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
  if (element('history-table-body').children.length !== 2) fail('accessible history table does not contain every sample');
  if (!element('history-summary').textContent.includes('2 samples')) fail('history summary does not expose the sample count');

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

  evaluate(`renderData({
    five_h_pct: 8,
    weekly_pct: 35,
    scraped_at: '2026-08-03T17:30:00Z',
    weekly_reset_at: ${Date.parse('2026-08-07T17:30:00Z') / 1000},
    sample_interval_seconds: 10,
  })`);
  evaluate(`updateFreshness(Date.parse('2026-08-03T17:30:19Z'))`);
  if (element('freshness-badge').textContent !== 'FRESH') fail('sample became stale before two sample intervals');
  if (element('sample-age').textContent !== 'Sample age: 19s') fail('sample age is not calculated from scraped_at');
  evaluate(`updateFreshness(Date.parse('2026-08-03T17:30:20Z'))`);
  if (element('freshness-badge').textContent !== 'STALE') fail('sample did not become stale after two sample intervals');
  if (element('five-h-criticality').textContent !== 'Quota status: critical') fail('critical quota is not described in text');
  if (element('five-h-bar').getAttribute('aria-valuetext') !== '8% - Quota status: critical') fail('progress value is not accessible');
  if (element('weekly-actual').textContent !== 'Actual: 35.0%' || element('weekly-ideal').textContent !== 'Ideal: 57.1%') {
    fail('actual and ideal weekly pace are not both visible');
  }
  if (!timerDelays.includes(10_000)) fail('refresh is not scheduled from sample_interval_seconds');

  evaluate(`renderData({ five_h_pct: 8, scraped_at: 'invalid', sample_interval_seconds: 10 })`);
  if (element('freshness-badge').textContent !== 'ERROR') fail('invalid sample timestamp remained fresh');
  evaluate(`renderData({ five_h_pct: 8, scraped_at: '2026-08-03T17:31:00Z', sample_interval_seconds: 10 }, { schedule: false });
    updateFreshness(Date.parse('2026-08-03T17:30:59Z'))`);
  if (element('freshness-badge').textContent !== 'ERROR') fail('future sample timestamp remained fresh');
  evaluate(`updateFreshness(Date.parse('2026-08-03T17:31:00Z'))`);
  if (element('freshness-badge').textContent !== 'FRESH') fail('future timestamp did not recover when time caught up');

  evaluate(`setOrigin('local'); setMainError('network unavailable'); setFreshness('error')`);
  if (element('freshness-badge').textContent !== 'ERROR') fail('refresh failure state is not visible');
  if (element('mode-badge').textContent !== 'LOCAL') fail('refresh failure replaced the persistent origin');
  if (element('five-h-pct').textContent !== '8%') fail('refresh failure discarded the last known quota');
  evaluate(`renderData({
    five_h_pct: 64,
    weekly_pct: 52,
    scraped_at: '2026-08-03T17:31:00Z',
    weekly_reset_at: ${Date.parse('2026-08-07T17:30:00Z') / 1000},
    sample_interval_seconds: 10,
  }); updateFreshness(Date.parse('2026-08-03T17:31:01Z'))`);
  if (element('freshness-badge').textContent !== 'FRESH' || element('five-h-pct').textContent !== '64%') {
    fail('dashboard did not recover from an error with fresh quotas');
  }
  if (!element('error-banner').hidden) fail('successful recovery did not clear the error');

  fetchQueue = [
    { five_h_pct: 80, weekly_pct: 70, scraped_at: '2026-08-03T00:00:00Z' },
    [],
  ];
  await evaluate('fetchLocal()');
  if (destroyed !== 1) fail('empty history did not destroy the previous chart');
  if (element('history-error').hidden) fail('empty history error is not visible');
  if (element('history-summary').textContent !== 'No history samples available.') fail('empty history has no accessible summary');

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
  if (element('history-table-body').children.length !== 1) fail('chart failure prevented the history table rendering');

  console.log('PASS: dashboard JavaScript tests');
})().catch(error => {
  console.error(`FAIL: ${error.message}`);
  process.exitCode = 1;
});
