'use strict';

// Set a Gist ID to use the GitHub API instead of local JSON files.
let GIST_ID = '';
const REFRESH_INTERVAL_MS = 900_000;
const DEFAULT_ACTIVE_REFRESH_INTERVAL_MS = 300_000;
const HEARTBEAT_INTERVAL_MS = 30_000;
const REFRESH_RETRY_INITIAL_MS = 5_000;
const MIN_SAMPLE_INTERVAL_SECONDS = 60;
const MAX_SAMPLE_INTERVAL_SECONDS = 86_400;
const DECIMATION_THRESHOLD = 1000;
const DECIMATION_SAMPLES = 600;
const PARIS_TIME_ZONE = 'Europe/Paris';
const SNAPSHOT_SCHEMA_VERSION = 1;

let chart = null;
let refreshTimer = null;
let freshnessTimer = null;
let heartbeatTimer = null;
let heartbeatInFlight = false;
let dashboardActiveIntervalMs = DEFAULT_ACTIVE_REFRESH_INTERVAL_MS;
let refreshRetryDelayMs = REFRESH_RETRY_INITIAL_MS;
let lastObservedScrapedAt = null;
let dashboardData = null;
let dashboardHistory = null;
let dashboardHistoryPoints = null;
let historyFailure = null;
let historyFailureKey = null;
let mainFailure = null;
let dashboardSource = null;
let refreshInFlight = null;

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

function validateSnapshotSchema(snapshot, history = false) {
  if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot)) {
    const error = history ? historyError('invalidHistory') : new Error(t('invalidDashboardData'));
    throw error;
  }
  const version = snapshot.schema_version;
  if (version === undefined) return snapshot; // implicit v0 compatibility
  if (!Number.isInteger(version) || version < 0) {
    const error = history ? historyError('invalidSnapshotSchema') : new Error(t('invalidSnapshotSchema'));
    throw error;
  }
  if (version > SNAPSHOT_SCHEMA_VERSION) {
    const error = history ? historyError('unsupportedSchema') : new Error(t('unsupportedSchema'));
    throw error;
  }
  return snapshot;
}

function displayText(value, fallback = '-', maxLength = 200) {
  return typeof value === 'string' && value.length <= maxLength ? value : fallback;
}

function setElementAttribute(element, name, value) {
  if (!element) return;
  if (typeof element.setAttribute === 'function') element.setAttribute(name, String(value));
  else element[name] = String(value);
}

function removeElementAttribute(element, name) {
  if (!element) return;
  if (typeof element.removeAttribute === 'function') element.removeAttribute(name);
  else delete element[name];
}

function formatPercent(value) {
  const pct = validPct(value);
  if (pct === null) return t('notAvailable');
  return `${new Intl.NumberFormat(currentLocale(), {
    maximumFractionDigits: 1,
  }).format(pct)}%`;
}

function normalizedSampleIntervalSeconds(rawValue) {
  const value = Number(rawValue);
  if (!Number.isInteger(value) || value < 1 || value > MAX_SAMPLE_INTERVAL_SECONDS) {
    return REFRESH_INTERVAL_MS / 1000;
  }
  return Math.max(MIN_SAMPLE_INTERVAL_SECONDS, value);
}

function classifySnapshotFreshness(data, now = Date.now()) {
  const scrapedAtMs = Date.parse(displayText(data?.scraped_at, ''));
  if (!Number.isFinite(scrapedAtMs)) throw new Error(t('invalidScrapedAt'));
  const intervalSeconds = normalizedSampleIntervalSeconds(data?.sample_interval_seconds);
  const staleAfterSeconds = Math.max(intervalSeconds * 2, intervalSeconds + 60);
  const ageSeconds = Math.floor(Math.max(0, Number(now) - scrapedAtMs) / 1000);
  const lateBySeconds = Math.max(0, ageSeconds - staleAfterSeconds);
  return {
    status: ageSeconds > staleAfterSeconds ? 'stale' : 'fresh',
    ageSeconds,
    staleAfterSeconds,
    lateBySeconds,
    scrapedAtMs,
    intervalSeconds,
  };
}

