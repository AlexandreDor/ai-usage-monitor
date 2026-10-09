'use strict';

const ANALYTICS_REFRESH_MS = 900_000;
const RESET_PAGE_SIZE = 50;
const BREAKDOWN_PAGE_SIZE = 50;
const PARIS_ZONE = 'Europe/Paris';
const EMPTY_VALUE = '-';
const PRICE_WARNING_PATTERN = /^No catalog price; assumed zero: (.+)$/u;
const GPT_MODELS = Object.freeze(['gpt-5.6-luna', 'gpt-5.6-terra', 'gpt-5.6-sol', 'gpt-6-luna', 'gpt-6-sol', 'gpt-6.1-sol', 'gpt-6-astra']);
const state = {
  range: '30d',
  sources: ['codex', 'opencode', 'hermes'],
  models: [...GPT_MODELS],
  availableModels: [],
  modelAvailabilityResolved: false,
  modelFallbackNotice: false,
  restoredModelsRejected: false,
  resetType: 'weekly',
  resetOffset: 0,
  breakdownOffset: 0,
  breakdownLimit: BREAKDOWN_PAGE_SIZE,
  fromDate: '',
  toDate: '',
  tokenOverlay: true,
  tokenMetric: 'cost',
  comparePrevious: false,
  explicitModels: false,
};
let limitsChart = null;
let weeklyLimitValueChart = null;
let tokensChart = null;
let refreshTimer = null;
let limitPoints = [];
let tokenPoints = [];
let tokenSourcePoints = [];
let limitDatasets = [];
let weeklyLimitValueDatasets = [];
let tokenDatasets = [];
let lastPayload = null;
let displayedResetData = null;
let diagnosticsPayload = null;
let diagnosticsState = '';
let currentPeriod = {};
let refreshSequence = 0;
let modelDraft = null;
let modelSearch = '';
let modelFamily = 'all';
let pendingBaseSequence = null;
let filterTimer = null;
let filtersPending = false;
const requestControllers = new Map();
const sectionSequences = new Map();
const deferredTables = new Map();
const localFormatters = new Map();
const FILTER_STORAGE_KEY = 'codex-usage-monitor.analytics-filters';
function cachedFormatter(kind, language, options) {
  const key = JSON.stringify([kind, language, options]);
  if (!localFormatters.has(key)) {
    if (localFormatters.size >= 64) localFormatters.delete(localFormatters.keys().next().value);
    localFormatters.set(key, kind === 'date' ? new Intl.DateTimeFormat(language, options) : new Intl.NumberFormat(language, options));
  }
  return localFormatters.get(key);
}
function timezone() { return typeof CodexPreferences === 'object' ? CodexPreferences.timezone() : PARIS_ZONE; }
function validFilterDate(value) {
  return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value) && Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value;
}
function restoreFilters() {
  let saved = {};
  try { saved = JSON.parse(localStorage.getItem(FILTER_STORAGE_KEY) || '{}') || {}; if (typeof saved !== 'object' || Array.isArray(saved)) saved = {}; } catch (_error) { /* Storage is optional. */ }
  if (typeof location === 'object' && typeof URLSearchParams === 'function') {
    const query = new URLSearchParams(location.search);
    if (!query.has('range') && query.has('from_date') && query.has('to_date')) saved.range = 'custom';
    for (const key of ['range', 'sources', 'models', 'from_date', 'to_date', 'reset_type', 'compare']) {
      if (query.has(key)) saved[key] = query.get(key);
    }
  }
  if (['24h', '7d', '30d', '90d', '1y', 'all', 'custom'].includes(saved.range)) state.range = saved.range;
  const list = value => Array.isArray(value) ? value : typeof value === 'string' ? value.split(',') : [];
  const sources = list(saved.sources).filter(value => ['codex', 'opencode', 'hermes'].includes(value));
  if (sources.length) state.sources = [...new Set(sources)];
  const models = [...new Set(list(saved.models).filter(value => typeof value === 'string' && value.length > 0 && value.length <= 200 && !/[\x00-\x1f,]/.test(value)))];
  state.restoredModelsRejected = models.length > 50;
  if (models.length && models.length <= 50) { state.models = models; state.explicitModels = true; state.modelAvailabilityResolved = true; }
  if (['all', '5h', 'weekly'].includes(saved.reset_type)) state.resetType = saved.reset_type;
  if (validFilterDate(saved.from_date) && validFilterDate(saved.to_date) && saved.from_date <= saved.to_date) {
    state.fromDate = saved.from_date; state.toDate = saved.to_date;
    if (!saved.range || saved.range === 'custom') state.range = 'custom';
  } else if (state.range === 'custom') state.range = '30d';
  state.comparePrevious = saved.compare === 'previous';
}
function persistFilters() {
  const saved = { range: state.range, sources: state.sources, reset_type: state.resetType, compare: state.comparePrevious ? 'previous' : '' };
  if (state.explicitModels) saved.models = state.models;
  if (state.range === 'custom') { saved.from_date = state.fromDate; saved.to_date = state.toDate; }
  try { localStorage.setItem(FILTER_STORAGE_KEY, JSON.stringify(saved)); } catch (_error) { /* Storage is optional. */ }
  if (typeof history === 'object' && typeof location === 'object') {
    const query = new URLSearchParams(queryString());
    for (const key of ['reset_offset', 'reset_limit', 'breakdown_offset', 'timezone']) query.delete(key);
    try { history.replaceState(null, '', `${location.pathname}?${query}${location.hash}`); } catch (_error) { /* Embedded pages may reject URL updates. */ }
  }
  updateExportLink();
}
function queueRefresh() {
  state.restoredModelsRejected = false;
  filtersPending = true;
  clearTimeout(filterTimer);
  ++refreshSequence;
  for (const controller of requestControllers.values()) controller?.abort();
  requestControllers.clear();
  persistFilters();
  filterTimer = setTimeout(() => refresh(), 120);
}
restoreFilters();
// Keep legend choices across payloads that temporarily omit a dataset (for
// example, an all-null 5-hour series or a period without reset markers).
// Entries are only updated for datasets currently exposed by the chart.
let limitDatasetVisibility = new Map();

function byId(id) { return document.getElementById(id); }
function safeNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : 0;
}
function finiteNumber(value) {
  if (value === null || value === undefined || value === '' || typeof value === 'boolean') return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}
function t(key, values = {}) {
  return typeof CodexPreferences === 'object' ? CodexPreferences.t(`analytics.${key}`, values) : key;
}
function locale() { return typeof CodexPreferences === 'object' ? CodexPreferences.locale() : 'en-GB'; }
function dateFormatter() {
  return typeof CodexPreferences === 'object' ? CodexPreferences.dateFormatter({ day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }) : cachedFormatter('date', locale(), {
    timeZone: timezone(), day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  });
}
function shortDateFormatter() {
  return typeof CodexPreferences === 'object' ? CodexPreferences.dateFormatter({ day: '2-digit', month: 'short', year: 'numeric' }) : cachedFormatter('date', locale(), { timeZone: timezone(), day: '2-digit', month: 'short', year: 'numeric' });
}
function numberFormatter(options = {}) {
  const numberLocale = typeof CodexPreferences === 'object' ? CodexPreferences.numberLocale() : 'en';
  return typeof CodexPreferences === 'object' ? CodexPreferences.numberFormatter(options) : cachedFormatter('number', numberLocale, options);
}
function formatTokens(value) { return numberFormatter({ notation: 'compact', maximumFractionDigits: 2 }).format(safeNumber(value)); }
function formatFullTokens(value) { return numberFormatter().format(safeNumber(value)); }
function formatDate(value) {
  const timestamp = timestampMs(value);
  return timestamp === null ? EMPTY_VALUE : dateFormatter().format(new Date(timestamp));
}
function formatShortDate(value) {
  const timestamp = timestampMs(value);
  return timestamp === null ? EMPTY_VALUE : shortDateFormatter().format(new Date(timestamp));
}
// The server's ordinary period end is authoritative even if the browser clock
// is behind. Custom dates already have explicit boundaries and need no anchor.
function periodAnchor(period) {
  if (period?.range === 'custom') return null;
  const milliseconds = timestampMs(period?.to);
  if (milliseconds === null) return null;
  const seconds = Math.floor(milliseconds / 1000);
  return seconds > 0 ? seconds : null;
}
function timestampMs(value) {
  if (typeof value === 'number' && Number.isFinite(value)) return value > 1e12 ? value : value * 1000;
  if (typeof value !== 'string' || !value) return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}
function formatCost(value) {
  return typeof CodexPreferences === 'object'
    ? CodexPreferences.formatCurrency(safeNumber(value))
    : `$${safeNumber(value).toFixed(safeNumber(value) < 1 ? 4 : 2)}`;
}
function formatUsd(value) {
  const number = finiteNumber(value);
  if (number === null || number < 0) return 'N/A';
  return cachedFormatter('number',
    typeof CodexPreferences === 'object' ? CodexPreferences.numberLocale() : 'en',
    { style: 'currency', currency: 'USD', maximumFractionDigits: number < 1 ? 4 : 2 },
  ).format(number);
}
function setCost(element, value) {
  if (!element) return;
  element.textContent = formatCost(value);
  const currency = typeof CodexPreferences === 'object' ? CodexPreferences.get().currency : 'USD';
  element.title = currency === 'EUR'
    ? t('currencyTooltip', { rate: CodexPreferences.formatRate() })
    : '';
}
function formatSignedPoints(value) {
  const number = Math.round((finiteNumber(value) || 0) * 1000) / 1000;
  return `${number >= 0 ? '+' : ''}${number} ${t('points')}`;
}
function formatPoints(value) { return `${Math.round(safeNumber(value) * 1000) / 1000} ${t('points')}`; }
function formatPercent(value) {
  const number = finiteNumber(value);
  return number === null ? EMPTY_VALUE : `${Math.round(number * 10) / 10}%`;
}
function formatChartValue(value, kind) {
  if (kind === 'percent') return formatPercent(value);
  if (kind === 'usd') return formatUsd(value);
  if (kind === 'cost') return formatCost(value);
  return t('tokenValue', { value: formatFullTokens(value) });
}
function totalBillable(summary) {
  return safeNumber(summary?.input_tokens)
    + safeNumber(summary?.cache_read_tokens)
    + safeNumber(summary?.cache_write_tokens)
    + safeNumber(summary?.output_tokens);
}
function pointTotal(point) {
  return totalBillable(point || {});
}
function pointCost(point) {
  return safeNumber(point?.estimated_cost_usd ?? point?.cost_usd ?? point?.cost);
}
function formatDuration(seconds) {
  const value = safeNumber(seconds);
  if (value < 60) return `${value}s`;
  if (value < 3600) return `${Math.round(value / 60)}m`;
  return `${Math.round(value / 360) / 10}h`;
}

