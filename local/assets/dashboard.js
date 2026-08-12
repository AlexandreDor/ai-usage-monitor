'use strict';

// Set a Gist ID to use the GitHub API instead of local JSON files.
const GIST_ID = '';
const REFRESH_INTERVAL_MS = 900_000;
const DECIMATION_THRESHOLD = 1000;
const DECIMATION_SAMPLES = 600;
const PARIS_TIME_ZONE = 'Europe/Paris';

let chart = null;
let refreshTimer = null;
let dashboardData = null;
let dashboardHistory = null;
let historyFailure = null;
let mainFailure = null;
let dashboardMode = null;

function t(key, values = {}) {
  return typeof CodexPreferences === 'object' ? CodexPreferences.t(`dashboard.${key}`, values) : key;
}

function currentLocale() {
  return typeof CodexPreferences === 'object' ? CodexPreferences.locale() : 'en-GB';
}

function validPct(value) {
  if (value === null || value === undefined || value === '') return null;
  const pct = Number(value);
  return Number.isFinite(pct) && pct >= 0 && pct <= 100 ? pct : null;
}

function displayText(value, fallback = '-', maxLength = 200) {
  return typeof value === 'string' && value.length <= maxLength ? value : fallback;
}

function scheduleRefresh(data = null) {
  const intervalSeconds = Number(data?.sample_interval_seconds);
  const intervalMs = Number.isFinite(intervalSeconds) && intervalSeconds > 0
    ? intervalSeconds * 1000
    : REFRESH_INTERVAL_MS;
  const now = Date.now();
  const nextUpdate = (Math.floor((now - 5_000) / intervalMs) + 1) * intervalMs + 5_000;
  clearTimeout(refreshTimer);
  refreshTimer = setTimeout(refresh, nextUpdate - now);
}

function formatParisDateTime(value, includeYear = true) {
  const timestamp = typeof value === 'number' ? value : Date.parse(value);
  if (!Number.isFinite(timestamp)) return '-';

  const formatter = new Intl.DateTimeFormat(currentLocale(), {
    timeZone: PARIS_TIME_ZONE,
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  });
  const parts = Object.fromEntries(
    formatter
      .formatToParts(new Date(timestamp))
      .filter(part => part.type !== 'literal')
      .map(part => [part.type, part.value]),
  );
  const date = includeYear ? `${parts.day}/${parts.month}/${parts.year}` : `${parts.day}/${parts.month}`;
  return `${date} ${parts.hour}:${parts.minute}`;
}

function formatParisUnixTimestamp(value) {
  const timestamp = Number(value);
  return Number.isFinite(timestamp) && timestamp > 0
    ? formatParisDateTime(timestamp * 1000)
    : '-';
}

function idealWeeklyRemaining(sampledAt, resetTimestamp) {
  const sampledAtMs = typeof sampledAt === 'number' ? sampledAt : Date.parse(displayText(sampledAt, ''));
  const resetAtMs = Number(resetTimestamp) * 1000;
  const weeklyWindowMs = 7 * 24 * 60 * 60 * 1000;
  const cycleStartMs = resetAtMs - weeklyWindowMs;
  if (!Number.isFinite(sampledAtMs) || !Number.isFinite(resetAtMs)) return null;
  if (sampledAtMs < cycleStartMs || sampledAtMs > resetAtMs) return null;
  return Math.round((100 * (resetAtMs - sampledAtMs) / weeklyWindowMs) * 10) / 10;
}

function renderWeeklyPaceDelta(data) {
  const element = document.getElementById('weekly-pace-delta');
  const actual = validPct(data.weekly_pct);
  const ideal = idealWeeklyRemaining(data.scraped_at, data.weekly_reset_at);
  element.classList.remove('ahead', 'behind');

  if (actual === null || ideal === null) {
    element.textContent = '--';
    element.title = t('weeklyPaceUnavailable');
    return;
  }

  const rawDifference = actual - ideal;
  const pointDifference = Math.round(rawDifference * 10) / 10;
  const relativeDifference = ideal > 0
    ? Math.round((Math.abs(rawDifference) / ideal) * 1000) / 10
    : null;
  const direction = pointDifference === 0 ? t('onPace') : pointDifference > 0 ? t('above') : t('below');
  const sign = pointDifference > 0 ? '+' : '';
  const relativeLabel = relativeDifference === null ? '' : ` / ${relativeDifference.toFixed(1)}% ${direction}`;

  element.textContent = `${sign}${pointDifference.toFixed(1)} ${t('points')}${relativeLabel}`;
  element.title = `${t('actualRemaining')}: ${actual.toFixed(1)}% / ${t('idealRemaining')}: ${ideal.toFixed(1)}%`;
  element.classList.add(pointDifference >= 0 ? 'ahead' : 'behind');
}

function setBar(barId, pctId, pct) {
  const safePct = validPct(pct);
  const bar = document.getElementById(barId);
  const value = document.getElementById(pctId);
  bar.value = safePct ?? 0;
  value.textContent = safePct === null ? '--' : `${safePct}%`;
  value.classList.toggle('unavailable', safePct === null);
}