function formatElapsedDuration(seconds) {
  const value = Math.max(0, Math.floor(Number(seconds) || 0));
  if (value < 60) return t('lessThanMinute');
  const minutes = Math.floor(value / 60);
  if (minutes < 60) return t('durationMinutes', { minutes });
  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;
  if (hours < 24) {
    return remainingMinutes
      ? t('durationHoursMinutes', { hours, minutes: remainingMinutes })
      : t('durationHours', { hours });
  }
  const days = Math.floor(hours / 24);
  const remainingHours = hours % 24;
  return remainingHours
    ? t('durationDaysHours', { days, hours: remainingHours })
    : t('durationDays', { days });
}

function renderSource(source) {
  if (source !== 'local' && source !== 'external') return;
  dashboardSource = source;
  document.body.dataset.dashboardSource = source;
  const badge = document.getElementById('mode-badge');
  badge.hidden = source === 'local';
  badge.textContent = source === 'external' ? t(source) : '';
}

function stopFreshnessUpdate() {
  clearTimeout(freshnessTimer);
  freshnessTimer = null;
}

function scheduleFreshnessUpdate(classification = null) {
  stopFreshnessUpdate();
  if (!dashboardData || document.visibilityState !== 'visible') return;
  const state = classification || classifySnapshotFreshness(dashboardData);
  const now = Date.now();
  const ageMs = Math.max(0, now - state.scrapedAtMs);
  const nextMinuteDelay = 60_000 - (ageMs % 60_000);
  const staleDelay = state.status === 'fresh'
    ? state.scrapedAtMs + (state.staleAfterSeconds + 1) * 1000 - now
    : Number.POSITIVE_INFINITY;
  freshnessTimer = setTimeout(renderFreshness, Math.max(1, Math.min(nextMinuteDelay, staleDelay)));
}

function renderFreshness() {
  const badge = document.getElementById('freshness-badge');
  const detail = document.getElementById('freshness-detail');
  if (!dashboardData) {
    document.body.dataset.freshness = 'unavailable';
    badge.hidden = true;
    badge.textContent = '';
    detail.textContent = t('dataUnavailable');
    stopFreshnessUpdate();
    return;
  }
  const state = classifySnapshotFreshness(dashboardData);
  document.body.dataset.freshness = state.status;
  badge.hidden = false;
  badge.textContent = t(state.status);
  detail.textContent = state.status === 'stale'
    ? t('staleDataAge', {
      age: formatElapsedDuration(state.ageSeconds),
      overdue: formatElapsedDuration(state.lateBySeconds),
    })
    : t('dataAge', { age: formatElapsedDuration(state.ageSeconds) });
  scheduleFreshnessUpdate(state);
}

function isLocalDashboard() {
  return !GIST_ID;
}

function resetRefreshRetry() {
  refreshRetryDelayMs = REFRESH_RETRY_INITIAL_MS;
}

function consumeRefreshRetryDelay(maximumMs) {
  const delay = Math.min(refreshRetryDelayMs, maximumMs);
  refreshRetryDelayMs = Math.min(delay * 2, maximumMs);
  return delay;
}

function scheduleRefresh(data = null) {
  clearTimeout(refreshTimer);
  refreshTimer = null;
  if (document.visibilityState !== 'visible') return;

  const intervalSeconds = Number(data?.sample_interval_seconds);
  const snapshotIntervalMs = Number.isFinite(intervalSeconds) && intervalSeconds > 0
    ? intervalSeconds * 1000
    : REFRESH_INTERVAL_MS;
  const now = Date.now();
  const rawScrapedAt = displayText(data?.scraped_at, '');
  const scrapedAt = Date.parse(rawScrapedAt);

  if (!isLocalDashboard()) {
    const nextUpdate = (Math.floor((now - 5_000) / snapshotIntervalMs) + 1) * snapshotIntervalMs + 5_000;
    refreshTimer = setTimeout(refresh, Math.max(REFRESH_RETRY_INITIAL_MS, nextUpdate - now));
    return;
  }

  if (Number.isFinite(scrapedAt) && rawScrapedAt !== lastObservedScrapedAt) {
    lastObservedScrapedAt = rawScrapedAt;
    resetRefreshRetry();
  }

  const nextUpdate = Number.isFinite(scrapedAt)
    ? scrapedAt + dashboardActiveIntervalMs + REFRESH_RETRY_INITIAL_MS
    : Number.NaN;
  if (Number.isFinite(nextUpdate) && nextUpdate > now) {
    resetRefreshRetry();
    refreshTimer = setTimeout(refresh, nextUpdate - now);
    return;
  }

  refreshTimer = setTimeout(
    refresh,
    consumeRefreshRetryDelay(dashboardActiveIntervalMs),
  );
}