function clearRows(body) {
  if (!body) return;
  if (typeof body.replaceChildren === 'function') body.replaceChildren();
  else while (body.firstChild) body.removeChild(body.firstChild);
}
function replaceRows(body, fragment) {
  if (!body) return;
  if (typeof body.replaceChildren === 'function') body.replaceChildren(fragment);
  else { clearRows(body); while (fragment.firstChild) body.appendChild(fragment.removeChild(fragment.firstChild)); }
}
function deferTable(id, populate) {
  const body = byId(id);
  const details = body?.closest('details');
  const previous = deferredTables.get(id);
  const entry = { details, populate, dirty: true };
  deferredTables.set(id, entry);
  if (details && !previous) details.addEventListener('toggle', () => {
    const current = deferredTables.get(id);
    if (details.open && current?.dirty) { current.populate(); current.dirty = false; }
  });
  if (!details || details.open || typeof Chart !== 'function') {
    if (details && typeof Chart !== 'function') details.open = true;
    populate(); entry.dirty = false;
  } else clearRows(body);
}
function showChartFallback(id) {
  const entry = deferredTables.get(id);
  if (entry) {
    if (entry.details) entry.details.open = true;
    if (entry.dirty) { entry.populate(); entry.dirty = false; }
  }
}
function renderChartSection(name, data) {
  const sections = {
    limits: [renderLimits, 'limits-data-body', 'limits-chart-wrap', 'limits-chart-summary'],
    weekly: [renderWeeklyLimitValue, 'weekly-limit-value-data-body', 'weekly-limit-value-chart-wrap', 'weekly-limit-value-summary'],
    tokens: [renderTokens, 'tokens-data-body', 'tokens-chart-wrap', 'tokens-chart-summary'],
  };
  const [draw, table, wrap, summary] = sections[name];
  try {
    draw(data);
    if (typeof Chart !== 'function') {
      showChartFallback(table);
      byId(summary).textContent += ` · ${t('chartFallbackTable')}`;
    }
  } catch (_error) {
    byId(wrap).hidden = true;
    if (name === 'tokens') byId('tokens-chart-card').hidden = false;
    showChartFallback(table);
    byId(summary).textContent += ` · ${t('chartFallbackTable')}`;
    const instance = name === 'limits' ? limitsChart : name === 'weekly' ? weeklyLimitValueChart : tokensChart;
    try { instance?.destroy(); } catch (_ignored) { /* Broken charts may reject cleanup. */ }
    if (name === 'limits') limitsChart = null;
    else if (name === 'weekly') weeklyLimitValueChart = null;
    else tokensChart = null;
  }
}
function cell(row, value, className = '') {
  const element = document.createElement('td');
  element.textContent = value === null || value === undefined ? EMPTY_VALUE : String(value);
  if (className) element.className = className;
  row.appendChild(element);
  return element;
}
function pillCell(row, value) {
  const element = cell(row, '');
  const pill = document.createElement('span');
  pill.className = 'source-pill';
  pill.textContent = value === null || value === undefined ? EMPTY_VALUE : String(value);
  element.appendChild(pill);
  return element;
}
function setMessage(id, messages) {
  const element = byId(id);
  if (!element) return;
  const values = (Array.isArray(messages) ? messages : messages ? [messages] : []).map(localizeMessage);
  element.textContent = values.join(' · ');
  element.hidden = values.length === 0;
}
function isPriceWarning(message) {
  return typeof message === 'string' && PRICE_WARNING_PATTERN.test(message);
}
function localizeMessage(message) {
  if (typeof message !== 'string') return message;
  const priceWarning = PRICE_WARNING_PATTERN.exec(message);
  if (priceWarning) return t('sourcePriceUnknown', { name: priceWarning[1] });
  const collectorWarning = /^(.+) collector: (.+)$/u.exec(message);
  if (collectorWarning) return t('collectorWarning', { name: collectorWarning[1], message: collectorWarning[2] });
  return message;
}
function renderWarnings(warnings) {
  const values = Array.isArray(warnings) ? [...warnings] : warnings ? [warnings] : [];
  if (state.restoredModelsRejected) values.push(t('restoredModelsRejected'));
  setMessage('analytics-warnings', values.filter(message => !isPriceWarning(message)));
  setMessage('analytics-price-warnings', values.filter(isPriceWarning));
}

function queryString() {
  const query = new URLSearchParams({
    reset_type: state.resetType,
    reset_offset: String(state.resetOffset),
    reset_limit: String(RESET_PAGE_SIZE),
    breakdown_offset: String(state.breakdownOffset),
  });
  if (state.sources.length) query.set('sources', state.sources.join(','));
  if (state.models.length) query.set('models', state.models.join(','));
  if (state.range === 'custom') {
    query.set('from_date', state.fromDate);
    query.set('to_date', state.toDate);
  } else {
    query.set('range', state.range);
  }
  query.set('timezone', timezone());
  if (state.comparePrevious) query.set('compare', 'previous');
  return query.toString();
}

function pointTimestamp(point) {
  return timestampMs(point?.at ?? point?.x);
}
function chartBounds(points) {
  const timestamps = points.map(pointTimestamp).filter(value => value !== null);
  if (!timestamps.length) return {};
  const firstData = Math.min(...timestamps);
  const periodStart = timestampMs(currentPeriod.from);
  const periodEnd = timestampMs(currentPeriod.to);
  const min = periodStart === null ? firstData : Math.max(periodStart, firstData);
  const max = periodEnd === null ? Date.now() : periodEnd;
  return max > min ? { min, max } : { min };
}
function applyChartBounds(options, points) {
  if (!options?.scales?.x) return;
  const bounds = chartBounds(points);
  if (bounds.min === undefined) delete options.scales.x.min;
  else options.scales.x.min = bounds.min;
  if (bounds.max === undefined) delete options.scales.x.max;
  else options.scales.x.max = bounds.max;
}
function chartBase(points = []) {
  let options = {
    responsive: true,
    maintainAspectRatio: false,
    parsing: false,
    normalized: true,
    animation: false,
    scales: {
      x: {
        type: 'linear',
        grid: { color: 'rgba(255,255,255,.05)' },
        ticks: { color: '#86a2c5', maxTicksLimit: 8, callback: value => formatShortDate(value) },
      },
      y: { beginAtZero: true, grid: { color: 'rgba(255,255,255,.05)' }, ticks: { color: '#86a2c5' } },
    },
    plugins: {
      legend: { labels: { color: '#edf5ff', boxWidth: 12 } },
      tooltip: { callbacks: { title: items => items.length ? formatDate(items[0].parsed.x) : '' } },
    },
  };
  applyChartBounds(options, points);
  if (typeof CodexChartInteractions === 'object') {
    options = CodexChartInteractions.enhanceOptions(options, {
      formatTitle: value => formatDate(value),
      formatValue: formatChartValue,
    });
  }
  return options;
}
function tokenAxis() {
  return {
    beginAtZero: true,
    position: 'right',
    grid: { drawOnChartArea: false },
    ticks: {
      color: '#c4b5fd',
      callback: value => state.tokenMetric === 'cost' ? formatCost(value) : formatTokens(value),
    },
  };
}
function overlayTokenDatasets() {
  return tokenDatasets.map(dataset => ({
    ...dataset,
    type: 'bar',
    yAxisID: 'tokens',
    borderWidth: 0,
    barPercentage: 0.8,
    categoryPercentage: 0.8,
  }));
}
function updateTokenMetricToggle() {
  const toggle = byId('token-metric-toggle');
  if (!toggle) return;
  const cost = state.tokenMetric === 'cost';
  toggle.setAttribute('aria-pressed', String(cost));
  toggle.textContent = cost ? t('showTokens') : t('showCost');
}
function updateTokenOverlay() {
  const available = limitPoints.length > 0 && tokenPoints.length > 0;
  const active = state.tokenOverlay && available && Boolean(limitsChart);
  const toggle = byId('toggle-token-overlay');
  if (toggle) {
    toggle.disabled = !available;
    toggle.setAttribute('aria-pressed', String(active));
    toggle.textContent = active ? t('showTokensSeparately') : t('overlayTokens');
  }
  const metricToggle = byId('token-metric-toggle');
  const metricTarget = byId(active ? 'limits-chart-actions' : 'tokens-chart-actions');
  const metricAnchor = byId(active ? 'toggle-token-overlay' : 'event-count');
  if (metricToggle && metricTarget) metricTarget.insertBefore(metricToggle, metricAnchor);
  const tokenCard = byId('tokens-chart-card');
  if (tokenCard) tokenCard.hidden = active;
  if (!limitsChart) return;
  limitsChart.data.datasets = active ? [...limitDatasets, ...overlayTokenDatasets()] : [...limitDatasets];
  applyChartBounds(limitsChart.options, active ? [...limitPoints, ...tokenPoints] : limitPoints);
  if (active) limitsChart.options.scales.tokens = tokenAxis();
  else delete limitsChart.options.scales.tokens;
  limitsChart.update('none');
}

function chartDatasetVisibility(instance) {
  const visibility = new Map();
  for (const [index, dataset] of (instance?.data?.datasets || []).entries()) {
    if (!dataset?.datasetKey) continue;
    let visible = dataset.hidden !== true;
    try {
      if (typeof instance.isDatasetVisible === 'function') {
        visible = instance.isDatasetVisible(index);
      } else {
        const meta = typeof instance.getDatasetMeta === 'function'
          ? instance.getDatasetMeta(index)
          : null;
        if (meta?.hidden !== null && meta?.hidden !== undefined) visible = !meta.hidden;
      }
    } catch (_error) {
      // Dataset.hidden remains a safe fallback during chart replacement.
    }
    visibility.set(dataset.datasetKey, visible);
  }
  return visibility;
}

function applyChartDatasetVisibility(instance, datasets, visibility) {
  for (const [index, dataset] of datasets.entries()) {
    if (!dataset?.datasetKey || !visibility.has(dataset.datasetKey)) continue;
    const visible = visibility.get(dataset.datasetKey);
    dataset.hidden = !visible;
    try {
      const meta = typeof instance.getDatasetMeta === 'function'
        ? instance.getDatasetMeta(index)
        : null;
      if (meta) meta.hidden = visible ? null : true;
    } catch (_error) {
      // Dataset.hidden remains authoritative when metadata is unavailable.
    }
  }
}

function rememberChartDatasetVisibility(instance) {
  const current = chartDatasetVisibility(instance);
  for (const [datasetKey, visible] of current) {
    limitDatasetVisibility.set(datasetKey, visible);
  }
  return new Map(limitDatasetVisibility);
}

