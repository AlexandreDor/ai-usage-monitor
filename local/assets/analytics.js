'use strict';

const ANALYTICS_REFRESH_MS = 900_000;
const RESET_PAGE_SIZE = 10;
const PARIS_ZONE = 'Europe/Paris';
const state = {
  range: '30d',
  sources: ['codex', 'opencode', 'hermes'],
  models: [],
  availableModels: [],
  resetType: 'all',
  resetOffset: 0,
  fromDate: '',
  toDate: '',
  tokenOverlay: false,
};
let limitsChart = null;
let tokensChart = null;
let refreshTimer = null;
let limitPoints = [];
let tokenPoints = [];
let limitDatasets = [];
let tokenDatasets = [];
let lastPayload = null;

function byId(id) { return document.getElementById(id); }
function safeNumber(value) { const number = Number(value); return Number.isFinite(number) && number >= 0 ? number : 0; }
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
function formatDate(value) { const date = new Date(value); return Number.isFinite(date.getTime()) ? dateFormatter().format(date) : '—'; }
function formatCost(value) { return typeof CodexPreferences === 'object' ? CodexPreferences.formatCurrency(safeNumber(value)) : `$${safeNumber(value).toFixed(safeNumber(value) < 1 ? 4 : 2)}`; }
function setCost(element, value) {
  element.textContent = formatCost(value);
  const currency = typeof CodexPreferences === 'object' ? CodexPreferences.get().currency : 'USD';
  element.title = currency === 'EUR'
    ? t('currencyTooltip', { rate: CodexPreferences.formatRate() })
    : '';
}
function formatSignedPoints(value) {
  const number = Math.round(safeNumber(value) * 1000) / 1000;
  return `${number >= 0 ? '+' : ''}${number} ${t('points')}`;
}
function formatPoints(value) { return `${Math.round(safeNumber(value) * 1000) / 1000} ${t('points')}`; }
function formatPercent(value) { return `${Math.round(safeNumber(value) * 10) / 10}%`; }
function totalBillable(summary) { return safeNumber(summary.input_tokens) + safeNumber(summary.cache_read_tokens) + safeNumber(summary.cache_write_tokens) + safeNumber(summary.output_tokens); }
function formatDuration(seconds) {
  const value = safeNumber(seconds);
  if (value < 60) return `${value}s`;
  if (value < 3600) return `${Math.round(value / 60)}m`;
  return `${Math.round(value / 360) / 10}h`;
}

function formatShortDate(value) { return shortDateFormatter().format(new Date(value)); }

function setMessage(id, messages) {
  const element = byId(id);
  const values = (Array.isArray(messages) ? messages : messages ? [messages] : []).map(localizeMessage);
  element.textContent = values.join(' · ');
  element.hidden = values.length === 0;
}

function localizeMessage(message) {
  if (typeof message !== 'string') return message;
  const priceWarning = /^No catalog price; assumed zero: (.+)$/u.exec(message);
  if (priceWarning) return t('sourcePriceUnknown', { name: priceWarning[1] });
  const collectorWarning = /^(.+) collector: (.+)$/u.exec(message);
  if (collectorWarning) return t('collectorWarning', { name: collectorWarning[1], message: collectorWarning[2] });
  return message;
}