function applyDashboardActiveInterval(rawValue) {
  const intervalSeconds = Number(rawValue);
  if (!Number.isInteger(intervalSeconds) || intervalSeconds < 30 || intervalSeconds > 86_400) return;
  const intervalMs = intervalSeconds * 1000;
  if (intervalMs === dashboardActiveIntervalMs) return;
  dashboardActiveIntervalMs = intervalMs;
  refreshRetryDelayMs = Math.min(refreshRetryDelayMs, dashboardActiveIntervalMs);
  if (isLocalDashboard() && document.visibilityState === 'visible') {
    scheduleRefresh(mainFailure ? null : dashboardData);
  }
}

async function sendDashboardHeartbeat() {
  if (!isLocalDashboard() || document.visibilityState !== 'visible' || heartbeatInFlight) return;
  heartbeatInFlight = true;
  try {
    const response = await fetch('api/dashboard-heartbeat', {
      method: 'POST',
      headers: { 'X-Codex-Dashboard-Activity': 'visible' },
      cache: 'no-store',
      credentials: 'same-origin',
    });
    applyDashboardActiveInterval(response.headers?.get('X-Codex-Dashboard-Interval-Seconds'));
  } catch (_error) {
    // Activity signaling is advisory and must never hide otherwise valid data.
  } finally {
    heartbeatInFlight = false;
  }
}

function stopDashboardHeartbeat() {
  clearInterval(heartbeatTimer);
  heartbeatTimer = null;
}

function startDashboardHeartbeat() {
  if (!isLocalDashboard() || document.visibilityState !== 'visible') return;
  stopDashboardHeartbeat();
  void sendDashboardHeartbeat();
  heartbeatTimer = setInterval(sendDashboardHeartbeat, HEARTBEAT_INTERVAL_MS);
}

function handleDashboardVisibility() {
  if (document.visibilityState === 'visible') {
    startDashboardHeartbeat();
    renderFreshness();
    void refresh();
  } else {
    stopDashboardHeartbeat();
    stopFreshnessUpdate();
    clearTimeout(refreshTimer);
  }
}

function handleDashboardPageHide() {
  stopDashboardHeartbeat();
  stopFreshnessUpdate();
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
    element.textContent = t('weeklyPaceUnavailable');
    element.title = '';
    return;
  }

  const rawDifference = actual - ideal;
  const pointDifference = Math.round(rawDifference * 10) / 10;
  const relativeDifference = ideal > 0
    ? Math.round((Math.abs(rawDifference) / ideal) * 1000) / 10
    : null;
  const direction = pointDifference === 0 ? t('onPace') : pointDifference > 0 ? t('above') : t('below');
  const sign = pointDifference > 0 ? '+' : '';
  element.textContent = relativeDifference === null
    ? t('paceDeltaPoints', { sign, value: pointDifference.toFixed(1), direction })
    : t('paceDelta', {
      sign,
      value: pointDifference.toFixed(1),
      relative: relativeDifference.toFixed(1),
      direction,
    });
  element.title = '';
  element.classList.add(pointDifference >= 0 ? 'ahead' : 'behind');
}

function setBar(barId, pctId, pct, labelKey = null, unavailableValue = t('notAvailable')) {
  const safePct = validPct(pct);
  const bar = document.getElementById(barId);
  const value = document.getElementById(pctId);
  const accessibleLabelKey = labelKey || (barId === 'five-h-bar' ? 'fiveHourQuotaLabel' : 'weeklyQuotaLabel');
  if (safePct === null) {
    removeElementAttribute(bar, 'value');
  } else {
    setElementAttribute(bar, 'value', safePct);
    bar.value = safePct;
  }
  setElementAttribute(bar, 'aria-label', t(accessibleLabelKey));
  setElementAttribute(bar, 'aria-valuetext', safePct === null
    ? t('quotaUnavailable')
    : t('quotaRemaining', { value: formatPercent(safePct) }));
  if (safePct === null) removeElementAttribute(bar, 'aria-valuenow');
  else setElementAttribute(bar, 'aria-valuenow', safePct);
  value.textContent = safePct === null ? unavailableValue : formatPercent(safePct);
  bar.classList.toggle('unavailable', barId === 'five-h-bar' && safePct === null);
  value.classList.toggle('unavailable', safePct === null);
}