function markerDataset(markers, window) {
  const values = markers
    .filter(marker => marker && (marker.window === window || marker.kind === window))
    .map(marker => timestampMs(marker.at ?? marker.reset_at))
    .filter(value => value !== null);
  if (!values.length) return null;
  const label = window === '5h' ? t('fiveHourResetMarkers') : t('weeklyResetMarkers');
  const data = [];
  for (const x of values) data.push({ x, y: 0 }, { x, y: 100 }, { x, y: null });
  return {
    datasetKey: `reset-${window}`,
    label,
    data,
    borderColor: window === '5h' ? '#fbbf24' : '#f0abfc',
    borderDash: [4, 4],
    borderWidth: 1,
    pointRadius: 0,
    fill: false,
    spanGaps: false,
    resetMarker: true,
    timeSliceExcluded: true,
    hidden: window === '5h',
  };
}
function renderLimitTable(points) {
  const body = byId('limits-data-body');
  const fragment = document.createDocumentFragment();
  for (const point of points) {
    const row = document.createElement('tr');
    cell(row, formatDate(point.at));
    cell(row, formatPercent(point.five_h_pct));
    cell(row, formatPercent(point.weekly_pct));
    cell(row, formatPercent(point.ideal_weekly_pct));
    cell(row, formatPercent(point.forecast_chance_24h_pct));
    cell(row, formatPercent(point.forecast_chance_6h_pct));
    fragment.appendChild(row);
  }
  replaceRows(body, fragment);
}
function renderLimits(data = {}) {
  const visibility = rememberChartDatasetVisibility(limitsChart);
  limitPoints = Array.isArray(data.series) ? data.series : [];
  const markers = Array.isArray(data.reset_markers)
    ? data.reset_markers
    : Array.isArray(data.markers) ? data.markers : [];
  const sampleCount = data.samples ?? limitPoints.reduce((total, point) => total + safeNumber(point.samples || 1), 0);
  const forecastSampleCount = data.forecast_samples
    ?? limitPoints.reduce((total, point) => total + safeNumber(point.forecast_samples), 0);
  byId('limit-samples').textContent = t('samples', { value: formatFullTokens(sampleCount) });
  byId('limits-empty').hidden = limitPoints.length > 0;
  byId('limits-chart-wrap').hidden = limitPoints.length === 0 || typeof Chart !== 'function';
  deferTable('limits-data-body', () => renderLimitTable(limitPoints));
  const first = limitPoints[0];
  const last = limitPoints[limitPoints.length - 1];
  byId('limits-chart-summary').textContent = limitPoints.length
    ? t('limitChartSummary', {
      samples: formatFullTokens(sampleCount),
      from: formatDate(first.at),
      to: formatDate(last.at),
      resets: formatFullTokens(markers.length),
      forecasts: formatFullTokens(forecastSampleCount),
    })
    : t('noLimitSamples');
  const limitCandidates = [
    {
      datasetKey: 'five-hour',
      label: t('fiveHourRemaining'),
      data: limitPoints.map(point => ({ x: timestampMs(point.at), y: finiteNumber(point.five_h_pct) })),
      borderColor: '#22c55e', backgroundColor: 'rgba(34,197,94,.10)', fill: true, borderWidth: 2, pointRadius: 0, tension: 0, spanGaps: false,
      valueKind: 'percent',
      hidden: visibility.has('five-hour') ? !visibility.get('five-hour') : true,
    },
    {
      datasetKey: 'weekly',
      label: t('weeklyRemaining'),
      data: limitPoints.map(point => ({ x: timestampMs(point.at), y: finiteNumber(point.weekly_pct) })),
      borderColor: '#38bdf8', backgroundColor: 'rgba(56,189,248,.07)', fill: true, borderWidth: 2, pointRadius: 0, tension: 0, spanGaps: false,
      valueKind: 'percent',
    },
    {
      datasetKey: 'ideal-weekly',
      label: t('idealWeeklyPace'),
      data: limitPoints.map(point => ({ x: timestampMs(point.at), y: finiteNumber(point.ideal_weekly_pct) })),
      borderColor: '#a7f3d0', backgroundColor: 'transparent', fill: false, borderWidth: 2, borderDash: [8, 6], pointRadius: 0, tension: 0, spanGaps: false,
      valueKind: 'percent',
    },
    {
      datasetKey: 'forecast-24h',
      label: t('forecast24h'),
      data: limitPoints.map(point => ({ x: timestampMs(point.at), y: finiteNumber(point.forecast_chance_24h_pct) })),
      borderColor: '#a78bfa', backgroundColor: 'transparent', fill: false, borderWidth: 2, pointRadius: 0, tension: 0.3, spanGaps: false,
      valueKind: 'percent',
    },
    {
      datasetKey: 'forecast-6h',
      label: t('forecast6h'),
      data: limitPoints.map(point => ({ x: timestampMs(point.at), y: finiteNumber(point.forecast_chance_6h_pct) })),
      borderColor: '#fbbf24', backgroundColor: 'transparent', fill: false, borderWidth: 2, pointRadius: 0, tension: 0.3, spanGaps: false,
      valueKind: 'percent',
    },
  ];
  limitDatasets = limitCandidates.filter(dataset => dataset.data.some(point => point.y !== null));
  for (const window of ['5h', 'weekly']) {
    const dataset = markerDataset(markers, window);
    if (dataset) limitDatasets.push(dataset);
  }
  for (const dataset of limitDatasets) {
    if (!dataset.datasetKey || !visibility.has(dataset.datasetKey)) continue;
    dataset.hidden = !visibility.get(dataset.datasetKey);
  }
  if (typeof Chart !== 'function' || !limitPoints.length) {
    if (limitsChart) { limitsChart.destroy(); limitsChart = null; }
    updateTokenOverlay();
    return;
  }
  if (limitsChart) {
    limitsChart.data.datasets = [...limitDatasets];
    applyChartDatasetVisibility(limitsChart, limitsChart.data.datasets, visibility);
    applyChartBounds(limitsChart.options, limitPoints);
    limitsChart.update('none');
    updateTokenOverlay();
    return;
  }
  const options = chartBase(limitPoints);
  options.scales.y.max = 100;
  options.scales.y.ticks.callback = value => `${value}%`;
  limitsChart = new Chart(byId('limits-chart').getContext('2d'), { type: 'line', data: { datasets: limitDatasets }, options });
  updateTokenOverlay();
}

