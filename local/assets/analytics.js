'use strict';

const ANALYTICS_REFRESH_MS = 900_000;
const RESET_PAGE_SIZE = 10;
const PARIS_ZONE = 'Europe/Paris';
const state = { range: '30d', source: 'all', model: '', resetType: 'all', resetOffset: 0, fromDate: '', toDate: '' };
let limitsChart = null;
let tokensChart = null;
let refreshTimer = null;

const dateTime = new Intl.DateTimeFormat('en-GB', {
  timeZone: PARIS_ZONE, day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
});
const shortDate = new Intl.DateTimeFormat('en-GB', { timeZone: PARIS_ZONE, day: '2-digit', month: 'short', year: 'numeric' });
const compactNumber = new Intl.NumberFormat('en', { notation: 'compact', maximumFractionDigits: 2 });
const preciseNumber = new Intl.NumberFormat('en');

function byId(id) { return document.getElementById(id); }
function safeNumber(value) { const number = Number(value); return Number.isFinite(number) && number >= 0 ? number : 0; }
function formatTokens(value) { return compactNumber.format(safeNumber(value)); }
function formatFullTokens(value) { return preciseNumber.format(safeNumber(value)); }
function formatDate(value) { const date = new Date(value); return Number.isFinite(date.getTime()) ? dateTime.format(date) : '—'; }
function formatCost(value) { return `$${safeNumber(value).toFixed(safeNumber(value) < 1 ? 4 : 2)}`; }
function totalBillable(summary) { return safeNumber(summary.input_tokens) + safeNumber(summary.cache_read_tokens) + safeNumber(summary.cache_write_tokens) + safeNumber(summary.output_tokens); }
function formatDuration(seconds) {
  const value = safeNumber(seconds);
  if (value < 60) return `${value}s`;
  if (value < 3600) return `${Math.round(value / 60)}m`;
  return `${Math.round(value / 360) / 10}h`;
}

function setMessage(id, messages) {
  const element = byId(id);
  const values = Array.isArray(messages) ? messages : messages ? [messages] : [];
  element.textContent = values.join(' · ');
  element.hidden = values.length === 0;
}

function queryString() {
  const query = new URLSearchParams({ source: state.source, reset_type: state.resetType, reset_offset: String(state.resetOffset), reset_limit: String(RESET_PAGE_SIZE) });
  if (state.model) query.set('model', state.model);
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
      x: { type: 'linear', grid: { color: 'rgba(255,255,255,.05)' }, ticks: { color: '#86a2c5', maxTicksLimit: 8, callback: value => shortDate.format(new Date(value)) } },
      y: { beginAtZero: true, grid: { color: 'rgba(255,255,255,.05)' }, ticks: { color: '#86a2c5' } },
    },
    plugins: { legend: { labels: { color: '#edf5ff', boxWidth: 12 } }, tooltip: { callbacks: { title: items => items.length ? formatDate(items[0].parsed.x) : '' } } },
  };
}

function renderLimits(data) {
  const points = Array.isArray(data.series) ? data.series : [];
  byId('limit-samples').textContent = `${formatFullTokens(data.samples)} samples`;
  byId('limits-empty').hidden = points.length > 0;
  byId('limits-chart-wrap').hidden = points.length === 0;
  const datasets = [
    { label: '5-hour remaining', data: points.map(point => ({ x: Date.parse(point.at), y: point.five_h_pct })), borderColor: '#22c55e', backgroundColor: 'rgba(34,197,94,.10)', fill: true, borderWidth: 2, pointRadius: 0, tension: .25, spanGaps: false },
    { label: 'Weekly remaining', data: points.map(point => ({ x: Date.parse(point.at), y: point.weekly_pct })), borderColor: '#38bdf8', backgroundColor: 'rgba(56,189,248,.07)', fill: true, borderWidth: 2, pointRadius: 0, tension: .25, spanGaps: false },
  ];
  if (limitsChart) { limitsChart.data.datasets = datasets; limitsChart.update('none'); return; }
  if (typeof Chart !== 'function') throw new Error('Chart.js failed to load');
  const options = chartBase();
  options.scales.y.max = 100;
  options.scales.y.ticks.callback = value => `${value}%`;
  limitsChart = new Chart(byId('limits-chart').getContext('2d'), { type: 'line', data: { datasets }, options });
}