function renderForecast(data) {
  const strip = document.getElementById('forecast-strip');
  const status = document.getElementById('forecast-status');
  const forecast = data?.codex_forecast;
  const chance24h = validPct(forecast?.chance_24h_pct);
  const chance6h = validPct(forecast?.chance_6h_pct);
  const threshold24h = validPct(forecast?.highlight_threshold_24h_pct) ?? 50;
  const threshold6h = validPct(forecast?.highlight_threshold_6h_pct) ?? 25;
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
    && ageMs >= -5 * 60 * 1000
    && ageMs <= staleAfterMs;

  const value24h = document.getElementById('forecast-24h');
  const value6h = document.getElementById('forecast-6h');
  value24h.textContent = available ? `${chance24h}%` : '--';
  value6h.textContent = available ? `${chance6h}%` : '--';
  const highlight24h = available && chance24h >= threshold24h;
  const highlight6h = available && chance6h >= threshold6h;
  value24h.classList.toggle('threshold-reached', highlight24h);
  value6h.classList.toggle('threshold-reached', highlight6h);
  value24h.title = highlight24h ? t('forecastThresholdReached', { value: threshold24h }) : '';
  value6h.title = highlight6h ? t('forecastThresholdReached', { value: threshold6h }) : '';
  strip.classList.toggle('unavailable', !available);
  status.textContent = available
    ? t('forecastUpdated', { value: formatParisDateTime(generatedAt) })
    : t('forecastUnavailable');
}

function setMainError(message = '') {
  const element = document.getElementById('error-banner');
  mainFailure = message || null;
  const safeMessage = displayText(message, t('warningFallback'));
  element.textContent = message
    ? `${t('warningPrefix')}: ${t(dashboardData ? 'refreshFailedWithData' : 'refreshFailedWithoutData', { message: safeMessage })}`
    : '';
  element.hidden = !message;
}

function setHistoryError(message = '') {
  const element = document.getElementById('history-error');
  element.textContent = message ? `${t('chartPrefix')}: ${displayText(message, t('chartFallback'))}` : '';
  element.hidden = !message;
}

function setHistoryState(state) {
  document.body.dataset.historyState = state;
}

function setHistoryCanvasVisible(visible) {
  const canvas = document.getElementById('history-chart');
  canvas.hidden = !visible;
  removeElementAttribute(canvas, 'aria-describedby');
}

function destroyChart(title = t('historyUnavailable')) {
  const chartToDestroy = chart;
  chart = null;
  if (chartToDestroy) {
    try {
      chartToDestroy.destroy();
    } catch (_error) {
      // Chart.js cleanup is best effort; accessible fallbacks must still render.
    }
  }
  document.getElementById('history-label').textContent = title;
  setHistoryCanvasVisible(false);
}

function normalizeHistory(history) {
  if (!Array.isArray(history)) throw historyError('invalidHistory');
  if (history.length === 0) throw historyError('historyEmpty');

  const byTimestamp = new Map();
  for (const item of history) {
    if (!item || typeof item !== 'object' || Array.isArray(item)) continue;
    validateSnapshotSchema(item, true);
    const timestamp = Date.parse(displayText(item.scraped_at, ''));
    const fiveHour = validPct(item.five_h_pct);
    const weekly = validPct(item.weekly_pct);
    if (!Number.isFinite(timestamp) || (fiveHour === null && weekly === null)) continue;
    const weeklyReset = Number(item.weekly_reset_at);
    const forecast24h = validPct(item.codex_forecast?.chance_24h_pct);
    const forecast6h = validPct(item.codex_forecast?.chance_6h_pct);
    byTimestamp.set(timestamp, {
      timestamp,
      fiveHour,
      weekly,
      weeklyReset: Number.isFinite(weeklyReset) && weeklyReset > 0 ? weeklyReset : null,
      forecast24h,
      forecast6h,
    });
  }

  const points = [...byTimestamp.values()].sort((a, b) => a.timestamp - b.timestamp);
  if (points.length === 0) throw historyError('historyNoValidSamples');
  return points;
}