function weeklyValueQuality(value) {
  const key = `weeklyValueQuality_${String(value || 'unavailable').replace(/[^a-z_]/gu, '')}`;
  return t(key);
}
function weeklyValueReason(value) {
  const keys = {
    ambiguous_limit: 'weeklyValueReasonAmbiguousLimit',
    mixed_models: 'weeklyValueReasonMixedModels',
    mixed_model_insufficient_samples: 'weeklyValueReasonMixedInsufficient',
    mixed_model_fixed_mix: 'weeklyValueReasonMixedFixedMix',
    mixed_model_ill_conditioned: 'weeklyValueReasonMixedIllConditioned',
    mixed_model_poor_fit: 'weeklyValueReasonMixedPoorFit',
    mixed_model_non_positive_coefficients: 'weeklyValueReasonMixedNonPositive',
    mixed_model_unstable_coefficients: 'weeklyValueReasonMixedUnstable',
    mixed_model_target_absent: 'weeklyValueReasonMixedTargetAbsent',
    mixed_model_target_mismatch: 'weeklyValueReasonMixedTargetMismatch',
    deadline_transition: 'weeklyValueReasonDeadlineTransition',
    incomplete_cycle: 'weeklyValueReasonIncompleteCycle',
    insufficient_quota_delta: 'weeklyValueReasonInsufficientDelta',
    invalid_event: 'weeklyValueReasonInvalidEvent',
    invalid_quota_pct: 'weeklyValueReasonInvalidQuota',
    invalid_value: 'weeklyValueReasonInvalidValue',
    missing_deadline: 'weeklyValueReasonMissingDeadline',
    missing_limit_id: 'weeklyValueReasonMissingLimit',
    limit_transition: 'weeklyValueReasonLimitTransition',
    missing_price: 'weeklyValueReasonMissingPrice',
    no_cost: 'weeklyValueReasonNoCost',
    no_events: 'weeklyValueReasonNoEvents',
    quota_increase: 'weeklyValueReasonQuotaIncrease',
    reset_in_window: 'weeklyValueReasonResetInWindow',
    fully_consumed: 'weeklyValueReasonFullyConsumed',
    weekly_only: 'weeklyValueReasonWeeklyOnly',
    stale_boundary: 'weeklyValueReasonStaleBoundary',
    stale_data: 'weeklyValueReasonStaleData',
    window_duration: 'weeklyValueReasonWindowDuration',
    zero_consumed_fraction: 'weeklyValueReasonZeroConsumed',
    zero_quota_delta: 'weeklyValueReasonZeroDelta',
  };
  return value ? t(keys[value] || 'weeklyValueUnavailable') : t('weeklyValueReasonIncompleteCycle');
}
function weeklyValuePointValid(point) {
  return point && finiteNumber(point.value_usd) !== null && point.quality && point.quality !== 'unavailable';
}
function weeklyValueSensitivity(point) {
  if (point?.uncertainty_method !== 'assumed_1_point_quota_error_sensitivity') return null;
  const lower = finiteNumber(point.value_lower_usd);
  const upper = finiteNumber(point.value_upper_usd);
  if (lower === null) return null;
  return upper === null
    ? t('weeklyValueSensitivityUnbounded', { lower: formatUsd(lower) })
    : t('weeklyValueSensitivityBounded', { lower: formatUsd(lower), upper: formatUsd(upper) });
}
function renderWeeklyLimitValueTable(points) {
  const body = byId('weekly-limit-value-data-body');
  const fragment = document.createDocumentFragment();
  for (const point of points) {
    const row = document.createElement('tr');
    cell(row, formatDate(point.at));
    const estimate = cell(row, point.estimateLabel || t('weeklyValueAllModels'));
    if (Array.isArray(point.estimateProviders) && point.estimateProviders.length) {
      estimate.title = point.estimateProviders.join(', ');
    }
    const observed = cell(row, formatUsd(point.observed_cost_usd), point.observed_cost_usd === null ? 'value-unavailable' : '');
    const consumed = finiteNumber(point.quota_consumed_pct_points);
    cell(row, consumed === null ? 'N/A' : formatPercent(consumed));
    cell(row, formatUsd(point.raw_value_usd), point.raw_value_usd === null ? 'value-unavailable' : '');
    cell(row, formatUsd(point.value_usd), point.value_usd === null ? 'value-unavailable' : '');
    const sensitivity = weeklyValueSensitivity(point);
    const sensitivityCell = cell(row, sensitivity || EMPTY_VALUE, sensitivity ? 'value-sensitivity' : '');
    if (sensitivity && finiteNumber(point.coefficient_fraction_per_usd) !== null) {
      const error = finiteNumber(point.coefficient_error_bound_fraction_per_usd);
      sensitivityCell.title = t('weeklyValueSensitivityTitle', {
        coefficient: point.coefficient_fraction_per_usd,
        error: error === null ? t('weeklyValueUnbounded') : error,
      });
    }
    const quality = cell(row, weeklyValueQuality(point.quality), `quality-${point.quality || 'unavailable'}`);
    if (point.dispersion_pct !== undefined && point.dispersion_pct !== null) quality.title = `${formatPercent(point.dispersion_pct)} ${t('weeklyValueDispersion')}`;
    let reasonText = point.carried
      ? t('weeklyValueCarried', { date: formatDate(point.source_at), quality: weeklyValueQuality(point.quality) })
      : point.inferred ? t('weeklyValueInferred')
      : point.mixed_model_reason ? weeklyValueReason(point.mixed_model_reason)
        : point.reason ? weeklyValueReason(point.reason) : t('weeklyValueAvailable');
    if (!point.carried && point.mixed_model_reason === 'mixed_model_insufficient_samples'
      && Number.isFinite(point.mixed_model_sample_count) && Number.isFinite(point.mixed_model_minimum_samples)) {
      reasonText = t('weeklyValueMixedSampleCounts', {
        samples: point.mixed_model_sample_count, minimum: point.mixed_model_minimum_samples,
      });
    }
    const reason = cell(row, reasonText, point.carried ? 'value-carried' : point.inferred ? 'value-inferred' : '');
    if (point.carried) {
      reason.title = t('weeklyValueCarriedTitle', {
        date: formatDate(point.source_at), age: formatDuration(point.source_age_seconds),
        method: point.source_method === 'mixed_model_regression' ? t('weeklyValueCarriedInferred') : t('weeklyValueCarriedDirect'),
        reason: weeklyValueReason(point.carried_from_reason),
      });
      reason.setAttribute('aria-label', reasonText);
    } else if (point.inferred) {
      reason.title = t('weeklyValueInferredTitle', { samples: point.training_sample_count ?? '?' });
      reason.setAttribute('aria-label', reasonText);
    }
    if (point.reason) reason.className = 'value-unavailable';
    fragment.appendChild(row);
  }
  replaceRows(body, fragment);
}
let weeklyValueData = {};
const weeklyValueSelection = new Map();
const weeklyValueDefaults = GPT_MODELS;
const weeklyValueColors = ['#38bdf8', '#a78bfa', '#34d399', '#fbbf24', '#fb7185', '#60a5fa', '#f97316', '#e879f9', '#2dd4bf'];
const weeklyValueModelColors = new Map([
  ['gpt-5.6-luna', '#a78bfa'],
  ['gpt-5.6-terra', '#34d399'],
  ['gpt-5.6-sol', '#fbbf24'],
  ['gpt-6-luna', '#60a5fa'],
  ['gpt-6-sol', '#f97316'],
  ['gpt-6.1-sol', '#e879f9'],
  ['gpt-6-astra', '#fb7185'],
]);
function weeklyValueModelKey(model) {
  return String(model || '').trim().toLowerCase();
}
function renderWeeklyLimitValue(data = {}) {
  weeklyValueData = data;
  const selector = byId('weekly-limit-value-models');
  const models = Array.isArray(data.by_model) ? data.by_model : [];
  const entries = [{ key: 'aggregate', label: t('weeklyValueAllModels'), color: weeklyValueColors[0], data }];
  const estimatesByModel = new Map();
  for (const estimate of models) {
    const modelKey = weeklyValueModelKey(estimate.model);
    if (modelKey && !estimatesByModel.has(modelKey)) estimatesByModel.set(modelKey, estimate);
  }
  const modelNames = [...weeklyValueDefaults, ...[...estimatesByModel.keys()]
    .filter(model => !weeklyValueDefaults.includes(model))];
  const colorsForEntry = index => weeklyValueColors[index % weeklyValueColors.length];
  for (const [index, model] of modelNames.entries()) {
    const estimate = estimatesByModel.get(model) || { model, providers: [], series: [], unavailable_reasons: {} };
    const providers = Array.isArray(estimate.providers)
      ? estimate.providers.filter(provider => typeof provider === 'string' && provider)
      : estimate.provider ? [estimate.provider] : [];
    const series = (Array.isArray(estimate.series) ? estimate.series : [])
      .map(point => ({ ...point, estimateProviders: providers }))
      .sort((left, right) => timestampMs(left.at) - timestampMs(right.at));
    const reasons = estimate.unavailable_reasons || {};
    entries.push({ key: model, label: estimate.model || model, model, providers,
      color: weeklyValueModelColors.get(model) || colorsForEntry(index + 5),
      data: { ...estimate, series, unavailable_reasons: reasons } });
  }
  const selected = [];
  clearRows(selector);
  for (const entry of entries) {
    if (!weeklyValueSelection.has(entry.key)) {
      let inherited;
      if (entry.model) {
        const suffix = `/${entry.model}`;
        const variants = [...weeklyValueSelection.entries()]
          .filter(([key]) => key.endsWith(suffix)).map(([, active]) => active);
        if (variants.length) inherited = variants.some(Boolean);
      }
      weeklyValueSelection.set(entry.key,
        inherited === undefined ? weeklyValueDefaults.includes(entry.model) : inherited);
    }
    const active = weeklyValueSelection.get(entry.key);
    const points = Array.isArray(entry.data.series) ? entry.data.series : [];
    const valid = points.filter(weeklyValuePointValid);
    const button = document.createElement('button');
    button.type = 'button';
    button.dataset.weeklyModel = entry.key;
    button.setAttribute('aria-pressed', String(active));
    if (entry.providers?.length) button.title = entry.providers.join(', ');
    button.style.setProperty('--series-color', entry.color);
    const swatch = document.createElement('span');
    swatch.className = 'weekly-value-swatch';
    swatch.setAttribute('aria-hidden', 'true');
    button.appendChild(swatch);
    const label = document.createElement('span');
    label.textContent = entry.label;
    button.appendChild(label);
    if (!valid.length) {
      const notice = document.createElement('span');
      notice.className = 'weekly-value-no-data';
      notice.textContent = t('weeklyValueNoPoints');
      button.appendChild(notice);
    }
    selector.appendChild(button);
    if (active) selected.push({ ...entry, points, valid });
  }
  const points = selected.flatMap(entry => entry.points.map(point => ({ ...point, estimateLabel: entry.label })))
    .sort((left, right) => timestampMs(left.at) - timestampMs(right.at));
  const valid = points.filter(weeklyValuePointValid);
  byId('weekly-limit-value-empty').hidden = valid.length > 0;
  byId('weekly-limit-value-chart-wrap').hidden = valid.length === 0 || typeof Chart !== 'function';
  const unavailable = selected.reduce((total, entry) => total + Object.values(entry.data.unavailable_reasons || {})
    .reduce((count, value) => count + safeNumber(value), 0), 0);
  const currentNotice = data.current_status === 'stale_data'
    ? ` · ${t('weeklyValueCurrentUnavailable')}`
    : '';
  byId('weekly-limit-value-summary').textContent = valid.length
    ? `${t('weeklyLimitValueSummary', { valid: valid.length, unavailable, from: formatDate(valid[0].at), to: formatDate(valid[valid.length - 1].at) })}${currentNotice}`
    : `${t('noWeeklyLimitValue')}${currentNotice}`;
  deferTable('weekly-limit-value-data-body', () => renderWeeklyLimitValueTable(points));
  weeklyLimitValueDatasets = selected.map(entry => ({
    label: entry.label,
    data: entry.valid.map(point => ({ x: timestampMs(point.at), y: finiteNumber(point.value_usd) })),
    borderColor: entry.color, backgroundColor: entry.color,
    fill: false, borderWidth: entry.key === 'aggregate' ? 3 : 2, tension: 0.2, spanGaps: false,
    pointBackgroundColor: entry.valid.map(point => point.carried ? 'transparent' : entry.color),
    pointBorderColor: entry.color,
    pointBorderWidth: entry.valid.map(point => point.carried ? 2 : 1),
    pointRadius: entry.valid.map(point => point.carried ? 4 : 3),
    pointStyle: entry.valid.map(point => point.quality === 'high_uncertainty' ? 'crossRot' : point.carried ? 'circle' : point.inferred ? 'star' : point.quality === 'volatile' ? 'triangle' : point.quality === 'low_confidence' ? 'rectRot' : 'circle'),
    segment: { borderDash: context => {
      const left = entry.valid[context.p0DataIndex];
      const right = entry.valid[context.p1DataIndex];
      return left?.carried || right?.carried ? [6, 4] : undefined;
    } },
    valueKind: 'usd',
  }));
  if (typeof Chart !== 'function' || !valid.length) {
    if (weeklyLimitValueChart) { weeklyLimitValueChart.destroy(); weeklyLimitValueChart = null; }
    return;
  }
  if (weeklyLimitValueChart) {
    weeklyLimitValueChart.data.datasets = weeklyLimitValueDatasets;
    applyChartBounds(weeklyLimitValueChart.options, valid);
    weeklyLimitValueChart.options.scales.y.ticks.callback = value => formatUsd(value);
    weeklyLimitValueChart.update('none');
    return;
  }
  const options = chartBase(valid);
  options.scales.y.ticks.callback = value => formatUsd(value);
  options.plugins.legend.display = false;
  weeklyLimitValueChart = new Chart(byId('weekly-limit-value-chart').getContext('2d'), {
    type: 'line', data: { datasets: weeklyLimitValueDatasets }, options,
  });
}

