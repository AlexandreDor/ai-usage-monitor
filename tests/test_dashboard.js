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
  this.data = config.data;
  this.update = () => {};
  this.destroy = () => { destroyed += 1; };
}

const context = vm.createContext({
  console,
  Date,
  Error,
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

const source = fs.readFileSync(path.join(__dirname, '..', 'local', 'assets', 'dashboard.js'), 'utf8');
vm.runInContext(source, context, { filename: 'dashboard.js' });

function evaluate(expression) {
  return vm.runInContext(expression, context);
}

(async () => {
  const points = evaluate(`normalizeHistory([
    {scraped_at:'2026-08-01T00:00:00Z', weekly_pct:90, weekly_reset_at:1786147200},
    {scraped_at:'2026-08-02T00:00:00Z', weekly_pct:70, weekly_reset_at:1786147200}
  ])`);
  context.testPoints = points;
  const ideals = evaluate('chartDatasets(testPoints)[2].data.map(point => point.y)');
  if (ideals.length !== 2 || ideals[0] === ideals[1]) fail('ideal pace is not calculated per point');

  evaluate(`renderHistory([{scraped_at:'2026-08-01T00:00:00Z', five_h_pct:80}])`);
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
