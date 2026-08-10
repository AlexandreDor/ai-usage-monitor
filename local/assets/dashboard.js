'use strict';

// Set a Gist ID to use the GitHub API instead of local JSON files.
const GIST_ID = '';
const REFRESH_INTERVAL_MS = 900_000;
const DECIMATION_THRESHOLD = 1000;
const DECIMATION_SAMPLES = 600;
const PARIS_TIME_ZONE = 'Europe/Paris';
const SAFE_GITHUB_RAW_HOSTS = new Set(['gist.githubusercontent.com', 'raw.githubusercontent.com']);
const MAX_RAW_URL_LENGTH = 2048;

let chart = null;
let refreshTimer = null;
let dashboardData = null;
let dashboardHistory = null;
let historyFailure = null;
let mainFailure = null;
let dashboardOrigin = null;
let freshnessState = 'waiting';
let freshnessFailure = null;
let lastSampleAt = null;
let sampleIntervalSeconds = REFRESH_INTERVAL_MS / 1000;

const DASHBOARD_COPY = {
  en: {
    source: 'Source', waiting: 'Waiting for data', fresh: 'FRESH', stale: 'STALE', error: 'ERROR',
    freshDetail: 'Data is current', staleDetail: 'Data is overdue', errorDetail: 'Refresh failed; showing last known quotas',
    sampleAge: 'Sample age: {value}', unavailable: 'unavailable', seconds: '{value}s', minutes: '{minutes}m {seconds}s', hours: '{hours}h {minutes}m',
    quotaHealthy: 'Quota status: comfortable', quotaCaution: 'Quota status: low', quotaCritical: 'Quota status: critical', quotaUnavailable: 'Quota status: unavailable',
    actual: 'Actual: {value}', ideal: 'Ideal: {value}', aheadBy: 'Ahead by {value} points', behindBy: 'Behind by {value} points', onIdealPace: 'On ideal pace',
    historySummary: '{count} samples from {start} to {end}. Latest weekly: {actual}; ideal: {ideal}.',
    historySummarySingle: '1 sample at {start}. Weekly: {actual}; ideal: {ideal}.', noHistory: 'No history samples available.',
    historyTableToggle: 'View history data table', historyTableCaption: 'Quota history samples', sample: 'Sample', fiveRemaining: '5-hour remaining', weeklyRemaining: 'Weekly remaining', weeklyIdeal: 'Weekly ideal',
    gistRawUrlUnsafe: 'External {file} degraded: GitHub returned truncated content, but its raw URL was not allowed.',
    gistRawFetchFailed: 'External {file} degraded: GitHub returned truncated content; the full file could not be loaded.',
    gistRawInvalid: 'External {file} degraded: GitHub returned truncated content; the full file was not valid JSON.',
  },
  fr: {
    source: 'Origine', waiting: 'En attente de données', fresh: 'FRESH', stale: 'STALE', error: 'ERROR',
    freshDetail: 'Données à jour', staleDetail: 'Données en retard', errorDetail: 'Actualisation échouée ; derniers quotas connus affichés',
    sampleAge: 'Âge de la collecte : {value}', unavailable: 'indisponible', seconds: '{value} s', minutes: '{minutes} min {seconds} s', hours: '{hours} h {minutes} min',
    quotaHealthy: 'Statut du quota : confortable', quotaCaution: 'Statut du quota : faible', quotaCritical: 'Statut du quota : critique', quotaUnavailable: 'Statut du quota : indisponible',
    actual: 'Réel : {value}', ideal: 'Idéal : {value}', aheadBy: 'En avance de {value} points', behindBy: 'En retard de {value} points', onIdealPace: 'Dans le rythme idéal',
    historySummary: '{count} collectes du {start} au {end}. Dernier quota hebdomadaire : {actual} ; idéal : {ideal}.',
    historySummarySingle: '1 collecte à {start}. Quota hebdomadaire : {actual} ; idéal : {ideal}.', noHistory: 'Aucune collecte disponible.',
    historyTableToggle: 'Afficher le tableau des collectes', historyTableCaption: 'Historique des quotas', sample: 'Collecte', fiveRemaining: 'Reste sur 5 heures', weeklyRemaining: 'Reste hebdomadaire', weeklyIdeal: 'Ideal hebdomadaire',
    gistRawUrlUnsafe: '{file} externe dégradé : GitHub a renvoyé un contenu tronqué, mais son URL raw n’est pas autorisée.',
    gistRawFetchFailed: '{file} externe dégradé : le contenu tronqué de GitHub n’a pas permis de charger le fichier complet.',
    gistRawInvalid: '{file} externe dégradé : le fichier complet renvoyé n’est pas un JSON valide.',
  },
};