function renderForecast(data) {
  const strip = document.getElementById('forecast-strip');
  const status = document.getElementById('forecast-status');
  const forecast = data?.codex_forecast;
  const chance24h = validPct(forecast?.chance_24h_pct);
  const chance6h = validPct(forecast?.chance_6h_pct);
  const generatedAt = Date.parse(displayText(forecast?.generated_at, ''));
  const intervalSeconds = Number(data?.sample_interval_seconds);
  const staleAfterMs = Math.max(
    30 * 60 * 1000,
    (Number.isFinite(intervalSeconds) && intervalSeconds > 0 ? intervalSeconds * 2 : 0) * 1000,
  );
  const ageMs = Date.now() - generatedAt;
  const available = chance24h !== null
    && chance6h !== null
    && Number.isFinite(generatedAt)
    && ageMs <= staleAfterMs;

  document.getElementById('forecast-24h').textContent = available ? `${chance24h}%` : '--';
  document.getElementById('forecast-6h').textContent = available ? `${chance6h}%` : '--';
  strip.classList.toggle('unavailable', !available);
  status.textContent = available
    ? t('forecastUpdated', { value: formatParisDateTime(generatedAt) })
    : t('forecastUnavailable');
}

function setMainError(message = '') {
  const element = document.getElementById('error-banner');
  mainFailure = message || null;
  element.textContent = message ? `${t('warningPrefix')}: ${displayText(message, t('warningFallback'))}` : '';
  element.hidden = !message;
}

function setHistoryError(message = '') {
  const element = document.getElementById('history-error');
  element.textContent = message ? `${t('chartPrefix')}: ${displayText(message, t('chartFallback'))}` : '';
  element.hidden = !message;
}

function destroyChart(title = t('historyUnavailable')) {
  if (chart) {
    chart.destroy();
    chart = null;
  }
  document.getElementById('history-label').textContent = title;
}

function normalizeHistory(history) {
  if (!Array.isArray(history)) throw new Error(t('invalidHistory'));
  if (history.length === 0) throw new Error(t('historyEmpty'));

  const byTimestamp = new Map();
  for (const item of history) {
    if (!item || typeof item !== 'object' || Array.isArray(item)) continue;
    const timestamp = Date.parse(displayText(item.scraped_at, ''));
    const fiveHour = validPct(item.five_h_pct);
    const weekly = validPct(item.weekly_pct);
    if (!Number.isFinite(timestamp) || (fiveHour === null && weekly === null)) continue;
    const weeklyReset = Number(item.weekly_reset_at);
    byTimestamp.set(timestamp, {
      timestamp,
      fiveHour,
      weekly,
      weeklyReset: Number.isFinite(weeklyReset) && weeklyReset > 0 ? weeklyReset : null,
    });
  }

  const points = [...byTimestamp.values()].sort((a, b) => a.timestamp - b.timestamp);
  if (points.length === 0) throw new Error(t('historyNoValidSamples'));
  return points;
}

function historyTitle(points) {
  const start = formatParisDateTime(points[0].timestamp, false);
  const end = formatParisDateTime(points[points.length - 1].timestamp, false);
  return points.length === 1
    ? t('historyTitleSingle', { start })
    : t('historyTitleRange', { start, end });
}

function chartDatasets(points) {
  return [
    {
      label: t('fiveHourDataset'),
      data: points.map(point => ({ x: point.timestamp, y: point.fiveHour })),
      borderColor: '#22c55e',
      backgroundColor: 'rgba(34,197,94,0.1)',
      borderWidth: 2,
      pointRadius: points.length > 200 ? 0 : 2,
      tension: 0.3,
      fill: true,
      spanGaps: false,
    },
    {
      label: t('weeklyDataset'),
      data: points.map(point => ({ x: point.timestamp, y: point.weekly })),
      borderColor: '#4ade80',
      backgroundColor: 'rgba(74,222,128,0.08)',
      borderWidth: 2,
      pointRadius: points.length > 200 ? 0 : 2,
      tension: 0.3,
      fill: true,
      spanGaps: false,
    },
    {
      label: t('idealDataset'),
      data: points.map(point => ({
        x: point.timestamp,
        y: idealWeeklyRemaining(point.timestamp, point.weeklyReset),
      })),
      borderColor: '#a7f3d0',
      backgroundColor: 'transparent',
      borderWidth: 2,
      borderDash: [8, 6],
      pointRadius: 0,
      tension: 0,
      fill: false,
      spanGaps: false,
    },
  ];
}

function formatChartTimestamp(value) {
  return formatParisDateTime(value, false);
}

function chartTimeBounds(points) {
  const min = points[0].timestamp;
  const max = points[points.length - 1].timestamp;
  return min < max ? { min, max } : null;
}