function renderTokens(data) {
  const points = Array.isArray(data.series) ? data.series : [];
  byId('event-count').textContent = `${formatFullTokens(data.summary.events)} events`;
  byId('tokens-empty').hidden = points.length > 0;
  byId('tokens-chart-wrap').hidden = points.length === 0;
  const datasets = [
    { label: 'Input', data: points.map(point => ({ x: Date.parse(point.at), y: safeNumber(point.input_tokens) })), backgroundColor: '#3b82f6', stack: 'tokens' },
    { label: 'Cache read/write', data: points.map(point => ({ x: Date.parse(point.at), y: safeNumber(point.cache_read_tokens) + safeNumber(point.cache_write_tokens) })), backgroundColor: '#a78bfa', stack: 'tokens' },
    { label: 'Output', data: points.map(point => ({ x: Date.parse(point.at), y: safeNumber(point.output_tokens) })), backgroundColor: '#22c55e', stack: 'tokens' },
  ];
  if (tokensChart) { tokensChart.data.datasets = datasets; tokensChart.update('none'); return; }
  if (typeof Chart !== 'function') throw new Error('Chart.js failed to load');
  const options = chartBase();
  options.scales.y.stacked = true;
  options.scales.y.ticks.callback = formatTokens;
  tokensChart = new Chart(byId('tokens-chart').getContext('2d'), { type: 'bar', data: { datasets }, options });
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
    const cost = cell(row, formatCost(item.estimated_cost_usd), item.pricing_status === 'assumed-zero' ? 'pricing-unknown' : '');
    if (item.pricing_status === 'assumed-zero') cost.title = 'Model absent from pricing catalog; assumed zero';
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
    cell(row, formatDate(item.reset_at));
    cell(row, formatDate(item.observed_at));
    cell(row, `${item.before_pct ?? '—'}% → ${item.after_pct ?? '—'}%`);
    cell(row, formatDuration(item.observation_delay_seconds));
    body.appendChild(row);
  }
  const pagination = byId('reset-pagination');
  pagination.hidden = data.total <= RESET_PAGE_SIZE;
  byId('resets-previous').disabled = data.offset === 0;
  byId('resets-next').disabled = data.offset + data.limit >= data.total;
  const first = data.total ? data.offset + 1 : 0;
  byId('reset-page-label').textContent = `${first}–${Math.min(data.offset + data.limit, data.total)} of ${data.total}`;
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
    detail.textContent = collector.last_success_at ? `Last success ${formatDate(collector.last_success_at)}` : 'No successful collection yet';
    item.append(heading, detail); grid.appendChild(item);
  }
  const baselineTokens = (baselines.hermes || []).reduce((total, item) => total + safeNumber(item.tokens), 0);
  const note = byId('baseline-note');
  note.hidden = baselineTokens === 0;
  note.textContent = baselineTokens ? `Hermes pre-monitor baseline excluded from dated totals: ${formatFullTokens(baselineTokens)} tokens.` : '';
}

function updateModelOptions(models) {
  const select = byId('model-filter');
  const current = state.model;
  while (select.options.length > 1) select.remove(1);
  for (const model of models) { const option = document.createElement('option'); option.value = model; option.textContent = model; select.appendChild(option); }
  if (models.includes(current)) select.value = current;
  else { state.model = ''; select.value = ''; }
}

function render(payload) {
  const summary = payload.tokens.summary;
  byId('total-tokens').textContent = formatTokens(totalBillable(summary));
  byId('total-tokens').title = `${formatFullTokens(totalBillable(summary))} billable tokens`;
  byId('token-detail').textContent = `${formatTokens(summary.input_tokens)} input · ${formatTokens(summary.cache_read_tokens + summary.cache_write_tokens)} cache · ${formatTokens(summary.output_tokens)} output`;
  byId('estimated-cost').textContent = formatCost(summary.estimated_cost_usd);
  byId('allocation-total-cost').textContent = formatCost(summary.estimated_cost_usd);
  byId('pricing-note').textContent = `Catalog ${payload.pricing.as_of} · ${payload.pricing.currency}`;
  byId('reset-count').textContent = formatFullTokens(payload.resets.weekly_total);
  byId('period-label').textContent = `${shortDate.format(new Date(payload.period.from))} – ${shortDate.format(new Date(payload.period.to))}`;
  byId('granularity-label').textContent = `Buckets of ${formatDuration(payload.period.granularity_seconds)}`;
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
    setMessage('analytics-error', error instanceof Error ? error.message : 'Unable to load analytics');
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
byId('source-filter').addEventListener('change', event => { state.source = event.target.value; state.resetOffset = 0; refresh(); });
byId('model-filter').addEventListener('change', event => { state.model = event.target.value; state.resetOffset = 0; refresh(); });
byId('reset-filter').addEventListener('change', event => { state.resetType = event.target.value; state.resetOffset = 0; refresh(); });
byId('apply-dates').addEventListener('click', () => {
  state.fromDate = byId('from-date').value; state.toDate = byId('to-date').value; state.resetOffset = 0;
  if (!state.fromDate || !state.toDate) { setMessage('analytics-error', 'Choose both custom dates.'); return; }
  refresh();
});
byId('resets-previous').addEventListener('click', () => { state.resetOffset = Math.max(0, state.resetOffset - RESET_PAGE_SIZE); refresh(); });
byId('resets-next').addEventListener('click', () => { state.resetOffset += RESET_PAGE_SIZE; refresh(); });

refresh();
