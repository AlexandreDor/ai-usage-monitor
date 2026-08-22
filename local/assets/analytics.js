'use strict';

const ANALYTICS_REFRESH_MS = 900_000;
const RESET_PAGE_SIZE = 50;
const BREAKDOWN_PAGE_SIZE = 50;
const PARIS_ZONE = 'Europe/Paris';
const EMPTY_VALUE = '-';
const PRICE_WARNING_PATTERN = /^No catalog price; assumed zero: (.+)$/u;
const GPT_56_MODELS = Object.freeze(['gpt-5.6-luna', 'gpt-5.6-sol', 'gpt-5.6-terra']);
const state = {
  range: '30d',
  sources: ['codex', 'opencode', 'hermes'],
  models: [...GPT_56_MODELS],
  availableModels: [],
  modelAvailabilityResolved: false,
  modelFallbackNotice: false,
  resetType: 'all',
  resetOffset: 0,
  breakdownOffset: 0,
  breakdownLimit: BREAKDOWN_PAGE_SIZE,
  fromDate: '',
  toDate: '',
  tokenOverlay: true,
  tokenMetric: 'cost',
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
let currentPeriod = {};
let refreshSequence = 0;

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
  return new Intl.DateTimeFormat(locale(), {
    timeZone: PARIS_ZONE, day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  });
}
function shortDateFormatter() {
  return new Intl.DateTimeFormat(locale(), { timeZone: PARIS_ZONE, day: '2-digit', month: 'short', year: 'numeric' });
}
function numberFormatter(options = {}) {
  const numberLocale = typeof CodexPreferences === 'object' ? CodexPreferences.numberLocale() : 'en';
  return new Intl.NumberFormat(numberLocale, options);
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
  return new Intl.NumberFormat(
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
  while (body.firstChild) body.removeChild(body.firstChild);
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
  const values = Array.isArray(warnings) ? warnings : warnings ? [warnings] : [];
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
  const active = state.tokenOverlay && available;
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
  };
}
function renderLimitTable(points) {
  const body = byId('limits-data-body');
  clearRows(body);
  for (const point of points) {
    const row = document.createElement('tr');
    cell(row, formatDate(point.at));
    cell(row, formatPercent(point.five_h_pct));
    cell(row, formatPercent(point.weekly_pct));
    cell(row, formatPercent(point.ideal_weekly_pct));
    cell(row, formatPercent(point.forecast_chance_24h_pct));
    cell(row, formatPercent(point.forecast_chance_6h_pct));
    body?.appendChild(row);
  }
}
function renderLimits(data = {}) {
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
  renderLimitTable(limitPoints);
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
      label: t('fiveHourRemaining'),
      data: limitPoints.map(point => ({ x: timestampMs(point.at), y: finiteNumber(point.five_h_pct) })),
      borderColor: '#22c55e', backgroundColor: 'rgba(34,197,94,.10)', fill: true, borderWidth: 2, pointRadius: 0, tension: 0, spanGaps: false,
      valueKind: 'percent',
    },
    {
      label: t('weeklyRemaining'),
      data: limitPoints.map(point => ({ x: timestampMs(point.at), y: finiteNumber(point.weekly_pct) })),
      borderColor: '#38bdf8', backgroundColor: 'rgba(56,189,248,.07)', fill: true, borderWidth: 2, pointRadius: 0, tension: 0, spanGaps: false,
      valueKind: 'percent',
    },
    {
      label: t('idealWeeklyPace'),
      data: limitPoints.map(point => ({ x: timestampMs(point.at), y: finiteNumber(point.ideal_weekly_pct) })),
      borderColor: '#a7f3d0', backgroundColor: 'transparent', fill: false, borderWidth: 2, borderDash: [8, 6], pointRadius: 0, tension: 0, spanGaps: false,
      valueKind: 'percent',
    },
    {
      label: t('forecast24h'),
      data: limitPoints.map(point => ({ x: timestampMs(point.at), y: finiteNumber(point.forecast_chance_24h_pct) })),
      borderColor: '#a78bfa', backgroundColor: 'transparent', fill: false, borderWidth: 2, pointRadius: 0, tension: 0.3, spanGaps: false,
      valueKind: 'percent',
    },
    {
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
  if (typeof Chart !== 'function' || !limitPoints.length) {
    if (limitsChart) { limitsChart.destroy(); limitsChart = null; }
    updateTokenOverlay();
    return;
  }
  if (limitsChart) {
    limitsChart.data.datasets = [...limitDatasets];
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
function renderWeeklyLimitValueTable(points) {
  const body = byId('weekly-limit-value-data-body');
  clearRows(body);
  for (const point of points) {
    const row = document.createElement('tr');
    cell(row, formatDate(point.at));
    const observed = cell(row, formatUsd(point.observed_cost_usd), point.observed_cost_usd === null ? 'value-unavailable' : '');
    const consumed = finiteNumber(point.quota_consumed_pct_points);
    cell(row, consumed === null ? 'N/A' : formatPercent(consumed));
    cell(row, formatUsd(point.raw_value_usd), point.raw_value_usd === null ? 'value-unavailable' : '');
    cell(row, formatUsd(point.value_usd), point.value_usd === null ? 'value-unavailable' : '');
    const quality = cell(row, weeklyValueQuality(point.quality), `quality-${point.quality || 'unavailable'}`);
    if (point.dispersion_pct !== undefined && point.dispersion_pct !== null) quality.title = `${formatPercent(point.dispersion_pct)} ${t('weeklyValueDispersion')}`;
    const reason = cell(row, point.reason ? weeklyValueReason(point.reason) : t('weeklyValueAvailable'));
    if (point.reason) reason.className = 'value-unavailable';
    body?.appendChild(row);
  }
}
function renderWeeklyLimitValue(data = {}) {
  const points = Array.isArray(data.series) ? data.series : [];
  const valid = points.filter(weeklyValuePointValid);
  byId('weekly-limit-value-empty').hidden = valid.length > 0;
  byId('weekly-limit-value-chart-wrap').hidden = valid.length === 0 || typeof Chart !== 'function';
  const unavailable = Object.values(data.unavailable_reasons || {}).reduce((total, value) => total + safeNumber(value), 0);
  const currentNotice = data.current_status === 'stale_data'
    ? ` · ${t('weeklyValueCurrentUnavailable')}`
    : '';
  byId('weekly-limit-value-summary').textContent = valid.length
    ? `${t('weeklyLimitValueSummary', { valid: valid.length, unavailable, from: formatDate(valid[0].at), to: formatDate(valid[valid.length - 1].at) })}${currentNotice}`
    : `${t('noWeeklyLimitValue')}${currentNotice}`;
  renderWeeklyLimitValueTable(points);
  weeklyLimitValueDatasets = [{
    label: t('weeklyLimitValueTitle'),
    data: valid.map(point => ({ x: timestampMs(point.at), y: finiteNumber(point.value_usd) })),
    borderColor: '#38bdf8', backgroundColor: 'rgba(56,189,248,.10)',
    fill: true, borderWidth: 2, pointRadius: 4, tension: 0.2, spanGaps: false,
    pointBackgroundColor: valid.map(point => point.quality === 'volatile' ? '#fca5a5' : point.quality === 'low_confidence' ? '#fbbf24' : '#86efac'),
    pointStyle: valid.map(point => point.quality === 'volatile' ? 'triangle' : point.quality === 'low_confidence' ? 'rectRot' : 'circle'),
    valueKind: 'usd',
  }];
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
  clearRows(body);
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
      body?.appendChild(row);
    }
  }
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
  renderTokenTable(data);
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
  clearRows(body);
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
    body.appendChild(row);
  }
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
  const body = byId('resets-body');
  clearRows(body);
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
    body.appendChild(row);
  }
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
  button.textContent = value;
  container.appendChild(button);
}
function updateModelOptions(models) {
  const normalized = Array.isArray(models) ? models.filter(model => typeof model === 'string') : [];
  const container = byId('model-filter');
  const changed = normalized.join('\0') !== state.availableModels.join('\0');
  state.availableModels = normalized;
  let shouldRefresh = false;
  if (!state.modelAvailabilityResolved && normalized.length) {
    const availableGpt = normalized.filter(model => GPT_56_MODELS.includes(model));
    if (availableGpt.length) {
      state.models = availableGpt;
    } else {
      state.models = [...normalized];
      state.modelFallbackNotice = true;
      shouldRefresh = normalized.length > 0;
    }
    state.modelAvailabilityResolved = true;
  }
  if (changed) {
    state.models = state.models.filter(model => normalized.includes(model));
    if (!state.models.length && !state.modelFallbackNotice) state.models = [...normalized];
    clearRows(container);
    for (const model of normalized) addFilterOption(container, model);
  } else setPressedValues(container, state.models);
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
  byId('pricing-note').textContent = currency === 'EUR'
    ? t('catalogConverted', { date: pricing.as_of || EMPTY_VALUE, rate: CodexPreferences.formatRate() })
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
  renderLimits(payload.limits || {});
  renderWeeklyLimitValue(payload.weekly_limit_value || {});
  renderTokens(payload.tokens || {});
  renderBreakdown(payload.tokens?.breakdown || [], payload.tokens?.breakdown_pagination);
  renderResets(payload.resets || {});
  renderFreshness(payload.freshness || {}, period);
  const refreshForModelFallback = updateModelOptions(payload.available?.models || []);
  renderWarnings(payload.warnings || []);
  setMessage('analytics-error', state.modelFallbackNotice ? t('gptModelsUnavailable') : '');
  setMessage('analytics-local-only', '');
  if (refreshForModelFallback) setTimeout(refresh, 0);
}