function renderHistory(history) {
  const points = normalizeHistory(history);
  dashboardHistory = history;
  historyFailure = null;
  const datasets = chartDatasets(points);
  const timeBounds = chartTimeBounds(points);
  document.getElementById('history-label').textContent = historyTitle(points);

  if (chart) {
    const xScale = chart.options.scales.x;
    if (timeBounds) {
      xScale.min = timeBounds.min;
      xScale.max = timeBounds.max;
    } else {
      delete xScale.min;
      delete xScale.max;
    }
    chart.data.datasets = datasets;
    chart.update('none');
    setHistoryError();
    return;
  }

  if (typeof Chart !== 'function') throw new Error(t('chartFailed'));
  const context = document.getElementById('history-chart').getContext('2d');
  chart = new Chart(context, {
    type: 'line',
    data: { datasets },
    options: {
      responsive: true,
      maintainAspectRatio: true,
      parsing: false,
      normalized: true,
      animation: false,
      scales: {
        y: {
          min: 0,
          max: 100,
          grid: { color: 'rgba(255,255,255,0.05)' },
          ticks: { color: '#8b949e', callback: value => `${value}%` },
        },
        x: {
          type: 'linear',
          ...(timeBounds || {}),
          grid: { color: 'rgba(255,255,255,0.05)' },
          ticks: { color: '#8b949e', maxTicksLimit: 12, callback: formatChartTimestamp },
        },
      },
      plugins: {
        decimation: {
          enabled: true,
          algorithm: 'lttb',
          samples: DECIMATION_SAMPLES,
          threshold: DECIMATION_THRESHOLD,
        },
        legend: { labels: { color: '#e6edf3', boxWidth: 12 } },
        tooltip: { callbacks: { title: items => items.length ? formatParisDateTime(items[0].parsed.x) : '' } },
      },
    },
  });
  setHistoryError();
}

function renderHistoryFailure(message) {
  historyFailure = message;
  dashboardHistory = null;
  destroyChart();
  setHistoryError(message);
}

function renderData(data, { schedule = true } = {}) {
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    throw new Error(t('invalidDashboardData'));
  }
  dashboardData = data;
  setBar('five-h-bar', 'five-h-pct', data.five_h_pct);
  setBar('weekly-bar', 'weekly-pct', data.weekly_pct);
  renderForecast(data);
  document.getElementById('five-h-reset').textContent = formatParisUnixTimestamp(data.five_h_reset_at);
  document.getElementById('weekly-reset').textContent = formatParisUnixTimestamp(data.weekly_reset_at);
  renderWeeklyPaceDelta(data);
  document.getElementById('last-updated').textContent = t('lastScraped', {
    value: formatParisDateTime(displayText(data.scraped_at, '')),
  });
  setMainError();
  if (schedule) scheduleRefresh(data);
}

async function fetchJson(url, missingMessage) {
  const response = await fetch(`${url}?_=${Date.now()}`);
  if (!response.ok) throw new Error(response.status === 404 ? missingMessage : `HTTP ${response.status}`);
  return response.json();
}

async function fetchLocal() {
  dashboardMode = 'local';
  document.getElementById('mode-badge').textContent = t(dashboardMode);
  const data = await fetchJson('data.json', t('dataNotFound'));
  renderData(data);

  try {
    renderHistory(await fetchJson('history.json', t('historyNotFound')));
  } catch (error) {
    renderHistoryFailure(error instanceof Error ? error.message : t('unableToLoadHistory'));
  }
}

async function fetchGist() {
  dashboardMode = 'external';
  document.getElementById('mode-badge').textContent = t(dashboardMode);
  const response = await fetch(`https://api.github.com/gists/${encodeURIComponent(GIST_ID)}?_=${Date.now()}`);
  if (!response.ok) throw new Error(t('githubApiError', { status: response.status }));
  const gist = await response.json();
  const dataContent = gist?.files?.['data.json']?.content;
  if (!dataContent) throw new Error(t('gistDataNotFound'));
  renderData(JSON.parse(dataContent));

  try {
    const historyContent = gist?.files?.['history.json']?.content;
    if (!historyContent) throw new Error(t('gistHistoryNotFound'));
    renderHistory(JSON.parse(historyContent));
  } catch (error) {
    renderHistoryFailure(error instanceof Error ? error.message : t('unableToLoadHistory'));
  }
}

async function refresh() {
  try {
    await (GIST_ID ? fetchGist() : fetchLocal());
  } catch (error) {
    setMainError(error instanceof Error ? error.message : t('unableToLoadData'));
    dashboardMode = 'error';
    document.getElementById('mode-badge').textContent = t(dashboardMode);
    scheduleRefresh();
  }
}

function refreshLocalizedDashboard() {
  if (dashboardMode) document.getElementById('mode-badge').textContent = t(dashboardMode);
  if (dashboardData) renderData(dashboardData, { schedule: false });
  else if (mainFailure) setMainError(mainFailure);
  if (dashboardHistory) {
    try {
      renderHistory(dashboardHistory);
    } catch (error) {
      renderHistoryFailure(error instanceof Error ? error.message : t('unableToLoadHistory'));
    }
  } else if (historyFailure) {
    setHistoryError(historyFailure);
  }
}

if (typeof CodexPreferences === 'object') CodexPreferences.subscribe(refreshLocalizedDashboard);
refresh();