function sourceSeries(tokens) {
  const candidate = tokens?.series_by_source ?? tokens?.series_by_application ?? tokens?.by_source_series;
  if (Array.isArray(candidate)) return candidate.filter(item => item && typeof item === 'object');
  if (candidate && typeof candidate === 'object') {
    return Object.entries(candidate).flatMap(([source, points]) => (Array.isArray(points) ? points.map(point => ({ ...point, source })) : []));
  }
  return [];
}
function groupedSourceSeries(tokens) {
  const flat = sourceSeries(tokens);
  const groups = new Map();
  for (const point of flat) {
    const source = String(point.source ?? point.application ?? 'all');
    if (!groups.has(source)) groups.set(source, []);
    groups.get(source).push(point);
  }
  return groups;
}
function sourceLabel(source) {
  return source === 'all' ? t('allApplications') : source;
}
function tokenDatasetValue(point) {
  return state.tokenMetric === 'cost' ? pointCost(point) : pointTotal(point);
}
function renderTokenTable(tokens) {
  const body = byId('tokens-data-body');
  const fragment = document.createDocumentFragment();
  const groups = groupedSourceSeries(tokens);
  if (!groups.size) groups.set('all', tokenPoints);
  for (const [source, points] of groups) {
    for (const point of points) {
      const row = document.createElement('tr');
      cell(row, formatDate(point.at));
      cell(row, sourceLabel(source));
      cell(row, formatFullTokens(pointTotal(point)));
      const cost = cell(row, '');
      setCost(cost, pointCost(point));
      fragment.appendChild(row);
    }
  }
  replaceRows(body, fragment);
}
function datasetsForTokens(tokens) {
  const groups = groupedSourceSeries(tokens);
  if (groups.size) {
    return [...groups.entries()].map(([source, points]) => ({
      label: sourceLabel(source),
      data: points.map(point => ({ x: timestampMs(point.at), y: tokenDatasetValue(point) })),
      backgroundColor: source === 'codex' ? '#3b82f6' : source === 'opencode' ? '#a78bfa' : source === 'hermes' ? '#22c55e' : '#38bdf8',
      stack: 'applications',
      valueKind: state.tokenMetric,
    }));
  }
  if (state.tokenMetric === 'cost') {
    return [{
      label: t('estimatedCost'),
      data: tokenPoints.map(point => ({ x: timestampMs(point.at), y: pointCost(point) })),
      backgroundColor: '#a78bfa', stack: 'tokens',
      valueKind: 'cost',
    }];
  }
  return [
    { label: t('input'), data: tokenPoints.map(point => ({ x: timestampMs(point.at), y: safeNumber(point.input_tokens) })), backgroundColor: '#3b82f6', stack: 'tokens', valueKind: 'tokens' },
    { label: t('cacheReadWrite'), data: tokenPoints.map(point => ({ x: timestampMs(point.at), y: safeNumber(point.cache_read_tokens) + safeNumber(point.cache_write_tokens) })), backgroundColor: '#a78bfa', stack: 'tokens', valueKind: 'tokens' },
    { label: t('output'), data: tokenPoints.map(point => ({ x: timestampMs(point.at), y: safeNumber(point.output_tokens) })), backgroundColor: '#22c55e', stack: 'tokens', valueKind: 'tokens' },
  ];
}
function renderTokens(data = {}) {
  const summary = data.summary || {};
  tokenPoints = Array.isArray(data.series) ? data.series : [];
  tokenSourcePoints = sourceSeries(data);
  byId('event-count').textContent = t('events', { value: formatFullTokens(summary.events) });
  byId('tokens-empty').hidden = tokenPoints.length > 0;
  byId('tokens-chart-wrap').hidden = tokenPoints.length === 0 || typeof Chart !== 'function';
  byId('tokens-chart-summary').textContent = tokenPoints.length
    ? t('tokenChartSummary', { events: formatFullTokens(summary.events), applications: formatFullTokens(new Set(tokenSourcePoints.map(point => point.source || point.application)).size || 1) })
    : t('noTokenEvents');
  deferTable('tokens-data-body', () => renderTokenTable(data));
  tokenDatasets = datasetsForTokens(data);
  updateTokenMetricToggle();
  if (typeof Chart !== 'function' || !tokenPoints.length) {
    if (tokensChart) { tokensChart.destroy(); tokensChart = null; }
    updateTokenOverlay();
    return;
  }
  if (tokensChart) {
    tokensChart.data.datasets = tokenDatasets;
    applyChartBounds(tokensChart.options, tokenPoints);
    tokensChart.options.scales.y.ticks.callback = value => state.tokenMetric === 'cost' ? formatCost(value) : formatTokens(value);
    tokensChart.update('none');
    updateTokenOverlay();
    return;
  }
  const options = chartBase(tokenPoints);
  options.scales.y.stacked = true;
  options.scales.y.ticks.callback = value => state.tokenMetric === 'cost' ? formatCost(value) : formatTokens(value);
  tokensChart = new Chart(byId('tokens-chart').getContext('2d'), { type: 'bar', data: { datasets: tokenDatasets }, options });
  updateTokenOverlay();
}

function renderBreakdown(items, paginationData) {
  const body = byId('breakdown-body');
  const fragment = document.createDocumentFragment();
  const values = Array.isArray(items) ? items : [];
  byId('breakdown-empty').hidden = values.length > 0;
  for (const item of values) {
    const row = document.createElement('tr');
    pillCell(row, item.source || EMPTY_VALUE);
    cell(row, item.provider || 'unknown');
    cell(row, item.model || 'unknown');
    cell(row, formatTokens(item.input_tokens));
    cell(row, formatTokens(item.cache_read_tokens));
    cell(row, formatTokens(item.cache_write_tokens));
    cell(row, formatTokens(item.output_tokens));
    cell(row, formatTokens(item.reasoning_tokens));
    cell(row, formatTokens(item.total_tokens ?? pointTotal(item)));
    const cost = cell(row, '', item.pricing_status === 'assumed-zero' ? 'pricing-unknown' : '');
    setCost(cost, item.estimated_cost_usd);
    if (item.pricing_status === 'assumed-zero') cost.title = t('pricingUnknownTitle');
    cell(row, item.pricing_status || EMPTY_VALUE, item.pricing_status === 'assumed-zero' ? 'pricing-unknown' : '');
    fragment.appendChild(row);
  }
  replaceRows(body, fragment);
  const pagination = byId('breakdown-pagination');
  if (!paginationData || typeof paginationData !== 'object') {
    pagination.hidden = true;
    byId('breakdown-page-label').textContent = '';
    return;
  }
  const total = safeNumber(paginationData.total);
  const limit = Math.max(1, safeNumber(paginationData.limit) || BREAKDOWN_PAGE_SIZE);
  const offset = safeNumber(paginationData.offset);
  state.breakdownOffset = offset;
  state.breakdownLimit = limit;
  pagination.hidden = total <= limit;
  byId('breakdown-previous').setAttribute('aria-disabled', String(offset === 0));
  byId('breakdown-next').setAttribute('aria-disabled', String(offset + limit >= total));
  const first = total ? offset + 1 : 0;
  byId('breakdown-page-label').textContent = t('pageOf', { from: first, to: Math.min(offset + limit, total), total });
}

function renderResets(data = {}) {
  displayedResetData = data;
  const body = byId('resets-body');
  const fragment = document.createDocumentFragment();
  const items = Array.isArray(data.items) ? data.items : [];
  byId('resets-empty').hidden = items.length > 0;
  for (const item of items) {
    const row = document.createElement('tr');
    pillCell(row, item.window);
    pillCell(row, item.category === 'random' ? t('random') : item.category === 'end_of_week' ? t('endOfWeek') : t('scheduled'));
    cell(row, formatDate(item.reset_at));
    cell(row, formatDate(item.observed_at));
    cell(row, `${item.before_pct ?? EMPTY_VALUE}% → ${item.after_pct ?? EMPTY_VALUE}%`);
    const cycleUnavailable = item.estimated_cycle_cost_usd === null || item.estimated_cycle_cost_usd === undefined;
    const cycleReason = cycleUnavailable ? weeklyValueReason(item.cycle_cost_reason) : '';
    const cycleCost = cell(row, cycleUnavailable ? `N/A — ${cycleReason}` : formatUsd(item.estimated_cycle_cost_usd), cycleUnavailable ? 'value-unavailable' : '');
    if (cycleUnavailable) {
      cycleCost.title = cycleReason;
      cycleCost.setAttribute('aria-label', `N/A: ${cycleReason}`);
    }
    const extrapolatedUnavailable = item.extrapolated_100_value_usd === null || item.extrapolated_100_value_usd === undefined;
    const extrapolatedReason = extrapolatedUnavailable ? weeklyValueReason(item.cycle_cost_reason) : '';
    const extrapolated = cell(row, extrapolatedUnavailable ? `N/A — ${extrapolatedReason}` : formatUsd(item.extrapolated_100_value_usd), extrapolatedUnavailable ? 'value-unavailable' : '');
    if (extrapolatedUnavailable) {
      extrapolated.title = extrapolatedReason;
      extrapolated.setAttribute('aria-label', `N/A: ${extrapolatedReason}`);
    }
    const forecast24h = finiteNumber(item.forecast_chance_24h_pct);
    const forecast6h = finiteNumber(item.forecast_chance_6h_pct);
    cell(
      row,
      forecast24h === null || forecast6h === null
        ? 'N/A'
        : `${t('forecast24h')}: ${formatPercent(forecast24h)} · ${t('forecast6h')}: ${formatPercent(forecast6h)}`,
    );
    fragment.appendChild(row);
  }
  replaceRows(body, fragment);
  const pagination = byId('reset-pagination');
  const total = safeNumber(data.total);
  const limit = Math.max(1, safeNumber(data.limit) || RESET_PAGE_SIZE);
  const offset = safeNumber(data.offset);
  pagination.hidden = total <= limit;
  byId('resets-previous').disabled = offset === 0;
  byId('resets-next').disabled = offset + limit >= total;
  const first = total ? offset + 1 : 0;
  byId('reset-page-label').textContent = t('pageOf', { from: first, to: Math.min(offset + limit, total), total });
}

function freshnessAge(value, explicit) {
  const given = finiteNumber(explicit);
  if (given !== null && given >= 0) return given;
  const timestamp = timestampMs(value);
  return timestamp === null ? null : Math.max(0, (Date.now() - timestamp) / 1000);
}
function collectorStatus(collector, age, interval) {
  if (collector?.status === 'error') return 'error';
  if (collector?.status === 'disabled' || collector?.status === 'unavailable') return collector.status;
  if (collector?.freshness_status === 'stale' || collector?.status === 'stale' || (age !== null && age > interval * 2)) return 'stale';
  return collector?.status || 'unavailable';
}
function renderCollectors(freshness = {}, baselines = {}, period = {}) {
  const grid = byId('collector-grid');
  clearRows(grid);
  const interval = safeNumber(freshness.sample_interval_seconds ?? period.sample_interval_seconds) || 900;
  const collectors = freshness.collectors || {};
  for (const source of ['codex', 'opencode', 'hermes']) {
    const collector = collectors[source] || { status: 'unavailable' };
    const latestAt = collector.latest_data_at || collector.last_data_at || collector.last_success_at;
    const age = freshnessAge(latestAt, collector.age_seconds);
    const status = collectorStatus(collector, age, interval);
    const item = document.createElement('div');
    item.className = 'collector-item';
    const heading = document.createElement('div'); heading.className = 'collector-name';
    const name = document.createElement('span'); name.textContent = source;
    const statusPill = document.createElement('span'); statusPill.className = `status-pill status-${status}`; statusPill.textContent = status;
    heading.append(name, statusPill);
    const detail = document.createElement('p'); detail.className = 'collector-detail';
    const lines = [
      `${t('lastAttempt')}: ${formatDate(collector.last_attempt_at)}`,
      collector.last_success_at
        ? t('lastSuccess', { value: formatDate(collector.last_success_at) })
        : t('noSuccessfulCollection'),
      `${t('dataAge')}: ${age === null ? EMPTY_VALUE : formatDuration(age)}`,
    ];
    if (collector.last_error) lines.push(`${t('lastError')}: ${collector.last_error}`);
    detail.textContent = lines.join('\n');
    item.append(heading, detail);
    grid.appendChild(item);
  }
  const baselineTokens = (baselines.hermes || []).reduce((total, item) => total + safeNumber(item.tokens), 0);
  const note = byId('baseline-note');
  note.hidden = baselineTokens === 0;
  note.textContent = baselineTokens ? t('hermesBaseline', { value: formatFullTokens(baselineTokens) }) : '';
}
function renderFreshness(freshness = {}, period = {}) {
  const interval = safeNumber(freshness.sample_interval_seconds ?? period.sample_interval_seconds) || 900;
  const age = freshnessAge(freshness.limits_last_sample_at, freshness.limits_age_seconds);
  const status = freshness.limits_status || freshness.limits_freshness_status || (age === null ? 'unavailable' : age > interval * 2 ? 'stale' : 'fresh');
  const summary = byId('analytics-freshness');
  summary.textContent = age === null
    ? t('noLimitSample')
    : `${t('lastLimitSample')}: ${formatDate(freshness.limits_last_sample_at)} · ${t('dataAge')}: ${formatDuration(age)} · ${status}`;
  summary.className = `freshness-summary freshness-${status}`;
  renderCollectors(freshness, lastPayload?.baselines || {}, period);
}