function refreshSchedule(payload = lastPayload) {
  const intervalSeconds = Number(payload?.freshness?.sample_interval_seconds ?? payload?.period?.sample_interval_seconds);
  const intervalMs = Number.isFinite(intervalSeconds) && intervalSeconds > 0 ? intervalSeconds * 1000 : ANALYTICS_REFRESH_MS;
  const now = Date.now();
  const nextUpdate = (Math.floor((now - 5_000) / intervalMs) + 1) * intervalMs + 5_000;
  clearTimeout(refreshTimer);
  refreshTimer = setTimeout(refresh, Math.max(1000, nextUpdate - now));
}
async function refresh({ restoreBreakdownOffsetOnError = false } = {}) {
  const sequence = ++refreshSequence;
  const displayedBreakdownOffset = safeNumber(lastPayload?.tokens?.breakdown_pagination?.offset);
  clearTimeout(refreshTimer);
  const loading = byId('analytics-loading');
  if (loading) loading.hidden = false;
  try {
    const response = await fetch(`/api/analytics?${queryString()}`, { headers: { Accept: 'application/json' } });
    let payload;
    try { payload = await response.json(); } catch (_error) { payload = {}; }
    if (!response.ok) {
      const error = new Error(payload.error || `HTTP ${response.status}`);
      error.status = response.status;
      throw error;
    }
    if (sequence !== refreshSequence) return;
    render(payload);
  } catch (error) {
    if (sequence !== refreshSequence) return;
    if (restoreBreakdownOffsetOnError) state.breakdownOffset = displayedBreakdownOffset;
    const message = error instanceof Error ? error.message : t('unableToLoadAnalytics');
    const localOnly = !lastPayload || error?.status === 503 || /not available|cannot be read|local mode/i.test(message);
    setMessage('analytics-local-only', localOnly ? t('localOnly') : '');
    setMessage('analytics-error', lastPayload ? `${message} · ${t('showingLastData')}` : message);
  } finally {
    if (sequence !== refreshSequence) return;
    if (loading) loading.hidden = true;
    refreshSchedule();
  }
}