function t(key, values = {}) {
  return typeof CodexPreferences === 'object' ? CodexPreferences.t(`dashboard.${key}`, values) : key;
}

function currentLocale() {
  return typeof CodexPreferences === 'object' ? CodexPreferences.locale() : 'en-GB';
}

function copy(key, values = {}) {
  const language = currentLocale().startsWith('fr') ? 'fr' : 'en';
  return (DASHBOARD_COPY[language][key] || key).replace(/\{(\w+)\}/g, (_match, name) => values[name] ?? '');
}

function validPct(value) {
  if (value === null || value === undefined || value === '') return null;
  const pct = Number(value);
  return Number.isFinite(pct) && pct >= 0 && pct <= 100 ? pct : null;
}

function displayText(value, fallback = '-', maxLength = 200) {
  return typeof value === 'string' && value.length <= maxLength ? value : fallback;
}

function formatAge(ageSeconds) {
  if (!Number.isFinite(ageSeconds)) return copy('unavailable');
  const seconds = Math.max(0, Math.floor(ageSeconds));
  if (seconds < 60) return copy('seconds', { value: seconds });
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return copy('minutes', { minutes, seconds: seconds % 60 });
  return copy('hours', { hours: Math.floor(minutes / 60), minutes: minutes % 60 });
}

function setOrigin(origin) {
  dashboardOrigin = origin;
  const badge = document.getElementById('mode-badge');
  badge.textContent = t(origin);
  badge.setAttribute('data-origin', origin);
}

function setFreshness(state, { force = false } = {}) {
  if (!['waiting', 'fresh', 'stale', 'error'].includes(state)) return;
  if (!force && freshnessState === state) return;
  freshnessState = state;
  const container = document.getElementById('dashboard-status');
  container.classList.remove('waiting', 'fresh', 'stale', 'error');
  container.classList.add(state);
  container.setAttribute('data-state', state);
  document.getElementById('freshness-badge').textContent = state === 'waiting' ? '-' : copy(state);
  document.getElementById('freshness-detail').textContent = state === 'waiting' ? copy('waiting') : copy(`${state}Detail`);
}

function updateFreshness(now = Date.now()) {
  const ageSeconds = Number.isFinite(lastSampleAt) && Number.isFinite(now)
    ? (now - lastSampleAt) / 1000
    : null;
  document.getElementById('sample-age').textContent = copy('sampleAge', { value: formatAge(ageSeconds) });
  if (ageSeconds === null) {
    if (dashboardData) {
      freshnessFailure = 'timestamp';
      setFreshness('error');
    } else if (!mainFailure) {
      setFreshness('waiting');
    }
  } else if (ageSeconds < 0) {
    freshnessFailure = 'timestamp';
    setFreshness('error');
  } else if (freshnessFailure !== 'network') {
    freshnessFailure = null;
    setFreshness(ageSeconds >= sampleIntervalSeconds * 2 ? 'stale' : 'fresh');
  }
}

function localizeDashboardChrome() {
  document.getElementById('origin-label').textContent = copy('source');
  document.getElementById('history-table-toggle').textContent = copy('historyTableToggle');
  document.getElementById('history-table-caption').textContent = copy('historyTableCaption');
  document.getElementById('history-time-heading').textContent = copy('sample');
  document.getElementById('history-five-heading').textContent = copy('fiveRemaining');
  document.getElementById('history-weekly-heading').textContent = copy('weeklyRemaining');
  document.getElementById('history-ideal-heading').textContent = copy('weeklyIdeal');
  if (dashboardOrigin) setOrigin(dashboardOrigin);
  if (freshnessState) setFreshness(freshnessState, { force: true });
  updateFreshness();
}

function scheduleRefresh(data = null) {
  const intervalSeconds = Number(data?.sample_interval_seconds);
  if (Number.isFinite(intervalSeconds) && intervalSeconds > 0) sampleIntervalSeconds = intervalSeconds;
  const intervalMs = Math.max(1000, sampleIntervalSeconds * 1000);
  clearTimeout(refreshTimer);
  refreshTimer = setTimeout(refresh, intervalMs);
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
  const actualElement = document.getElementById('weekly-actual');
  const idealElement = document.getElementById('weekly-ideal');
  const actual = validPct(data.weekly_pct);
  const ideal = idealWeeklyRemaining(data.scraped_at, data.weekly_reset_at);
  element.classList.remove('ahead', 'behind');
  actualElement.textContent = copy('actual', { value: actual === null ? '--' : `${actual.toFixed(1)}%` });
  idealElement.textContent = copy('ideal', { value: ideal === null ? '--' : `${ideal.toFixed(1)}%` });

  if (actual === null || ideal === null) {
    element.textContent = '--';
    element.title = t('weeklyPaceUnavailable');
    return;
  }

  const rawDifference = actual - ideal;
  const pointDifference = Math.round(rawDifference * 10) / 10;
  element.textContent = pointDifference === 0
    ? copy('onIdealPace')
    : copy(pointDifference > 0 ? 'aheadBy' : 'behindBy', { value: Math.abs(pointDifference).toFixed(1) });
  element.title = `${t('actualRemaining')}: ${actual.toFixed(1)}% / ${t('idealRemaining')}: ${ideal.toFixed(1)}%`;
  element.classList.add(pointDifference >= 0 ? 'ahead' : 'behind');
}

