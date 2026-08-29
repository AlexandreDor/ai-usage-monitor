'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

function fail(message) { throw new Error(message); }

class FakeElement {
  constructor(id = '') {
    this.id = id;
    this.hidden = false;
    this.textContent = '';
    this.title = '';
    this.children = [];
    this.attributes = {};
    this.dataset = {};
    this.className = '';
    this.classList = { add: () => {}, remove: () => {}, toggle: () => {} };
  }
  appendChild(child) { this.children.push(child); return child; }
  removeChild(child) { this.children = this.children.filter(item => item !== child); }
  get firstChild() { return this.children[0] || null; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name] || null; }
  addEventListener() {}
  querySelectorAll() { return []; }
  closest() { return null; }
  insertBefore(child) { this.appendChild(child); }
  getContext() { return {}; }
}

const elements = new Map();
function element(id) {
  if (!elements.has(id)) elements.set(id, new FakeElement(id));
  return elements.get(id);
}
const documentObject = {
  documentElement: { lang: 'en' },
  querySelectorAll: () => [],
  getElementById: element,
  createElement: tag => new FakeElement(tag),
  addEventListener: () => {},
};
function FakeChart(_context, config) {
  this.data = config.data;
  this.options = config.options;
  this.update = () => {};
  this.destroy = () => {};
}
FakeChart.Interaction = { modes: {} };
FakeChart.register = () => {};

const context = vm.createContext({
  console, Date, Error, Intl, Map, Number, Object, Array, Set,
  Chart: FakeChart,
  document: documentObject,
  addEventListener: () => {},
  setTimeout: () => 1,
  clearTimeout: () => {},
  fetch: () => new Promise(() => {}),
});
context.window = context;
for (const sourceName of ['preferences.js', 'chart-interactions.js', 'analytics.js']) {
  const source = fs.readFileSync(path.join(__dirname, '..', 'local', 'assets', sourceName), 'utf8');
  vm.runInContext(source, context, { filename: sourceName });
}
function evaluate(expression) { return vm.runInContext(expression, context); }

evaluate(`renderWeeklyLimitValue({
  series: [
    { at: '2026-08-01T00:00:00Z', window_start: '2026-07-31T12:00:00Z', window_seconds: 43200, observed_cost_usd: 1.5, quota_consumed_pct_points: 2, raw_value_usd: 75, value_usd: 75, quality: 'good', reason: null },
    { at: '2026-08-01T12:00:00Z', window_start: '2026-08-01T00:00:00Z', window_seconds: 43200, observed_cost_usd: null, quota_consumed_pct_points: 0.2, raw_value_usd: null, value_usd: null, quality: 'unavailable', reason: 'insufficient_quota_delta' }
  ], window_seconds: 43200, point_interval_seconds: 21600, unavailable_reasons: { insufficient_quota_delta: 1 }
})`);
if (element('weekly-limit-value-empty').hidden !== true) fail('valid weekly value series still showed the empty state');
if (element('weekly-limit-value-data-body').children.length !== 2) fail('weekly value table did not include qualified rows');
if (!element('weekly-limit-value-summary').textContent.includes('twelve-hour estimate')) fail('weekly value summary did not use the twelve-hour window');
if (evaluate('weeklyLimitValueDatasets[0].data[0].y') !== 75) fail('weekly value chart lost the USD value');
if (evaluate('formatUsd(75)') !== '$75.00') fail('weekly value formatting did not remain USD');
if (evaluate("weeklyLimitValueDatasets[0].valueKind") !== 'usd') fail('weekly value chart did not declare USD formatting');
if (evaluate("formatChartValue(75, 'usd')") !== '$75.00') fail('weekly value chart formatter did not stay in USD');

evaluate(`renderWeeklyLimitValue({
  current_status: 'stale_data',
  series: [{ at: '2026-08-01T00:00:00Z', observed_cost_usd: 1.5, quota_consumed_pct_points: 2, raw_value_usd: 75, value_usd: 75, quality: 'good', reason: null }]
})`);
if (!element('weekly-limit-value-summary').textContent.includes('latest limit sample is stale')) fail('stale current estimate was not announced');

evaluate(`renderResets({
  items: [{ window: '5h', category: 'scheduled', reset_at: '2026-08-01T00:00:00Z', observed_at: '2026-08-01T00:01:00Z', before_pct: 1, after_pct: 100, cycle_cost_reason: 'weekly_only', estimated_cycle_cost_usd: null, extrapolated_100_value_usd: null }],
  total: 1, offset: 0, limit: 50
})`);
if (element('resets-body').children.length !== 1) fail('reset row was not rendered');
if (element('resets-body').children[0].children.length !== 8) fail('reset row did not expose both USD cycle columns');
if (!element('resets-body').children[0].children[5].textContent.includes('N/A')) fail('cycle cost N/A cause was not visible in the cell');
if (!element('resets-body').children[0].children[5].textContent.includes('Cycle value applies')) fail('cycle cost N/A cause was not localized in the cell');
if (!element('resets-body').children[0].children[5].getAttribute('aria-label').includes('N/A')) fail('cycle cost N/A aria label was lost');

evaluate(`renderLimits({
  series: [
    { at: '2026-08-01T00:00:00Z', five_h_pct: 80, weekly_pct: 70, ideal_weekly_pct: 75 },
    { at: '2026-08-02T00:00:00Z', five_h_pct: 60, weekly_pct: 65, ideal_weekly_pct: 70 }
  ],
  reset_markers: [
    { window: '5h', at: '2026-08-01T05:00:00Z' },
    { window: 'weekly', at: '2026-08-02T00:00:00Z' }
  ]
})`);
if (evaluate('limitDatasets.find(dataset => dataset.datasetKey === "five-hour").hidden') !== true) fail('analytics 5-hour series was visible by default');
if (evaluate('limitDatasets.find(dataset => dataset.datasetKey === "reset-5h").hidden') !== true) fail('analytics 5-hour marker was visible by default');
if (evaluate('state.resetType') !== 'weekly') fail('analytics reset filter did not default to weekly');
evaluate('limitsChart.data.datasets.find(dataset => dataset.datasetKey === "five-hour").hidden = false');
evaluate(`renderLimits({
  series: [{ at: '2026-08-03T00:00:00Z', five_h_pct: 55, weekly_pct: 60, ideal_weekly_pct: 65 }],
  reset_markers: [{ window: '5h', at: '2026-08-03T05:00:00Z' }]
})`);
if (evaluate('limitDatasets.find(dataset => dataset.datasetKey === "five-hour").hidden') !== false) fail('analytics 5-hour selection was lost on refresh');

console.log('PASS: analytics JavaScript tests');