function pressedValues(container) {
  return [...container.querySelectorAll('[data-filter-value][aria-pressed="true"]')]
    .map(button => button.dataset.filterValue);
}
function setPressedValues(container, values) {
  const selected = new Set(values);
  for (const button of container.querySelectorAll('[data-filter-value]')) {
    button.setAttribute('aria-pressed', String(selected.has(button.dataset.filterValue)));
  }
}
function addFilterOption(container, value) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'filter-option';
  button.dataset.filterValue = value;
  button.setAttribute('aria-pressed', String(state.models.includes(value)));
  const marker = document.createElement('span');
  marker.className = 'model-check';
  marker.setAttribute('aria-hidden', 'true');
  marker.textContent = '✓';
  const name = document.createElement('span');
  name.className = 'model-name';
  name.textContent = value;
  const family = document.createElement('span');
  family.className = 'model-family-label';
  family.dataset.familyLabel = modelFamilyFor(value);
  button.appendChild(marker);
  button.appendChild(name);
  button.appendChild(family);
  container.appendChild(button);
}
function modelFamilyFor(model) {
  return GPT_MODELS.includes(model) ? 'current' : /^gpt-/i.test(model) ? 'older' : 'other';
}
function catalogModels() {
  const selected = state.explicitModels || state.modelAvailabilityResolved ? state.models : [];
  return [...new Set([...state.availableModels, ...selected, ...(modelDraft || [])])];
}
function visibleModels() {
  return catalogModels().filter(model =>
    (modelFamily === 'all' || modelFamilyFor(model) === modelFamily)
    && model.toLowerCase().includes(modelSearch.trim().toLowerCase()));
}
function modelDraftChanges() {
  const applied = new Set(state.models);
  const draft = new Set(modelDraft || state.models);
  return [...new Set([...applied, ...draft])].filter(model => applied.has(model) !== draft.has(model)).length;
}
function renderModelSelection() {
  const catalog = catalogModels();
  const draft = (modelDraft || state.models).filter(model => catalog.includes(model));
  const visible = new Set(visibleModels());
  const familyKeys = { current: 'currentGpt', older: 'olderGpt', other: 'otherModels' };
  setPressedValues(byId('model-filter'), draft);
  for (const button of byId('model-filter').querySelectorAll('[data-filter-value]')) {
    button.hidden = !visible.has(button.dataset.filterValue);
    const available = state.availableModels.includes(button.dataset.filterValue);
    button.querySelector('[data-family-label]').textContent = t(available ? familyKeys[modelFamilyFor(button.dataset.filterValue)] : 'unavailableModel');
    button.title = available ? '' : t('unavailableModel');
  }
  byId('model-selection-summary').textContent = t('modelSelectionCount', { selected: draft.length, total: catalog.length });
  byId('model-results-count').textContent = t('modelResultsCount', { count: visible.size });
  const empty = byId('model-search-empty');
  empty.hidden = visible.size > 0;
  empty.textContent = t(state.availableModels.length ? 'modelNoResults' : 'modelNoAvailable');
  const changes = modelDraftChanges();
  byId('model-apply-bar').hidden = !changes;
  byId('model-draft-status').textContent = t(!draft.length ? 'modelDraftEmpty' : changes ? 'modelDraftPending' : 'modelDraftSaved', { count: changes });
  byId('apply-model-selection').disabled = !draft.length || !changes;
  byId('reset-model-selection').disabled = !changes;
  byId('clear-model-selection').disabled = !draft.length;
  byId('select-visible-models').disabled = ![...visible].some(model => !draft.includes(model));
  byId('select-gpt').disabled = !state.availableModels.some(model => GPT_MODELS.includes(model));
  byId('select-all-models').disabled = !state.availableModels.length;
  const toggle = byId('toggle-model-explorer');
  toggle.textContent = t(toggle.getAttribute('aria-expanded') === 'true' ? 'hideModels' : 'showModels');
  // Reuse tray controls so keyboard focus survives draft edits and translation.
  const tray = byId('model-selection-tray');
  const controls = new Map([...tray.querySelectorAll('[data-remove-model]')].map(button => [button.dataset.removeModel, button]));
  for (const [model, button] of controls) {
    if (!draft.includes(model)) tray.removeChild(button);
  }
  for (const model of draft) {
    let button = controls.get(model);
    if (!button) {
      button = document.createElement('button');
      button.type = 'button';
      button.className = 'filter-option selected-model';
      button.dataset.removeModel = model;
      button.textContent = `${model} ×`;
      tray.appendChild(button);
    }
    button.setAttribute('aria-label', t('removeModel', { model }));
    button.title = state.availableModels.includes(model) ? '' : t('unavailableModel');
  }
}
function updateModelOptions(models) {
  const normalized = Array.isArray(models) ? [...new Set(models.filter(model => typeof model === 'string' && model.length))] : [];
  const container = byId('model-filter');
  state.availableModels = normalized;
  let shouldRefresh = false;
  if (!state.modelAvailabilityResolved && normalized.length) {
    const availableGpt = normalized.filter(model => GPT_MODELS.includes(model));
    if (availableGpt.length) state.models = availableGpt;
    else {
      state.models = [...normalized]; state.modelFallbackNotice = true; shouldRefresh = true;
    }
    state.modelAvailabilityResolved = true;
  }
  const options = catalogModels();
  const signature = JSON.stringify([normalized, options]);
  if (container.dataset.options === signature) {
    renderModelSelection();
    return shouldRefresh;
  }
  container.dataset.options = signature;
  clearRows(container);
  for (const model of options) {
    addFilterOption(container, model);
    if (!normalized.includes(model)) {
      const button = container.lastElementChild || container.children[container.children.length - 1];
      button.title = t('unavailableModel');
      button.classList.add('model-unavailable');
    }
  }
  renderModelSelection();
  return shouldRefresh;
}

function render(payload) {
  lastPayload = payload;
  const summary = payload.tokens?.summary || {};
  const fields = {
    input: safeNumber(summary.input_tokens),
    cacheRead: safeNumber(summary.cache_read_tokens),
    cacheWrite: safeNumber(summary.cache_write_tokens),
    output: safeNumber(summary.output_tokens),
    reasoning: safeNumber(summary.reasoning_tokens),
  };
  const total = totalBillable(summary);
  byId('input-tokens').textContent = formatTokens(fields.input);
  byId('cache-read-tokens').textContent = formatTokens(fields.cacheRead);
  byId('cache-write-tokens').textContent = formatTokens(fields.cacheWrite);
  byId('output-tokens').textContent = formatTokens(fields.output);
  byId('reasoning-tokens').textContent = formatTokens(fields.reasoning);
  byId('total-tokens').textContent = formatTokens(total);
  byId('total-tokens').title = t('billableTokensTitle', { value: formatFullTokens(total) });
  byId('token-detail').textContent = `${formatTokens(fields.input)} ${t('input').toLowerCase()} · ${formatTokens(fields.cacheRead + fields.cacheWrite)} ${t('cache').toLowerCase()} · ${formatTokens(fields.output)} ${t('output').toLowerCase()}`;
  setCost(byId('estimated-cost'), summary.estimated_cost_usd);
  setCost(byId('allocation-total-cost'), summary.estimated_cost_usd);
  const pricing = payload.pricing || {};
  const currency = typeof CodexPreferences === 'object' ? CodexPreferences.get().currency : 'USD';
  const rateDate = typeof CodexPreferences === 'object' ? CodexPreferences.get().rateDate : '';
  byId('pricing-note').textContent = currency === 'EUR'
    ? t('catalogConverted', { date: pricing.as_of || EMPTY_VALUE, rate: CodexPreferences.formatRate() }) + (rateDate ? ` · ${rateDate}` : '')
    : t('catalog', { date: pricing.as_of || EMPTY_VALUE, currency: pricing.currency || 'USD' });
  const weeklySummary = payload.resets?.weekly_summary || { random: {}, end_of_week: {} };
  const random = weeklySummary.random || {};
  const endOfWeek = weeklySummary.end_of_week || {};
  const weeklyTotal = safeNumber(payload.resets?.weekly_total ?? safeNumber(random.count) + safeNumber(endOfWeek.count));
  byId('weekly-reset-count').textContent = formatFullTokens(weeklyTotal);
  byId('weekly-reset-impact').textContent = t('weeklyResetBreakdown', {
    random: formatFullTokens(random.count),
    regular: formatFullTokens(endOfWeek.count),
  });
  byId('random-reset-count').textContent = formatFullTokens(random.count);
  byId('random-reset-impact').textContent = t('randomResetImpact', {
    gained: formatPoints(random.gained_vs_ideal_pct_points),
    lost: formatPoints(random.lost_vs_ideal_pct_points),
  });
  byId('end-week-reset-count').textContent = formatFullTokens(endOfWeek.count);
  byId('end-week-reset-impact').textContent = t('ofUnusedQuotaExpired', { value: formatPercent(endOfWeek.unused_pct_points) });
  const period = payload.period || {};
  currentPeriod = period;
  renderChartSection('limits', payload.limits || {});
  if (payload.weekly_limit_value) renderChartSection('weekly', payload.weekly_limit_value);
  renderChartSection('tokens', payload.tokens || {});
  renderBreakdown(payload.tokens?.breakdown || [], payload.tokens?.breakdown_pagination);
  if (!payload.pending_sections?.includes('resets')) renderResets(payload.resets || {});
  renderComparison(payload.comparison);
  updateExportLink();
  renderFreshness(payload.freshness || {}, period);
  const refreshForModelFallback = updateModelOptions(payload.available?.models || []);
  renderWarnings(payload.warnings || []);
  setMessage('analytics-error', state.modelFallbackNotice ? t('gptModelsUnavailable') : '');
  setMessage('analytics-local-only', '');
  if (refreshForModelFallback) queueRefresh();
}

