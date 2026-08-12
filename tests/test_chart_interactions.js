'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

function fail(message) { throw new Error(message); }
function assert(condition, message) { if (!condition) fail(message); }

let registeredPlugin = null;
function FakeChart() {}
FakeChart.Interaction = { modes: {} };
FakeChart.register = plugin => { registeredPlugin = plugin; };

const context = vm.createContext({
  Chart: FakeChart,
  WeakMap,
  Number,
  Object,
  globalThis: null,
});
context.globalThis = context;
context.window = context;
const source = fs.readFileSync(path.join(__dirname, '..', 'local', 'assets', 'chart-interactions.js'), 'utf8');
vm.runInContext(source, context, { filename: 'chart-interactions.js' });

function fakeChart(datasets, hidden = []) {
  const metas = datasets.map(dataset => ({ data: dataset.data.map(() => ({ skip: false })) }));
  const drawing = [];
  return {
    data: { datasets },
    scales: { x: { getValueForPixel: value => value, getPixelForValue: value => value } },
    isDatasetVisible: index => !hidden.includes(index),
    getDatasetMeta: index => metas[index],
    chartArea: { left: 0, right: 100, top: 10, bottom: 80 },
    tooltip: { getActiveElements: () => [{ datasetIndex: 0, index: 0 }], setActiveElements: () => {} },
    setActiveElements: () => {},
    ctx: {
      save: () => drawing.push('save'),
      beginPath: () => drawing.push('begin'),
      moveTo: (x, y) => drawing.push(['move', x, y]),
      lineTo: (x, y) => drawing.push(['line', x, y]),
      setLineDash: value => drawing.push(['dash', ...value]),
      stroke: () => drawing.push('stroke'),
      restore: () => drawing.push('restore'),
    },
    drawing,
  };
}

(() => {
  const api = context.CodexChartInteractions;
  assert(api && typeof api.enhanceOptions === 'function', 'public interaction API is missing');
  assert(typeof FakeChart.Interaction.modes.timeSlice === 'function', 'timeSlice mode was not registered');
  assert(registeredPlugin?.id === 'timeSliceCursor', 'cursor plugin was not registered');

  const datasets = [
    { label: 'percent', valueKind: 'percent', data: [{ x: 10, y: 80 }, { x: 30, y: 60 }] },
    { label: 'tokens', valueKind: 'tokens', data: [{ x: 5, y: 100 }, { x: 10, y: 200 }, { x: 30, y: null }] },
    { label: 'hidden', data: [{ x: 20, y: 1 }] },
    { label: 'marker', timeSliceExcluded: true, data: [{ x: 11, y: 0 }] },
  ];
  const chart = fakeChart(datasets, [2]);
  const mode = FakeChart.Interaction.modes.timeSlice;

  let active = mode(chart, { x: 12, y: -1000 });
  assert(active.length === 2, 'nearest time slice did not group series with different indices');
  assert(active.every(item => datasets[item.datasetIndex].data[item.index].x === 10), 'time slice used vertical distance or a technical point');

  active = mode(chart, { x: 20, y: 5000 });
  assert(active.length === 2 && active.every(item => datasets[item.datasetIndex].data[item.index].x === 10), 'equal-distance tie did not select the older timestamp');

  active = mode(chart, { x: 29, y: 0 });
  assert(active.length === 1 && active[0].datasetIndex === 0 && active[0].index === 1, 'null, hidden, or excluded series produced a misleading item');

  const options = api.enhanceOptions({ plugins: { tooltip: {} } }, {
    formatTitle: value => `at ${value}`,
    formatValue: (value, kind) => `${kind}=${value}`,
  });
  assert(options.interaction.mode === 'timeSlice' && options.interaction.intersect === false, 'shared interaction options are incomplete');
  assert(options.plugins.tooltip.callbacks.title([{ parsed: { x: 10 } }]) === 'at 10', 'title formatter was not used');
  const label = options.plugins.tooltip.callbacks.label({ parsed: { y: 80 }, dataset: datasets[0] });
  assert(label === 'percent: percent=80', 'unit-aware value formatter was not used');
  assert(options.plugins.tooltip.filter({ parsed: { y: null }, dataset: datasets[0] }) === false, 'null tooltip item was not filtered');
  assert(options.plugins.tooltip.filter({ parsed: { y: 0 }, dataset: datasets[3] }) === false, 'technical tooltip item was not filtered');

  mode(chart, { x: 29, y: 0 });
  registeredPlugin.afterDatasetsDraw(chart, {}, { enabled: true, color: '#fff', width: 1, dash: [2, 2] });
  assert(chart.drawing.some(call => Array.isArray(call) && call[0] === 'move' && call[1] === 30 && call[2] === 10), 'cursor did not start at the selected timestamp and chart top');
  assert(chart.drawing.some(call => Array.isArray(call) && call[0] === 'line' && call[1] === 30 && call[2] === 80), 'cursor did not end at the chart bottom');

  chart.drawing.length = 0;
  registeredPlugin.afterEvent(chart, { event: { type: 'touchend' }, changed: false });
  registeredPlugin.afterDatasetsDraw(chart, {}, { enabled: true, color: '#fff', width: 1, dash: [] });
  assert(chart.drawing.includes('stroke'), 'touch selection was not retained');

  chart.drawing.length = 0;
  const mouseout = { event: { type: 'mouseout' }, changed: false };
  registeredPlugin.afterEvent(chart, mouseout);
  registeredPlugin.afterDatasetsDraw(chart, {}, { enabled: true, color: '#fff', width: 1, dash: [] });
  assert(mouseout.changed && !chart.drawing.includes('stroke'), 'mouseout did not clear the cursor');

  mode(chart, { x: 29, y: 0 });
  chart.drawing.length = 0;
  registeredPlugin.beforeUpdate(chart);
  registeredPlugin.afterDatasetsDraw(chart, {}, { enabled: true, color: '#fff', width: 1, dash: [] });
  assert(!chart.drawing.includes('stroke'), 'chart update did not clear the cursor');

  const withoutChart = vm.createContext({ WeakMap, Number, Object, globalThis: null });
  withoutChart.globalThis = withoutChart;
  vm.runInContext(source, withoutChart, { filename: 'chart-interactions-no-chart.js' });
  const fallback = withoutChart.CodexChartInteractions.enhanceOptions({ responsive: true }, {});
  assert(fallback.responsive === true, 'Chart.js fallback changed the original options');

  console.log('PASS: chart interaction JavaScript tests');
})();