function historyError(key) {
  const error = new Error(t(key));
  error.historyKey = key;
  return error;
}

function shouldPreserveValidHistory(error) {
  return error instanceof Error
    && ['chartFailed', 'unsupportedSchema', 'invalidSnapshotSchema'].includes(error.historyKey)
    && Array.isArray(dashboardHistoryPoints)
    && dashboardHistoryPoints.length > 0;
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
      valueKind: 'percent',
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
      valueKind: 'percent',
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
      valueKind: 'percent',
    },
    {
      label: t('forecast24hDataset'),
      data: points.map(point => ({ x: point.timestamp, y: point.forecast24h })),
      borderColor: '#a78bfa',
      backgroundColor: 'transparent',
      borderWidth: 2,
      pointRadius: points.length > 200 ? 0 : 2,
      tension: 0.3,
      fill: false,
      spanGaps: false,
      valueKind: 'percent',
    },
    {
      label: t('forecast6hDataset'),
      data: points.map(point => ({ x: point.timestamp, y: point.forecast6h })),
      borderColor: '#fbbf24',
      backgroundColor: 'transparent',
      borderWidth: 2,
      pointRadius: points.length > 200 ? 0 : 2,
      tension: 0.3,
      fill: false,
      spanGaps: false,
      valueKind: 'percent',
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
  // Normalize first.  A future/invalid payload must not erase the last valid
  // chart state; the caller can then render an explicit error while retaining
  // those points for the accessible fallback.
  const points = normalizeHistory(history);
  dashboardHistory = history;
  dashboardHistoryPoints = points;
  historyFailure = null;
  historyFailureKey = null;
  const datasets = chartDatasets(points);
  const timeBounds = chartTimeBounds(points);
  document.getElementById('history-label').textContent = historyTitle(points);
  setHistoryState('valid');

  if (chart) {
    try {
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
    } catch (error) {
      const chartError = historyError('chartFailed');
      chartError.cause = error;
      throw chartError;
    }
    setHistoryError();
    setHistoryCanvasVisible(true);
    return;
  }

  if (typeof Chart !== 'function') throw historyError('chartFailed');
  const context = document.getElementById('history-chart').getContext('2d');
  let options = {
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
  };
  if (typeof CodexChartInteractions === 'object') {
    options = CodexChartInteractions.enhanceOptions(options, {
      formatTitle: value => formatParisDateTime(value),
      formatValue: value => `${new Intl.NumberFormat(currentLocale(), { maximumFractionDigits: 1 }).format(value)}%`,
    });
  }
  try {
    chart = new Chart(context, {
      type: 'line',
      data: { datasets },
      options,
    });
  } catch (error) {
    chart = null;
    const chartError = historyError('chartFailed');
    chartError.cause = error;
    throw chartError;
  }
  setHistoryError();
  setHistoryCanvasVisible(true);
}

function renderHistoryFailure(message, key = null, { preserveValidHistory = false } = {}) {
  historyFailure = message;
  historyFailureKey = key;
  const hasValidHistory = preserveValidHistory
    && Array.isArray(dashboardHistoryPoints)
    && dashboardHistoryPoints.length > 0;
  if (hasValidHistory) {
    setHistoryState('chart-unavailable');
    // Unsupported/invalid payloads are transient publication failures. Keep
    // the last rendered chart and points visible while surfacing the error;
    // only an empty history or a chart rendering failure should destroy it.
    const keepVisible = ['unsupportedSchema', 'invalidSnapshotSchema'].includes(key);
    if (keepVisible) {
      setHistoryCanvasVisible(true);
    } else {
      destroyChart(historyTitle(dashboardHistoryPoints));
    }
  } else {
    dashboardHistory = null;
    dashboardHistoryPoints = null;
    setHistoryState('unavailable');
    destroyChart();
  }
  setHistoryError(message);
}