function setBar(barId, pctId, criticalityId, pct) {
  const safePct = validPct(pct);
  const bar = document.getElementById(barId);
  const value = document.getElementById(pctId);
  const criticality = document.getElementById(criticalityId);
  const level = safePct === null ? 'unavailable' : safePct <= 10 ? 'critical' : safePct <= 25 ? 'caution' : 'healthy';
  if (safePct === null) bar.removeAttribute('value');
  else bar.value = safePct;
  value.textContent = safePct === null ? '--' : `${safePct}%`;
  value.classList.toggle('unavailable', safePct === null);
  criticality.classList.remove('healthy', 'caution', 'critical', 'unavailable');
  criticality.classList.add(level);
  criticality.textContent = copy(`quota${level[0].toUpperCase()}${level.slice(1)}`);
  bar.setAttribute('aria-valuetext', safePct === null ? copy('quotaUnavailable') : `${safePct}% - ${criticality.textContent}`);
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
  document.getElementById('history-chart').hidden = true;
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

function historyPct(value) {
  return value === null ? '--' : `${value.toFixed(1)}%`;
}

function tableCell(row, value) {
  const cell = document.createElement('td');
  cell.textContent = value;
  row.appendChild(cell);
}

function renderHistoryAccessible(points) {
  const start = formatParisDateTime(points[0].timestamp);
  const end = formatParisDateTime(points[points.length - 1].timestamp);
  const latest = points[points.length - 1];
  const latestIdeal = idealWeeklyRemaining(latest.timestamp, latest.weeklyReset);
  document.getElementById('history-summary').textContent = copy(
    points.length === 1 ? 'historySummarySingle' : 'historySummary',
    { count: points.length, start, end, actual: historyPct(latest.weekly), ideal: historyPct(latestIdeal) },
  );

  const body = document.getElementById('history-table-body');
  body.replaceChildren();
  for (const point of points) {
    const row = document.createElement('tr');
    tableCell(row, formatParisDateTime(point.timestamp));
    tableCell(row, historyPct(point.fiveHour));
    tableCell(row, historyPct(point.weekly));
    tableCell(row, historyPct(idealWeeklyRemaining(point.timestamp, point.weeklyReset)));
    body.appendChild(row);
  }
}

function renderEmptyHistoryAccessible() {
  document.getElementById('history-summary').textContent = copy('noHistory');
  const body = document.getElementById('history-table-body');
  const row = document.createElement('tr');
  const cell = document.createElement('td');
  cell.colSpan = 4;
  cell.textContent = copy('noHistory');
  row.appendChild(cell);
  body.replaceChildren(row);
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
  renderHistoryAccessible(points);

  if (chart) {
    document.getElementById('history-chart').hidden = false;
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

  if (typeof Chart !== 'function') {
    document.getElementById('history-chart').hidden = true;
    setHistoryError(t('chartFailed'));
    return;
  }
  try {
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
    document.getElementById('history-chart').hidden = false;
    setHistoryError();
  } catch (error) {
    chart = null;
    document.getElementById('history-chart').hidden = true;
    setHistoryError(error instanceof Error ? error.message : t('chartFailed'));
  }
}

function renderHistoryFailure(message) {
  historyFailure = message;
  dashboardHistory = null;
  destroyChart();
  renderEmptyHistoryAccessible();
  setHistoryError(message);
}

function renderData(data, { schedule = true, preserveHealth = false } = {}) {
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    throw new Error(t('invalidDashboardData'));
  }
  dashboardData = data;
  const intervalSeconds = Number(data.sample_interval_seconds);
  if (Number.isFinite(intervalSeconds) && intervalSeconds > 0) sampleIntervalSeconds = intervalSeconds;
  lastSampleAt = Date.parse(displayText(data.scraped_at, ''));
  if (!Number.isFinite(lastSampleAt)) lastSampleAt = null;
  setBar('five-h-bar', 'five-h-pct', 'five-h-criticality', data.five_h_pct);
  setBar('weekly-bar', 'weekly-pct', 'weekly-criticality', data.weekly_pct);
  document.getElementById('five-h-reset').textContent = formatParisUnixTimestamp(data.five_h_reset_at);
  document.getElementById('weekly-reset').textContent = formatParisUnixTimestamp(data.weekly_reset_at);
  renderWeeklyPaceDelta(data);
  document.getElementById('last-updated').textContent = t('lastScraped', {
    value: formatParisDateTime(displayText(data.scraped_at, '')),
  });
  if (!preserveHealth) {
    setMainError();
    freshnessFailure = null;
    freshnessState = null;
  }
  updateFreshness();
  if (schedule) scheduleRefresh(data);
}

async function fetchJson(url, missingMessage) {
  const response = await fetch(`${url}?_=${Date.now()}`);
  if (!response.ok) throw new Error(response.status === 404 ? missingMessage : `HTTP ${response.status}`);
  return response.json();
}

function safeRawUrl(rawUrl) {
  if (typeof rawUrl !== 'string' || rawUrl.length === 0 || rawUrl.length > MAX_RAW_URL_LENGTH) return null;
  if (typeof URL !== 'function') return null;

  const pageLocation = typeof location === 'object' && location !== null ? location : null;
  let candidate;
  try {
    candidate = new URL(rawUrl, pageLocation?.href);
  } catch (_error) {
    return null;
  }

  if (candidate.username || candidate.password || candidate.port) return null;
  if (pageLocation?.origin && candidate.origin === pageLocation.origin) return candidate.href;
  if (candidate.protocol === 'https:' && SAFE_GITHUB_RAW_HOSTS.has(candidate.hostname.toLowerCase())) {
    return candidate.href;
  }
  return null;
}

function gistFileLabel(filename) {
  return filename === 'history.json' ? 'history' : 'dashboard data';
}

async function fetchGistRawJson(rawUrl, filename) {
  const label = gistFileLabel(filename);
  let response;
  try {
    response = await fetch(rawUrl, { redirect: 'error' });
  } catch (_error) {
    throw new Error(copy('gistRawFetchFailed', { file: label }));
  }
  if (!response.ok) throw new Error(copy('gistRawFetchFailed', { file: label }));
  try {
    return await response.json();
  } catch (_error) {
    throw new Error(copy('gistRawInvalid', { file: label }));
  }
}

async function fetchGistFile(file, filename, missingMessage) {
  if (!file || typeof file !== 'object' || Array.isArray(file)) throw new Error(missingMessage);
  if (file.truncated === true) {
    const rawUrl = safeRawUrl(file.raw_url);
    if (!rawUrl) throw new Error(copy('gistRawUrlUnsafe', { file: gistFileLabel(filename) }));
    return fetchGistRawJson(rawUrl, filename);
  }
  if (typeof file.content !== 'string' || file.content.length === 0) throw new Error(missingMessage);
  return JSON.parse(file.content);
}

async function fetchLocal() {
  setOrigin('local');
  const data = await fetchJson('data.json', t('dataNotFound'));
  renderData(data);

  try {
    renderHistory(await fetchJson('history.json', t('historyNotFound')));
  } catch (error) {
    renderHistoryFailure(error instanceof Error ? error.message : t('unableToLoadHistory'));
  }
}

async function fetchGist() {
  setOrigin('external');
  const response = await fetch(`https://api.github.com/gists/${encodeURIComponent(GIST_ID)}?_=${Date.now()}`);
  if (!response.ok) throw new Error(t('githubApiError', { status: response.status }));
  const gist = await response.json();
  renderData(await fetchGistFile(gist?.files?.['data.json'], 'data.json', t('gistDataNotFound')));

  try {
    renderHistory(await fetchGistFile(gist?.files?.['history.json'], 'history.json', t('gistHistoryNotFound')));
  } catch (error) {
    renderHistoryFailure(error instanceof Error ? error.message : t('unableToLoadHistory'));
  }
}

async function refresh() {
  try {
    await (GIST_ID ? fetchGist() : fetchLocal());
  } catch (error) {
    setMainError(error instanceof Error ? error.message : t('unableToLoadData'));
    freshnessFailure = 'network';
    setFreshness('error');
    scheduleRefresh(dashboardData);
  }
}

function refreshLocalizedDashboard() {
  localizeDashboardChrome();
  if (dashboardData) renderData(dashboardData, { schedule: false, preserveHealth: true });
  if (mainFailure) setMainError(mainFailure);
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
localizeDashboardChrome();
refresh();
setInterval(updateFreshness, 1000);