for (const button of document.querySelectorAll('[data-range]')) {
  button.addEventListener('click', () => {
    document.querySelectorAll('[data-range]').forEach(item => item.classList.toggle('active', item === button));
    state.range = button.dataset.range;
    state.resetOffset = 0;
    state.breakdownOffset = 0;
    byId('custom-dates').hidden = state.range !== 'custom';
    if (state.range !== 'custom') refresh();
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
  refresh();
});
byId('model-filter').addEventListener('click', event => {
  const button = event.target.closest('[data-filter-value]');
  if (!button) return;
  button.setAttribute('aria-pressed', String(button.getAttribute('aria-pressed') !== 'true'));
  state.models = pressedValues(byId('model-filter'));
  if (!state.models.length) {
    button.setAttribute('aria-pressed', 'true');
    state.models = [button.dataset.filterValue];
  }
  state.resetOffset = 0;
  state.breakdownOffset = 0;
  refresh();
});
byId('select-all-models').addEventListener('click', () => {
  state.models = [...state.availableModels];
  setPressedValues(byId('model-filter'), state.models);
  state.resetOffset = 0;
  state.breakdownOffset = 0;
  refresh();
});
byId('select-gpt-5-6').addEventListener('click', () => {
  const gpt56 = state.availableModels.filter(model => GPT_56_MODELS.includes(model));
  if (!gpt56.length) { setMessage('analytics-error', t('gptModelsUnavailable')); return; }
  state.models = gpt56;
  setPressedValues(byId('model-filter'), state.models);
  state.resetOffset = 0;
  state.breakdownOffset = 0;
  refresh();
});
byId('reset-filter').addEventListener('change', event => { state.resetType = event.target.value; state.resetOffset = 0; refresh(); });
byId('apply-dates').addEventListener('click', () => {
  state.fromDate = byId('from-date').value; state.toDate = byId('to-date').value; state.resetOffset = 0; state.breakdownOffset = 0;
  if (!state.fromDate || !state.toDate) { setMessage('analytics-error', t('chooseBothDates')); return; }
  refresh();
});
byId('resets-previous').addEventListener('click', () => { state.resetOffset = Math.max(0, state.resetOffset - RESET_PAGE_SIZE); refresh(); });
byId('resets-next').addEventListener('click', () => { state.resetOffset += RESET_PAGE_SIZE; refresh(); });
byId('breakdown-previous').addEventListener('click', event => {
  if (event.currentTarget.getAttribute('aria-disabled') === 'true') return;
  state.breakdownOffset = Math.max(0, state.breakdownOffset - state.breakdownLimit);
  refresh({ restoreBreakdownOffsetOnError: true });
});
byId('breakdown-next').addEventListener('click', event => {
  if (event.currentTarget.getAttribute('aria-disabled') === 'true') return;
  state.breakdownOffset += state.breakdownLimit;
  refresh({ restoreBreakdownOffsetOnError: true });
});
byId('toggle-token-overlay').addEventListener('click', () => {
  if (!limitPoints.length || !tokenPoints.length) return;
  state.tokenOverlay = !state.tokenOverlay;
  updateTokenOverlay();
});
byId('token-metric-toggle').addEventListener('click', () => {
  state.tokenMetric = state.tokenMetric === 'tokens' ? 'cost' : 'tokens';
  if (lastPayload) renderTokens(lastPayload.tokens || {});
});

function refreshLocalizedAnalytics() {
  if (!lastPayload) return;
  try { render(lastPayload); } catch (error) { setMessage('analytics-error', error instanceof Error ? error.message : t('unableToLoadAnalytics')); }
}

if (typeof CodexPreferences === 'object') CodexPreferences.subscribe(refreshLocalizedAnalytics);
refresh();