function queryString() {
  const query = new URLSearchParams({ reset_type: state.resetType, reset_offset: String(state.resetOffset), reset_limit: String(RESET_PAGE_SIZE) });
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

function chartBase() {
  return {
    responsive: true, maintainAspectRatio: false, parsing: false, normalized: true, animation: false,
    scales: {
      x: { type: 'linear', grid: { color: 'rgba(255,255,255,.05)' }, ticks: { color: '#86a2c5', maxTicksLimit: 8, callback: value => formatShortDate(value) } },
      y: { beginAtZero: true, grid: { color: 'rgba(255,255,255,.05)' }, ticks: { color: '#86a2c5' } },
    },
    plugins: { legend: { labels: { color: '#edf5ff', boxWidth: 12 } }, tooltip: { callbacks: { title: items => items.length ? formatDate(items[0].parsed.x) : '' } } },
  };
}

function tokenAxis() {
  return {
    beginAtZero: true,
    position: 'right',
    grid: { drawOnChartArea: false },
    ticks: { color: '#c4b5fd', callback: formatTokens },
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

function updateTokenOverlay() {
  const available = limitPoints.length > 0 && tokenPoints.length > 0;
  const active = state.tokenOverlay && available;
  const toggle = byId('toggle-token-overlay');
  toggle.disabled = !available;
  toggle.setAttribute('aria-pressed', String(active));
  toggle.textContent = active ? t('showTokensSeparately') : t('overlayTokens');
  byId('tokens-chart-card').hidden = active;
  if (!limitsChart) return;
  limitsChart.data.datasets = active ? [...limitDatasets, ...overlayTokenDatasets()] : [...limitDatasets];
  if (active) limitsChart.options.scales.tokens = tokenAxis();
  else delete limitsChart.options.scales.tokens;
  limitsChart.update('none');
}

function renderLimits(data) {
  limitPoints = Array.isArray(data.series) ? data.series : [];
  byId('limit-samples').textContent = t('samples', { value: formatFullTokens(data.samples) });
  byId('limits-empty').hidden = limitPoints.length > 0;
  byId('limits-chart-wrap').hidden = limitPoints.length === 0;
  limitDatasets = [
    { label: t('fiveHourRemaining'), data: limitPoints.map(point => ({ x: Date.parse(point.at), y: point.five_h_pct })), borderColor: '#22c55e', backgroundColor: 'rgba(34,197,94,.10)', fill: true, borderWidth: 2, pointRadius: 0, tension: 0, spanGaps: false },
    { label: t('weeklyRemaining'), data: limitPoints.map(point => ({ x: Date.parse(point.at), y: point.weekly_pct })), borderColor: '#38bdf8', backgroundColor: 'rgba(56,189,248,.07)', fill: true, borderWidth: 2, pointRadius: 0, tension: 0, spanGaps: false },
  ];
  if (limitsChart) { limitsChart.data.datasets = [...limitDatasets]; limitsChart.update('none'); updateTokenOverlay(); return; }
  if (typeof Chart !== 'function') throw new Error('Chart.js failed to load');
  const options = chartBase();
  options.scales.y.max = 100;
  options.scales.y.ticks.callback = value => `${value}%`;
  limitsChart = new Chart(byId('limits-chart').getContext('2d'), { type: 'line', data: { datasets: limitDatasets }, options });
  updateTokenOverlay();
}

function renderTokens(data) {
  tokenPoints = Array.isArray(data.series) ? data.series : [];
  byId('event-count').textContent = t('events', { value: formatFullTokens(data.summary.events) });
  byId('tokens-empty').hidden = tokenPoints.length > 0;
  byId('tokens-chart-wrap').hidden = tokenPoints.length === 0;
  tokenDatasets = [
    { label: t('input'), data: tokenPoints.map(point => ({ x: Date.parse(point.at), y: safeNumber(point.input_tokens) })), backgroundColor: '#3b82f6', stack: 'tokens' },
    { label: t('cacheReadWrite'), data: tokenPoints.map(point => ({ x: Date.parse(point.at), y: safeNumber(point.cache_read_tokens) + safeNumber(point.cache_write_tokens) })), backgroundColor: '#a78bfa', stack: 'tokens' },
    { label: t('output'), data: tokenPoints.map(point => ({ x: Date.parse(point.at), y: safeNumber(point.output_tokens) })), backgroundColor: '#22c55e', stack: 'tokens' },
  ];
  if (tokensChart) { tokensChart.data.datasets = tokenDatasets; tokensChart.update('none'); updateTokenOverlay(); return; }
  if (typeof Chart !== 'function') throw new Error('Chart.js failed to load');
  const options = chartBase();
  options.scales.y.stacked = true;
  options.scales.y.ticks.callback = formatTokens;
  tokensChart = new Chart(byId('tokens-chart').getContext('2d'), { type: 'bar', data: { datasets: tokenDatasets }, options });
  updateTokenOverlay();
}

function clearRows(body) { while (body.firstChild) body.removeChild(body.firstChild); }
function cell(row, text, className = '') { const value = document.createElement('td'); value.textContent = text; if (className) value.className = className; row.appendChild(value); return value; }

function renderBreakdown(items) {
  const body = byId('breakdown-body');
  clearRows(body);
  byId('breakdown-empty').hidden = items.length > 0;
  for (const item of items) {
    const row = document.createElement('tr');
    cell(row, item.source, 'source-pill');
    cell(row, `${item.provider || 'unknown'} / ${item.model}`);
    cell(row, formatTokens(item.input_tokens));
    cell(row, formatTokens(safeNumber(item.cache_read_tokens) + safeNumber(item.cache_write_tokens)));
    cell(row, formatTokens(item.output_tokens));
    const cost = cell(row, '', item.pricing_status === 'assumed-zero' ? 'pricing-unknown' : '');
    setCost(cost, item.estimated_cost_usd);
    if (item.pricing_status === 'assumed-zero') cost.title = t('pricingUnknownTitle');
    body.appendChild(row);
  }
}

function renderResets(data) {
  const body = byId('resets-body');
  clearRows(body);
  byId('resets-empty').hidden = data.items.length > 0;
  for (const item of data.items) {
    const row = document.createElement('tr');
    cell(row, item.window, 'source-pill');
    cell(row, item.category === 'random' ? t('random') : item.category === 'end_of_week' ? t('endOfWeek') : t('scheduled'), 'source-pill');
    cell(row, formatDate(item.reset_at));
    cell(row, formatDate(item.observed_at));
    cell(row, `${item.before_pct ?? '—'}% → ${item.after_pct ?? '—'}%`);
    const impact = item.category === 'random'
      ? `${formatSignedPoints(item.pace_delta_pct_points)} ${t('vsIdealPace')}`
      : item.category === 'end_of_week' && item.unused_pct_points > 0
        ? t('unusedExpired', { value: item.unused_pct_points })
        : '—';
    cell(row, impact);
    cell(row, formatDuration(item.observation_delay_seconds));
    body.appendChild(row);
  }
  const pagination = byId('reset-pagination');
  pagination.hidden = data.total <= RESET_PAGE_SIZE;
  byId('resets-previous').disabled = data.offset === 0;
  byId('resets-next').disabled = data.offset + data.limit >= data.total;
  const first = data.total ? data.offset + 1 : 0;
  byId('reset-page-label').textContent = t('pageOf', {
    from: first,
    to: Math.min(data.offset + data.limit, data.total),
    total: data.total,
  });
}

function renderCollectors(freshness, baselines) {
  const grid = byId('collector-grid');
  clearRows(grid);
  for (const source of ['codex', 'opencode', 'hermes']) {
    const collector = freshness.collectors[source] || { status: 'unavailable', last_success_at: null };
    const item = document.createElement('div');
    item.className = 'collector-item';
    const heading = document.createElement('div'); heading.className = 'collector-name';
    const name = document.createElement('span'); name.textContent = source;
    const status = document.createElement('span'); status.className = `status-pill status-${collector.status}`; status.textContent = collector.status;
    heading.append(name, status);
    const detail = document.createElement('p'); detail.className = 'collector-detail';
    detail.textContent = collector.last_success_at
      ? t('lastSuccess', { value: formatDate(collector.last_success_at) })
      : t('noSuccessfulCollection');
    item.append(heading, detail); grid.appendChild(item);
  }
  const baselineTokens = (baselines.hermes || []).reduce((total, item) => total + safeNumber(item.tokens), 0);
  const note = byId('baseline-note');
  note.hidden = baselineTokens === 0;
  note.textContent = baselineTokens
    ? t('hermesBaseline', { value: formatFullTokens(baselineTokens) })
    : '';
}

function checkedValues(container) {
  return [...container.querySelectorAll('input[type="checkbox"]:checked')].map(input => input.value);
}

function setCheckedValues(container, values) {
  const selected = new Set(values);
  for (const input of container.querySelectorAll('input[type="checkbox"]')) input.checked = selected.has(input.value);
}

function addFilterOption(container, value) {
  const label = document.createElement('label');
  label.className = 'filter-option';
  const input = document.createElement('input');
  input.type = 'checkbox';
  input.value = value;
  input.checked = state.models.includes(value);
  label.append(input, ` ${value}`);
  container.appendChild(label);
}

function updateModelOptions(models) {
  const normalized = Array.isArray(models) ? models.filter(model => typeof model === 'string') : [];
  const container = byId('model-filter');
  const availableChanged = normalized.join('\0') !== state.availableModels.join('\0');
  state.availableModels = normalized;
  if (availableChanged) {
    state.models = state.models.filter(model => normalized.includes(model));
    if (!state.models.length) state.models = [...normalized];
    clearRows(container);
    for (const model of normalized) addFilterOption(container, model);
  } else {
    setCheckedValues(container, state.models);
  }
}

function render(payload) {
  lastPayload = payload;
  const summary = payload.tokens.summary;
  byId('total-tokens').textContent = formatTokens(totalBillable(summary));
  byId('total-tokens').title = t('billableTokensTitle', { value: formatFullTokens(totalBillable(summary)) });
  byId('token-detail').textContent = `${formatTokens(summary.input_tokens)} ${t('input').toLowerCase()} · ${formatTokens(summary.cache_read_tokens + summary.cache_write_tokens)} ${t('cache').toLowerCase()} · ${formatTokens(summary.output_tokens)} ${t('output').toLowerCase()}`;
  setCost(byId('estimated-cost'), summary.estimated_cost_usd);
  setCost(byId('allocation-total-cost'), summary.estimated_cost_usd);
  const currency = typeof CodexPreferences === 'object' ? CodexPreferences.get().currency : 'USD';
  byId('pricing-note').textContent = currency === 'EUR'
    ? t('catalogConverted', { date: payload.pricing.as_of, rate: CodexPreferences.formatRate() })
    : t('catalog', { date: payload.pricing.as_of, currency: payload.pricing.currency });
  const weeklySummary = payload.resets.weekly_summary || { random: {}, end_of_week: {} };
  const random = weeklySummary.random || {};
  const endOfWeek = weeklySummary.end_of_week || {};
  byId('random-reset-count').textContent = formatFullTokens(random.count);
  byId('random-reset-impact').textContent = `${t('gain')} ${formatSignedPoints(random.gained_vs_ideal_pct_points)} · ${t('loss')} ${formatPoints(random.lost_vs_ideal_pct_points)} ${t('vsIdealPace')}`;
  byId('end-week-reset-count').textContent = formatFullTokens(endOfWeek.count);
  byId('end-week-reset-impact').textContent = t('ofUnusedQuotaExpired', { value: formatPercent(endOfWeek.unused_pct_points) });
  byId('period-label').textContent = `${formatShortDate(payload.period.from)} – ${formatShortDate(payload.period.to)}`;
  byId('granularity-label').textContent = t('bucketsOf', { value: formatDuration(payload.period.granularity_seconds) });
  renderLimits(payload.limits);
  renderTokens(payload.tokens);
  renderBreakdown(payload.tokens.breakdown);
  renderResets(payload.resets);
  renderCollectors(payload.freshness, payload.baselines);
  updateModelOptions(payload.available.models);
  setMessage('analytics-warnings', payload.warnings);
  setMessage('analytics-error', '');
}

async function refresh() {
  clearTimeout(refreshTimer);
  try {
    const response = await fetch(`/api/analytics?${queryString()}`, { headers: { Accept: 'application/json' } });
    const payload = await response.json();
    if (!response.ok) throw new Error(payload.error || `HTTP ${response.status}`);
    render(payload);
  } catch (error) {
    setMessage('analytics-error', error instanceof Error ? error.message : t('unableToLoadAnalytics'));
  } finally {
    refreshTimer = setTimeout(refresh, ANALYTICS_REFRESH_MS);
  }
}

for (const button of document.querySelectorAll('[data-range]')) {
  button.addEventListener('click', () => {
    document.querySelectorAll('[data-range]').forEach(item => item.classList.toggle('active', item === button));
    state.range = button.dataset.range;
    state.resetOffset = 0;
    byId('custom-dates').hidden = state.range !== 'custom';
    if (state.range !== 'custom') refresh();
  });
}
byId('source-filter').addEventListener('change', event => {
  const source = event.target.value;
  state.sources = checkedValues(byId('source-filter'));
  if (!state.sources.length) { event.target.checked = true; state.sources = [source]; }
  state.resetOffset = 0;
  refresh();
});
byId('model-filter').addEventListener('change', event => {
  const model = event.target.value;
  state.models = checkedValues(byId('model-filter'));
  if (!state.models.length) { event.target.checked = true; state.models = [model]; }
  state.resetOffset = 0;
  refresh();
});
byId('select-all-models').addEventListener('click', () => {
  state.models = [...state.availableModels];
  setCheckedValues(byId('model-filter'), state.models);
  state.resetOffset = 0;
  refresh();
});
byId('select-gpt-5-6').addEventListener('click', () => {
  const gpt56 = state.availableModels.filter(model => ['gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna'].includes(model));
  if (!gpt56.length) { setMessage('analytics-error', t('gptModelsUnavailable')); return; }
  state.models = gpt56;
  setCheckedValues(byId('model-filter'), state.models);
  state.resetOffset = 0;
  refresh();
});
byId('reset-filter').addEventListener('change', event => { state.resetType = event.target.value; state.resetOffset = 0; refresh(); });
byId('apply-dates').addEventListener('click', () => {
  state.fromDate = byId('from-date').value; state.toDate = byId('to-date').value; state.resetOffset = 0;
  if (!state.fromDate || !state.toDate) { setMessage('analytics-error', t('chooseBothDates')); return; }
  refresh();
});
byId('resets-previous').addEventListener('click', () => { state.resetOffset = Math.max(0, state.resetOffset - RESET_PAGE_SIZE); refresh(); });
byId('resets-next').addEventListener('click', () => { state.resetOffset += RESET_PAGE_SIZE; refresh(); });
byId('toggle-token-overlay').addEventListener('click', () => {
  if (!limitPoints.length || !tokenPoints.length) return;
  state.tokenOverlay = !state.tokenOverlay;
  updateTokenOverlay();
});

function refreshLocalizedAnalytics() {
  if (!lastPayload) return;
  try {
    render(lastPayload);
  } catch (error) {
    setMessage('analytics-error', error instanceof Error ? error.message : t('unableToLoadAnalytics'));
  }
}

if (typeof CodexPreferences === 'object') CodexPreferences.subscribe(refreshLocalizedAnalytics);
refresh();
