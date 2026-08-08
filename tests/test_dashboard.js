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
let destroyed = 0;
function FakeChart(_context, config) {
  this.config = config;
  this.data = config.data;
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
  document: { getElementById: element },
  fetch: async () => {
    if (!fetchQueue.length) return new Promise(() => {});
    const value = fetchQueue.shift();
    return { ok: true, status: 200, json: async () => value };
  },
  setTimeout: () => 1,
  clearTimeout: () => {},
});

const preferencesSource = fs.readFileSync(path.join(__dirname, '..', 'local', 'assets', 'preferences.js'), 'utf8');
vm.runInContext(preferencesSource, context, { filename: 'preferences.js' });
const source = fs.readFileSync(path.join(__dirname, '..', 'local', 'assets', 'dashboard.js'), 'utf8');
vm.runInContext(source, context, { filename: 'dashboard.js' });

function evaluate(expression) {
  return vm.runInContext(expression, context);
}

(async () => {
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