function refreshSchedule(payload = lastPayload) {
  const intervalSeconds = Number(payload?.freshness?.sample_interval_seconds ?? payload?.period?.sample_interval_seconds);
  const intervalMs = Number.isFinite(intervalSeconds) && intervalSeconds > 0 ? intervalSeconds * 1000 : ANALYTICS_REFRESH_MS;
  const now = Date.now();
  const nextUpdate = (Math.floor((now - 5_000) / intervalMs) + 1) * intervalMs + 5_000;
  clearTimeout(refreshTimer);
  refreshTimer = setTimeout(refresh, Math.max(1000, nextUpdate - now));
}
function setSectionStatus(section, status, message = '') {
  const element = byId(`${section}-section-status`);
  if (!element) return;
  element.hidden = !status;
  element.textContent = status === 'loading' ? t('loadingSection') : message || t('sectionFailed');
  const card = byId(section === 'weekly' ? 'weekly-limit-value-card' : section === 'resets' ? 'reset-history-card' : 'allocation-card');
  card?.setAttribute('aria-busy', String(status === 'loading'));
}
function compatiblePayload(base, component) {
  if (base.revision !== undefined && component.revision !== base.revision) return false;
  for (const key of ['from', 'to']) {
    if (base.period?.[key] !== undefined && component.period?.[key] !== base.period[key]) return false;
  }
  return true;
}
async function fetchAnalytics(section, query, signal) {
  const params = new URLSearchParams(query);
  params.set('sections', section);
  const response = await fetch(`/api/analytics?${params}`, { headers: { Accept: 'application/json' }, signal });
  let payload;
  try { payload = await response.json(); } catch (_error) { payload = {}; }
  if (!response.ok) {
    const error = new Error(payload.error || `HTTP ${response.status}`); error.status = response.status; throw error;
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw new Error(t('unableToLoadAnalytics'));
  return payload;
}
async function loadSection(section, generation, base, query) {
  const sequence = (sectionSequences.get(section) || 0) + 1;
  sectionSequences.set(section, sequence);
  requestControllers.get(section)?.abort();
  const controller = typeof AbortController === 'function' ? new AbortController() : null;
  requestControllers.set(section, controller);
  const params = new URLSearchParams(query);
  const anchor = periodAnchor(base.period);
  if (anchor !== null) params.set('at', String(anchor));
  setSectionStatus(section, 'loading');
  try {
    const component = await fetchAnalytics(section, params.toString(), controller?.signal);
    if (generation !== refreshSequence || sequence !== sectionSequences.get(section)) return;
    if (!compatiblePayload(base, component)) { const error = new Error('Analytics changed during loading'); error.revisionMismatch = true; throw error; }
    // Component responses own only their section. Legacy responses may include the full payload.
    if (section === 'weekly') {
      if (!component.weekly_limit_value) throw new Error(t('sectionFailed'));
      lastPayload = { ...lastPayload, weekly_limit_value: component.weekly_limit_value };
      renderChartSection('weekly', component.weekly_limit_value);
    } else if (section === 'resets') {
      if (!component.resets) throw new Error(t('sectionFailed'));
      lastPayload = { ...lastPayload, resets: component.resets };
      renderResets(component.resets);
    } else {
      if (!component.tokens) throw new Error(t('sectionFailed'));
      lastPayload = { ...lastPayload, tokens: { ...lastPayload.tokens, breakdown: component.tokens.breakdown, breakdown_pagination: component.tokens.breakdown_pagination } };
      renderBreakdown(component.tokens.breakdown, component.tokens.breakdown_pagination);
    }
    lastPayload.pending_sections = (lastPayload.pending_sections || []).filter(value => value !== section);
    lastPayload.warnings = [...new Set([...(lastPayload.warnings || []), ...(component.warnings || [])])];
    renderWarnings(lastPayload.warnings);
    setSectionStatus(section, '');
  } catch (error) {
    if (generation !== refreshSequence || sequence !== sectionSequences.get(section) || error?.name === 'AbortError') return;
    if (section === 'breakdown') state.breakdownOffset = safeNumber(lastPayload?.tokens?.breakdown_pagination?.offset);
    if (section === 'resets') state.resetOffset = safeNumber(lastPayload?.resets?.offset);
    setSectionStatus(section, 'error', `${error.message} · ${t('sectionFailed')}`);
    if (error.revisionMismatch) throw error;
  } finally {
    if (requestControllers.get(section) === controller) requestControllers.delete(section);
  }
}
async function refresh({ section = 'base', revisionRetry = false, coherent = false } = {}) {
  // A pending base owns an older query. Restart it with the latest controls
  // before it can overwrite a newer component selection or pagination page.
  if (filtersPending || pendingBaseSequence !== null) section = 'base';
  filtersPending = false;
  clearTimeout(filterTimer);
  if (section !== 'base' && lastPayload) {
    try { await loadSection(section, refreshSequence, lastPayload, queryString()); }
    catch (error) { if (error.revisionMismatch) await refresh({ revisionRetry: true }); }
    updateExportLink();
    return;
  }
  const sequence = ++refreshSequence;
  pendingBaseSequence = sequence;
  clearTimeout(refreshTimer);
  for (const controller of requestControllers.values()) controller?.abort();
  requestControllers.clear();
  const coherentPending = coherent
    ? ['weekly', 'resets'].filter(name => lastPayload?.pending_sections?.includes(name)) : [];
  for (const name of ['weekly', 'resets', 'breakdown']) {
    setSectionStatus(name, coherentPending.includes(name) ? 'loading' : '');
  }
  const controller = typeof AbortController === 'function' ? new AbortController() : null;
  requestControllers.set('base', controller);
  const loading = byId('analytics-loading');
  if (loading) loading.hidden = false;
  const query = queryString();
  try {
    const payload = await fetchAnalytics(coherent ? 'full' : 'base', query, controller?.signal);
    if (sequence !== refreshSequence) return;
    pendingBaseSequence = null;
    render(payload);
    if (sequence !== refreshSequence) return;
    for (const name of coherentPending) setSectionStatus(name, '');
    persistFilters();
    if (loading) loading.hidden = true;
    refreshDiagnostics(sequence);
    const pending = payload.pending_sections || [!payload.weekly_limit_value ? 'weekly' : null].filter(Boolean);
    await Promise.all(pending.filter(name => ['weekly', 'resets'].includes(name)).map(name => loadSection(name, sequence, payload, query)));
  } catch (error) {
    if (sequence !== refreshSequence || error?.name === 'AbortError') return;
    if (error.revisionMismatch) {
      // Two changing snapshots must never be mixed. A single full response
      // pins every section to one database snapshot without an unbounded retry.
      await refresh(revisionRetry ? { coherent: true } : { revisionRetry: true }); return;
    }
    const message = error instanceof Error ? error.message : t('unableToLoadAnalytics');
    for (const name of coherentPending) setSectionStatus(name, 'error', `${message} · ${t('showingLastData')}`);
    const localOnly = error?.status === 404 || /local mode/i.test(message);
    setMessage('analytics-local-only', localOnly ? t('localOnly') : '');
    setMessage('analytics-error', lastPayload ? `${message} · ${t('showingLastData')}` : message);
  } finally {
    if (sequence === refreshSequence) {
      pendingBaseSequence = null;
      if (loading) loading.hidden = true;
      requestControllers.delete('base');
      refreshSchedule();
    }
  }
}
function renderComparison(comparison) {
  const panel = byId('comparison-summary');
  if (!panel) return;
  panel.hidden = !state.comparePrevious;
  if (!state.comparePrevious) return;
  if (!comparison?.tokens?.summary) { panel.textContent = t('comparisonUnavailable'); return; }
  const previous = comparison.tokens.summary;
  const current = lastPayload?.tokens?.summary || {};
  const delta = totalBillable(current) - totalBillable(previous);
  const costDelta = safeNumber(current.estimated_cost_usd) - safeNumber(previous.estimated_cost_usd);
  const signedTokens = `${delta >= 0 ? '+' : '−'}${formatFullTokens(Math.abs(delta))}`;
  const signedCost = `${costDelta >= 0 ? '+' : '−'}${formatCost(Math.abs(costDelta))}`;
  panel.textContent = `${t('comparison')}: ${formatDate(comparison.period?.from)} – ${formatDate(comparison.period?.to)} · ${t('billableTokens')}: ${formatFullTokens(totalBillable(previous))} (${signedTokens}) · ${t('apiCost')}: ${formatCost(previous.estimated_cost_usd)} (${signedCost})` + (Array.isArray(comparison.warnings) && comparison.warnings.length ? ` · ${comparison.warnings.map(localizeMessage).join(' · ')}` : '');
}
function updateExportLink() {
  const link = byId('csv-download');
  const select = byId('csv-dataset');
  if (!link || !select) return;
  const query = new URLSearchParams(queryString());
  query.set('dataset', select.value || 'limits');
  const anchor = periodAnchor(lastPayload?.period);
  if (anchor !== null && !filtersPending) query.set('at', String(anchor));
  query.delete('reset_offset'); query.delete('breakdown_offset');
  link.href = `/api/analytics.csv?${query}`;
}
function renderDiagnostics(data) {
  const body = byId('diagnostics-body');
  if (!body) return;
  const lines = [];
  const statuses = ['healthy', 'unhealthy', 'degraded', 'stale', 'unavailable', 'ok'];
  const errors = ['alert_state_failed', 'alert_journal_failed', 'alert_cleanup_failed', 'collection_failed'];
  // Allowlisted fields only; never dump diagnostic objects or arbitrary errors.
  for (const [name, source, keys] of [
    ['monitor', data.monitor, ['status', 'last_cycle_at', 'last_success_at', 'consecutive_failures', 'last_cycle_duration_ms', 'interval_seconds', 'age_seconds', 'last_error_at', 'error_code', 'error_message']],
    ['archive', data.archive, ['status', 'snapshots', 'token_events', 'resets', 'anomalies', 'pending_anomalies', 'last_snapshot_at']],
  ]) {
    for (const key of keys) {
      const value = source?.[key];
      if (typeof value !== 'string' && typeof value !== 'number') continue;
      let text;
      if (key.endsWith('_at')) text = formatDate(value);
      else if (key === 'status') text = t(`diagnosticStatuses.${statuses.includes(value) ? value : 'unavailable'}`);
      else if (key === 'error_code' || key === 'error_message') {
        const code = errors.includes(source.error_code) ? source.error_code : 'collection_failed';
        text = key === 'error_code' ? code : t(`diagnosticErrors.${code}`);
      } else {
        if (typeof value !== 'number') continue;
        text = numberFormatter().format(value);
      }
      lines.push(`${t(`diagnosticLabels.${name}`)} · ${t(`diagnosticLabels.${key}`)}: ${text}`);
    }
  }
  const anomalyTypes = ['quota_increase', 'reset_shift', 'reset_in_past', 'reset_missing', 'reset_oscillation'];
  for (const item of (Array.isArray(data.anomalies) ? data.anomalies.slice(0, 20) : [])) {
    const window = item.window === '5h' ? t('fiveHour') : item.window === 'weekly' ? t('weekly') : EMPTY_VALUE;
    const type = anomalyTypes.includes(item.type) ? t(`diagnosticAnomalies.${item.type}`) : EMPTY_VALUE;
    lines.push(`${window} · ${type} · ${formatDate(item.detected_at)} · ${formatPercent(item.before_pct)} → ${formatPercent(item.after_pct)}`);
  }
  const warnings = { 'Monitor health is unavailable.': 'monitorUnavailable', 'Monitor health is stale.': 'monitorStale', 'Archive is unavailable.': 'archiveUnavailable', 'Archive could not be read safely.': 'archiveUnsafe' };
  for (const warning of (Array.isArray(data.warnings) ? data.warnings.slice(0, 10) : [])) {
    if (typeof warning === 'string') {
      const key = Object.prototype.hasOwnProperty.call(warnings, warning) ? warnings[warning] : 'unknown';
      lines.push(t(`diagnosticWarnings.${key}`));
    }
  }
  body.textContent = lines.join('\n');
}
function renderDiagnosticsStatus() {
  setMessage('diagnostics-status', diagnosticsState === 'loading' ? t('loadingSection') : diagnosticsState === 'error' ? t('diagnosticsUnavailable') : '');
}
async function refreshDiagnostics(generation) {
  if (!byId('diagnostics-body')) return;
  diagnosticsState = 'loading';
  renderDiagnosticsStatus();
  try {
    const response = await fetch('/api/diagnostics', { headers: { Accept: 'application/json' } });
    if (!response.ok) throw new Error('unavailable');
    const data = await response.json();
    if (generation !== refreshSequence) return;
    if (data.schema_version !== 1) throw new Error('unsupported');
    diagnosticsPayload = data;
    renderDiagnostics(data);
    diagnosticsState = '';
    renderDiagnosticsStatus();
  } catch (_error) {
    if (generation === refreshSequence) { diagnosticsState = 'error'; renderDiagnosticsStatus(); }
  }
}

for (const button of document.querySelectorAll('[data-range]')) {
  button.addEventListener('click', () => {
    document.querySelectorAll('[data-range]').forEach(item => {
      item.classList.toggle('active', item === button);
      item.setAttribute('aria-pressed', String(item === button));
    });
    state.range = button.dataset.range;
    state.resetOffset = 0;
    state.breakdownOffset = 0;
    byId('custom-dates').hidden = state.range !== 'custom';
    if (state.range !== 'custom') queueRefresh();
  });
}
byId('source-filter').addEventListener('click', event => {
  const button = event.target.closest('[data-filter-value]');
  if (!button) return;
  button.setAttribute('aria-pressed', String(button.getAttribute('aria-pressed') !== 'true'));
  state.sources = pressedValues(byId('source-filter'));
  if (!state.sources.length) {
    button.setAttribute('aria-pressed', 'true');
    state.sources = [button.dataset.filterValue];
  }
  state.resetOffset = 0;
  state.breakdownOffset = 0;
  queueRefresh();
});
function setModelDraft(models) {
  modelDraft = catalogModels().filter(model => models.includes(model));
  renderModelSelection();
}
byId('model-filter').addEventListener('click', event => {
  const button = event.target.closest('[data-filter-value]');
  if (!button) return;
  const model = button.dataset.filterValue;
  const draft = modelDraft || state.models;
  setModelDraft(draft.includes(model) ? draft.filter(value => value !== model) : [...draft, model]);
});
byId('model-selection-tray').addEventListener('click', event => {
  const button = event.target.closest('[data-remove-model]');
  if (!button) return;
  const next = button.nextElementSibling || button.previousElementSibling;
  setModelDraft((modelDraft || state.models).filter(model => model !== button.dataset.removeModel));
  (next || byId('toggle-model-explorer')).focus();
});
byId('select-all-models').addEventListener('click', () => setModelDraft(state.availableModels));
byId('select-gpt').addEventListener('click', () => setModelDraft(state.availableModels.filter(model => GPT_MODELS.includes(model))));
byId('select-visible-models').addEventListener('click', () => setModelDraft([...(modelDraft || state.models), ...visibleModels()]));
byId('clear-model-selection').addEventListener('click', () => setModelDraft([]));
byId('reset-model-selection').addEventListener('click', () => {
  modelDraft = null;
  renderModelSelection();
  byId('toggle-model-explorer').focus();
});
byId('apply-model-selection').addEventListener('click', () => {
  if (!modelDraft?.length || !modelDraftChanges()) return;
  state.explicitModels = true;
  state.models = [...modelDraft];
  modelDraft = null;
  state.modelFallbackNotice = false;
  state.resetOffset = 0;
  state.breakdownOffset = 0;
  renderModelSelection();
  byId('toggle-model-explorer').focus();
  queueRefresh();
});
byId('model-search').addEventListener('input', event => {
  modelSearch = event.target.value;
  renderModelSelection();
});
byId('model-families').addEventListener('click', event => {
  const button = event.target.closest('[data-model-family]');
  if (!button) return;
  modelFamily = button.dataset.modelFamily;
  for (const control of byId('model-families').querySelectorAll('button')) {
    control.setAttribute('aria-pressed', String(control === button));
  }
  renderModelSelection();
});
function collapseModelExplorer() {
  byId('model-explorer').hidden = true;
  byId('toggle-model-explorer').setAttribute('aria-expanded', 'false');
  renderModelSelection();
}
byId('toggle-model-explorer').addEventListener('click', () => {
  if (byId('toggle-model-explorer').getAttribute('aria-expanded') === 'true') collapseModelExplorer();
  else {
    byId('model-explorer').hidden = false;
    byId('toggle-model-explorer').setAttribute('aria-expanded', 'true');
    renderModelSelection();
    byId('model-search').focus();
  }
});
byId('model-explorer').addEventListener('keydown', event => {
  if (event.key !== 'Escape') return;
  event.preventDefault();
  collapseModelExplorer();
  byId('toggle-model-explorer').focus();
});
byId('reset-filter').value = state.resetType;
byId('weekly-limit-value-models').addEventListener('click', event => {
  const button = event.target.closest('button[data-weekly-model]');
  if (!button) return;
  const key = button.dataset.weeklyModel;
  weeklyValueSelection.set(key, !weeklyValueSelection.get(key));
  renderChartSection('weekly', weeklyValueData);
  // Rebuilding translated controls must not lose keyboard focus.
  for (const control of byId('weekly-limit-value-models').querySelectorAll('button')) {
    if (control.dataset.weeklyModel === key) control.focus();
  }
});
byId('reset-filter').addEventListener('change', event => { state.resetType = event.target.value; state.resetOffset = 0; persistFilters(); refresh({ section: 'resets' }); });
byId('apply-dates').addEventListener('click', () => {
  state.fromDate = byId('from-date').value; state.toDate = byId('to-date').value; state.resetOffset = 0; state.breakdownOffset = 0;
  if (!validFilterDate(state.fromDate) || !validFilterDate(state.toDate) || state.fromDate > state.toDate) { setMessage('analytics-error', t('chooseBothDates')); return; }
  queueRefresh();
});
byId('resets-previous').addEventListener('click', () => { state.resetOffset = Math.max(0, state.resetOffset - RESET_PAGE_SIZE); refresh({ section: 'resets' }); });
byId('resets-next').addEventListener('click', () => { state.resetOffset += RESET_PAGE_SIZE; refresh({ section: 'resets' }); });
byId('breakdown-previous').addEventListener('click', event => {
  if (event.currentTarget.getAttribute('aria-disabled') === 'true') return;
  state.breakdownOffset = Math.max(0, state.breakdownOffset - state.breakdownLimit);
  refresh({ section: 'breakdown' });
});
byId('breakdown-next').addEventListener('click', event => {
  if (event.currentTarget.getAttribute('aria-disabled') === 'true') return;
  state.breakdownOffset += state.breakdownLimit;
  refresh({ section: 'breakdown' });
});
byId('toggle-token-overlay').addEventListener('click', () => {
  if (!limitPoints.length || !tokenPoints.length) return;
  state.tokenOverlay = !state.tokenOverlay;
  updateTokenOverlay();
});
byId('token-metric-toggle').addEventListener('click', () => {
  state.tokenMetric = state.tokenMetric === 'tokens' ? 'cost' : 'tokens';
  if (lastPayload) renderChartSection('tokens', lastPayload.tokens || {});
});

function refreshLocalizedAnalytics() {
  if (!lastPayload) return;
  try {
    render(lastPayload);
    // Retained sections remain independent of the new base revision while
    // their replacements are pending, but must still follow display preferences.
    if (!lastPayload.weekly_limit_value && Object.keys(weeklyValueData).length) renderChartSection('weekly', weeklyValueData);
    if (lastPayload.pending_sections?.includes('resets') && displayedResetData) renderResets(displayedResetData);
    if (diagnosticsPayload) renderDiagnostics(diagnosticsPayload);
    renderDiagnosticsStatus();
  } catch (error) { setMessage('analytics-error', error instanceof Error ? error.message : t('unableToLoadAnalytics')); }
}

let activeTimezone = timezone();
if (typeof CodexPreferences === 'object') CodexPreferences.subscribe(() => {
  if (activeTimezone !== timezone()) { activeTimezone = timezone(); queueRefresh(); }
  else refreshLocalizedAnalytics();
});
for (const button of document.querySelectorAll('[data-range]')) {
  const active = button.dataset.range === state.range;
  button.classList.toggle('active', active);
  button.setAttribute('aria-pressed', String(active));
}
byId('custom-dates').hidden = state.range !== 'custom';
byId('from-date').value = state.fromDate;
byId('to-date').value = state.toDate;
setPressedValues(byId('source-filter'), state.sources);
byId('compare-previous').checked = state.comparePrevious;
byId('compare-previous').addEventListener('change', event => { state.comparePrevious = event.target.checked; queueRefresh(); });
byId('csv-dataset').addEventListener('change', updateExportLink);
updateExportLink();
refresh();