function renderData(data, { schedule = true, clearError = true } = {}) {
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    throw new Error(t('invalidDashboardData'));
  }
  validateSnapshotSchema(data);
  classifySnapshotFreshness(data);
  dashboardData = data;
  setBar('five-h-bar', 'five-h-pct', data.five_h_pct, 'fiveHourQuotaLabel', '--');
  setBar('weekly-bar', 'weekly-pct', data.weekly_pct, 'weeklyQuotaLabel');
  renderForecast(data);
  document.getElementById('five-h-reset').textContent = formatParisUnixTimestamp(data.five_h_reset_at);
  document.getElementById('weekly-reset').textContent = formatParisUnixTimestamp(data.weekly_reset_at);
  renderWeeklyPaceDelta(data);
  document.getElementById('last-updated').textContent = t('lastScraped', {
    value: formatParisDateTime(displayText(data.scraped_at, '')),
  });
  renderFreshness();
  if (clearError) setMainError();
  if (schedule) scheduleRefresh(data);
}

async function fetchJson(url, missingMessage) {
  const response = await fetch(`${url}?_=${Date.now()}`);
  if (!response.ok) {
    const error = new Error(response.status === 404 ? missingMessage : `HTTP ${response.status}`);
    if (response.status === 404 && missingMessage === t('historyNotFound')) error.historyKey = 'historyNotFound';
    return Promise.reject(error);
  }
  return response.json();
}

async function fetchLocal() {
  const data = await fetchJson('data.json', t('dataNotFound'));
  validateSnapshotSchema(data);
  classifySnapshotFreshness(data);
  renderSource('local');
  renderData(data);

  try {
    renderHistory(await fetchJson('history.json', t('historyNotFound')));
  } catch (error) {
    renderHistoryFailure(
      error instanceof Error ? error.message : t('unableToLoadHistory'),
      error instanceof Error ? error.historyKey || null : null,
      { preserveValidHistory: shouldPreserveValidHistory(error) },
    );
  }
}

async function fetchGist() {
  const response = await fetch(`https://api.github.com/gists/${encodeURIComponent(GIST_ID)}?_=${Date.now()}`);
  if (!response.ok) throw new Error(t('githubApiError', { status: response.status }));
  const gist = await response.json();
  const dataContent = gist?.files?.['data.json']?.content;
  if (!dataContent) throw new Error(t('gistDataNotFound'));
  const data = JSON.parse(dataContent);
  validateSnapshotSchema(data);
  classifySnapshotFreshness(data);
  renderSource('external');
  renderData(data);

  try {
    const historyContent = gist?.files?.['history.json']?.content;
    if (!historyContent) throw historyError('gistHistoryNotFound');
    renderHistory(JSON.parse(historyContent));
  } catch (error) {
    renderHistoryFailure(
      error instanceof Error ? error.message : t('unableToLoadHistory'),
      error instanceof Error ? error.historyKey || null : null,
      { preserveValidHistory: shouldPreserveValidHistory(error) },
    );
  }
}

function refresh() {
  if (refreshInFlight) return refreshInFlight;
  const operation = (async () => {
    try {
      await (GIST_ID ? fetchGist() : fetchLocal());
    } catch (error) {
      setMainError(error instanceof Error ? error.message : t('unableToLoadData'));
      renderFreshness();
      scheduleRefresh();
    }
  })();
  refreshInFlight = operation;
  operation.finally(() => {
    if (refreshInFlight === operation) refreshInFlight = null;
  });
  return operation;
}

function refreshLocalizedDashboard() {
  if (dashboardSource) renderSource(dashboardSource);
  if (dashboardData) renderData(dashboardData, { schedule: false, clearError: false });
  else renderFreshness();
  if (mainFailure) setMainError(mainFailure);
  if (dashboardHistory && dashboardHistoryPoints) {
    try {
      renderHistory(dashboardHistory);
    } catch (error) {
      renderHistoryFailure(
        error instanceof Error ? error.message : t('unableToLoadHistory'),
        error instanceof Error ? error.historyKey || null : null,
        { preserveValidHistory: true },
      );
    }
  } else if (historyFailure) {
    const localizedFailure = historyFailureKey ? t(historyFailureKey) : historyFailure;
    destroyChart(t('historyUnavailable'));
    setHistoryError(localizedFailure);
  }
}

if (typeof CodexPreferences === 'object') CodexPreferences.subscribe(refreshLocalizedDashboard);
document.addEventListener('visibilitychange', handleDashboardVisibility);
window.addEventListener('pageshow', handleDashboardVisibility);
window.addEventListener('pagehide', handleDashboardPageHide);
renderSource(isLocalDashboard() ? 'local' : 'external');
renderFreshness();
startDashboardHeartbeat();
refresh();
