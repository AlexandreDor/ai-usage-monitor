'use strict';

// Set a Gist ID to use the GitHub API instead of local JSON files.
const GIST_ID = '';
const REFRESH_INTERVAL_MS = 900_000;
const DEFAULT_SAMPLE_INTERVAL_SECONDS = REFRESH_INTERVAL_MS / 1000;
const FRESHNESS_CHECK_MAX_DELAY_MS = 60_000;
const DECIMATION_THRESHOLD = 1000;
const DECIMATION_SAMPLES = 600;
const PARIS_TIME_ZONE = 'Europe/Paris';

const LOCAL_COPY = Object.freeze({
  en: Object.freeze({
    freshnessLabel: 'Freshness',
    fresh: 'FRESH',
    stale: 'STALE',
    error: 'ERROR',
    unknown: 'UNKNOWN',
    dataAge: 'Data age',
    ageUnavailable: 'Age unavailable',
    expectedInterval: 'Expected every {value}',
    seconds: '{value} seconds',
    minutes: '{value} minutes',
    hours: '{value} hours',
    days: '{value} days',
    availability: 'Availability',
    criticality: 'Criticality',
    available: 'Available',
    unavailable: 'Unavailable',
    normal: 'Normal',
    attention: 'Attention',
    critical: 'Critical',
    freshnessChanged: 'Freshness changed: {status}.',
    freshnessFresh: 'The latest successful sample is within the expected interval.',
    freshnessStale: 'The latest successful sample is older than two expected intervals.',
    freshnessError: 'The latest refresh failed; the last successful data remains visible.',
    freshnessUnknown: 'The age of the latest sample is unavailable.',
    historyData: 'History data',
    sampleTime: 'Sample time',
    showHistoryTable: 'Show history table',
    hideHistoryTable: 'Hide history table',
    noValue: '—',
    historySummary: '{count} samples from {from} to {to}. Latest: 5-hour {fiveHour}; weekly {weekly}; ideal weekly {ideal}.',
  }),
  fr: Object.freeze({
    freshnessLabel: 'Fraîcheur',
    fresh: 'FRESH',
    stale: 'STALE',
    error: 'ERROR',
    unknown: 'UNKNOWN',
    dataAge: 'Âge des données',
    ageUnavailable: 'Âge indisponible',
    expectedInterval: 'Intervalle attendu : {value}',
    seconds: '{value} secondes',
    minutes: '{value} minutes',
    hours: '{value} heures',
    days: '{value} jours',
    availability: 'Disponibilité',
    criticality: 'Criticité',
    available: 'Disponible',
    unavailable: 'Indisponible',
    normal: 'Normal',
    attention: 'Attention',
    critical: 'Critique',
    freshnessChanged: 'Fraîcheur modifiée : {status}.',
    freshnessFresh: 'Le dernier relevé réussi est dans l’intervalle attendu.',
    freshnessStale: 'Le dernier relevé réussi date de plus de deux intervalles attendus.',
    freshnessError: 'Le dernier rafraîchissement a échoué ; les dernières données réussies restent visibles.',
    freshnessUnknown: 'L’âge du dernier relevé est indisponible.',
    historyData: 'Données historiques',
    sampleTime: 'Heure du relevé',
    showHistoryTable: 'Afficher le tableau historique',
    hideHistoryTable: 'Masquer le tableau historique',
    noValue: '—',
    historySummary: '{count} relevés du {from} au {to}. Dernier relevé : 5 heures {fiveHour} ; hebdomadaire {weekly} ; rythme idéal {ideal}.',
  }),
});

let chart = null;
let refreshTimer = null;
let freshnessTimer = null;
let dashboardData = null;
let dashboardHistory = null;
let historyFailure = null;
let mainFailure = null;
let dashboardMode = null;
let freshnessState = 'unknown';
let historyTableBound = false;

function t(key, values = {}) {
  return typeof CodexPreferences === 'object' ? CodexPreferences.t(`dashboard.${key}`, values) : key;
}

function currentLocale() {
  return typeof CodexPreferences === 'object' ? CodexPreferences.locale() : 'en-GB';
}

function currentLanguage() {
  if (typeof CodexPreferences === 'object' && typeof CodexPreferences.get === 'function') {
    return CodexPreferences.get().language === 'fr' ? 'fr' : 'en';
  }
  return currentLocale().toLowerCase().startsWith('fr') ? 'fr' : 'en';
}

function localCopy(key, values = {}) {
  const language = currentLanguage();
  const template = LOCAL_COPY[language][key] || LOCAL_COPY.en[key] || key;
  return template.replace(/\{(\w+)\}/g, (_match, name) => values[name] === undefined ? `{${name}}` : String(values[name]));
}

function setAttribute(element, name, value) {
  if (element && typeof element.setAttribute === 'function') element.setAttribute(name, String(value));
}

function removeAttribute(element, name) {
  if (element && typeof element.removeAttribute === 'function') element.removeAttribute(name);
}

function setDataAttribute(element, name, value) {
  setAttribute(element, `data-${name}`, value);
}

function setText(element, value) {
  if (element) element.textContent = value;
}

function validPct(value) {
  if (value === null || value === undefined || value === '') return null;
  const pct = Number(value);
  return Number.isFinite(pct) && pct >= 0 && pct <= 100 ? pct : null;
}

function displayText(value, fallback = '-', maxLength = 200) {
  return typeof value === 'string' && value.length <= maxLength ? value : fallback;
}

function parseScrapedTimestamp(value) {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.abs(value) < 1_000_000_000_000 ? value * 1000 : value;
  }
  const timestamp = Date.parse(displayText(value, ''));
  return Number.isFinite(timestamp) ? timestamp : null;
}

function sampleIntervalSeconds(data) {
  const interval = Number(data?.sample_interval_seconds);
  return Number.isFinite(interval) && interval > 0 ? interval : DEFAULT_SAMPLE_INTERVAL_SECONDS;
}

function freshnessInfo(data, now = Date.now()) {
  const scrapedAtMs = parseScrapedTimestamp(data?.scraped_at);
  const intervalSeconds = sampleIntervalSeconds(data);
  const ageSeconds = scrapedAtMs === null
    ? null
    : Math.max(0, (now - scrapedAtMs) / 1000);
  const staleAfterSeconds = intervalSeconds * 2;
  return {
    scrapedAtMs,
    intervalSeconds,
    ageSeconds,
    staleAfterSeconds,
    state: ageSeconds === null ? 'unknown' : ageSeconds >= staleAfterSeconds ? 'stale' : 'fresh',
  };
}

function formatDuration(seconds) {
  if (!Number.isFinite(seconds)) return localCopy('ageUnavailable');
  const safeSeconds = Math.max(0, Math.floor(seconds));
  if (safeSeconds < 60) return localCopy('seconds', { value: safeSeconds });
  const minutes = Math.floor(safeSeconds / 60);
  if (minutes < 60) return localCopy('minutes', { value: minutes });
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return localCopy('hours', { value: hours });
  return localCopy('days', { value: Math.floor(hours / 24) });
}

function freshnessStatusLabel(state) {
  return LOCAL_COPY[currentLanguage()][state] || LOCAL_COPY.en[state] || state.toUpperCase();
}

function freshnessDetail(state, info) {
  if (state === 'fresh') return localCopy('freshnessFresh');
  if (state === 'stale') return localCopy('freshnessStale');
  if (state === 'error') return localCopy('freshnessError');
  return localCopy('freshnessUnknown');
}

function setFreshnessState(state, { announce = true, info = null } = {}) {
  const nextState = ['fresh', 'stale', 'error', 'unknown'].includes(state) ? state : 'unknown';
  const changed = freshnessState !== nextState;
  freshnessState = nextState;
  const status = document.getElementById('freshness-status');
  const announcement = document.getElementById('freshness-announcement');
  const label = freshnessStatusLabel(nextState);
  setText(status, label);
  setDataAttribute(status, 'state', nextState);
  setAttribute(status, 'aria-label', `${localCopy('freshnessLabel')}: ${label}`);
  if (changed && announce && announcement) {
    const detail = freshnessDetail(nextState, info);
    announcement.textContent = `${localCopy('freshnessChanged', { status: label })} ${detail}`;
  }
}

function updateFreshnessAge(info) {
  const age = document.getElementById('freshness-age');
  const ageLabel = document.getElementById('freshness-age-label');
  const interval = document.getElementById('freshness-interval');
  if (!age || !ageLabel || !interval) return;
  const value = info.ageSeconds === null ? localCopy('ageUnavailable') : formatDuration(info.ageSeconds);
  ageLabel.textContent = localCopy('dataAge');
  age.textContent = value;
  setAttribute(age, 'aria-label', `${localCopy('dataAge')}: ${value}`);
  if (info.scrapedAtMs !== null) setAttribute(age, 'datetime', new Date(info.scrapedAtMs).toISOString());
  else removeAttribute(age, 'datetime');
  interval.textContent = localCopy('expectedInterval', { value: formatDuration(info.intervalSeconds) });
}

function updateFreshness({ announce = true } = {}) {
  if (!dashboardData) return null;
  const info = freshnessInfo(dashboardData);
  updateFreshnessAge(info);
  if (freshnessState !== 'error') setFreshnessState(info.state, { announce, info });
  return info;
}

function scheduleFreshnessCheck(data = dashboardData) {
  clearTimeout(freshnessTimer);
  if (!data) return;
  const info = freshnessInfo(data);
  const remainingMs = info.ageSeconds === null
    ? FRESHNESS_CHECK_MAX_DELAY_MS
    : Math.max(0, (info.staleAfterSeconds - info.ageSeconds) * 1000);
  const delay = info.state === 'fresh'
    ? Math.max(1_000, Math.min(FRESHNESS_CHECK_MAX_DELAY_MS, remainingMs + 50))
    : FRESHNESS_CHECK_MAX_DELAY_MS;
  freshnessTimer = setTimeout(() => {
    updateFreshness();
    scheduleFreshnessCheck(data);
  }, delay);
}

function scheduleRefresh(data = null) {
  const intervalMs = sampleIntervalSeconds(data) * 1000;
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
  const actualElement = document.getElementById('weekly-pace-actual');
  const idealElement = document.getElementById('weekly-pace-ideal');
  const actual = validPct(data.weekly_pct);
  const ideal = idealWeeklyRemaining(data.scraped_at, data.weekly_reset_at);
  element.classList.remove('ahead', 'behind');

  if (actual === null || ideal === null) {
    element.textContent = '--';
    setText(actualElement, actual === null ? '--' : `${actual.toFixed(1)}%`);
    setText(idealElement, ideal === null ? '--' : `${ideal.toFixed(1)}%`);
    setAttribute(element, 'aria-label', t('weeklyPaceUnavailable'));
    removeAttribute(element, 'title');
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
  setText(actualElement, `${actual.toFixed(1)}%`);
  setText(idealElement, `${ideal.toFixed(1)}%`);
  setAttribute(element, 'aria-label', `${t('paceVsIdeal')}: ${element.textContent}. ${t('actualRemaining')}: ${actual.toFixed(1)}%. ${t('idealRemaining')}: ${ideal.toFixed(1)}%.`);
  removeAttribute(element, 'title');
  element.classList.add(pointDifference >= 0 ? 'ahead' : 'behind');
}

function quotaCriticality(pct) {
  if (pct === null) return { level: 'unavailable', label: localCopy('unavailable') };
  if (pct <= 10) return { level: 'critical', label: localCopy('critical') };
  if (pct <= 25) return { level: 'attention', label: localCopy('attention') };
  return { level: 'normal', label: localCopy('normal') };
}

function setBar(barId, pctId, pct) {
  const safePct = validPct(pct);
  const bar = document.getElementById(barId);
  const value = document.getElementById(pctId);
  const stateIds = barId === 'five-h-bar'
    ? { availability: 'five-h-availability', criticality: 'five-h-criticality', label: 'fiveHourLimit' }
    : { availability: 'weekly-availability', criticality: 'weekly-criticality', label: 'weeklyLimit' };
  const availability = document.getElementById(stateIds.availability);
  const criticality = document.getElementById(stateIds.criticality);
  const status = quotaCriticality(safePct);
  bar.value = safePct ?? 0;
  value.textContent = safePct === null ? '--' : `${safePct}%`;
  value.classList.toggle('unavailable', safePct === null);
  setAttribute(bar, 'aria-label', t(stateIds.label));
  setAttribute(bar, 'aria-valuenow', safePct ?? 0);
  setAttribute(bar, 'aria-valuetext', safePct === null ? localCopy('unavailable') : `${safePct}%`);
  setText(availability, `${localCopy('availability')}: ${safePct === null ? localCopy('unavailable') : localCopy('available')}`);
  setDataAttribute(availability, 'available', safePct !== null);
  setText(criticality, `${localCopy('criticality')}: ${status.label}`);
  setDataAttribute(criticality, 'level', status.level);
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

function historyPercentage(value) {
  return value === null ? localCopy('noValue') : `${value.toFixed(1)}%`;
}

function historySummary(points) {
  const latest = points[points.length - 1];
  const ideal = idealWeeklyRemaining(latest.timestamp, latest.weeklyReset);
  return localCopy('historySummary', {
    count: points.length,
    from: formatParisDateTime(points[0].timestamp),
    to: formatParisDateTime(latest.timestamp),
    fiveHour: historyPercentage(latest.fiveHour),
    weekly: historyPercentage(latest.weekly),
    ideal: historyPercentage(ideal),
  });
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function setHistoryTableVisibility(visible) {
  const wrap = document.getElementById('history-table-wrap');
  const toggle = document.getElementById('history-table-toggle');
  if (!wrap || !toggle) return;
  wrap.hidden = !visible;
  toggle.textContent = visible ? localCopy('hideHistoryTable') : localCopy('showHistoryTable');
  setAttribute(toggle, 'aria-expanded', visible);
}

function clearHistoryTable() {
  const body = document.getElementById('history-table-body');
  const toggle = document.getElementById('history-table-toggle');
  if (body) body.innerHTML = '';
  if (toggle) toggle.disabled = true;
  setHistoryTableVisibility(false);
}

function renderHistoryTable(points) {
  const body = document.getElementById('history-table-body');
  const caption = document.getElementById('history-table-caption');
  const sampleHeading = document.getElementById('history-sample-heading');
  const toggle = document.getElementById('history-table-toggle');
  const wrap = document.getElementById('history-table-wrap');
  if (!body || !caption || !sampleHeading || !toggle || !wrap) return;
  const wasVisible = !wrap.hidden;
  caption.textContent = localCopy('historyData');
  sampleHeading.textContent = localCopy('sampleTime');
  body.innerHTML = points.map(point => {
    const ideal = idealWeeklyRemaining(point.timestamp, point.weeklyReset);
    return `<tr><th scope="row">${escapeHtml(formatParisDateTime(point.timestamp))}</th><td>${escapeHtml(historyPercentage(point.fiveHour))}</td><td>${escapeHtml(historyPercentage(point.weekly))}</td><td>${escapeHtml(historyPercentage(ideal))}</td></tr>`;
  }).join('');
  toggle.disabled = false;
  setHistoryTableVisibility(wasVisible);
}

function bindHistoryTableControls() {
  if (historyTableBound) return;
  const toggle = document.getElementById('history-table-toggle');
  if (!toggle || typeof toggle.addEventListener !== 'function') return;
  historyTableBound = true;
  toggle.addEventListener('click', () => {
    setHistoryTableVisibility(document.getElementById('history-table-wrap').hidden);
  });
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
  setText(document.getElementById('history-summary'), historySummary(points));
  renderHistoryTable(points);

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

  try {
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
  } catch (error) {
    chart = null;
    historyFailure = error instanceof Error ? error.message : t('chartFailed');
    setHistoryTableVisibility(true);
    setHistoryError(historyFailure);
  }
}

function renderHistoryFailure(message) {
  historyFailure = message;
  dashboardHistory = null;
  destroyChart();
  setText(document.getElementById('history-summary'), t('historyUnavailable'));
  clearHistoryTable();
  setHistoryError(message);
}

function renderData(data, { schedule = true, clearError = true } = {}) {
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    throw new Error(t('invalidDashboardData'));
  }
  const hadFailure = Boolean(mainFailure);
  dashboardData = data;
  setBar('five-h-bar', 'five-h-pct', data.five_h_pct);
  setBar('weekly-bar', 'weekly-pct', data.weekly_pct);
  document.getElementById('five-h-reset').textContent = formatParisUnixTimestamp(data.five_h_reset_at);
  document.getElementById('weekly-reset').textContent = formatParisUnixTimestamp(data.weekly_reset_at);
  renderWeeklyPaceDelta(data);
  document.getElementById('last-updated').textContent = t('lastScraped', {
    value: formatParisDateTime(displayText(data.scraped_at, '')),
  });
  if (clearError) setMainError();
  const info = freshnessInfo(data);
  updateFreshnessAge(info);
  setFreshnessState(!clearError && hadFailure ? 'error' : info.state, { info });
  scheduleFreshnessCheck(data);
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
    if (!dashboardMode) dashboardMode = GIST_ID ? 'external' : 'local';
    document.getElementById('mode-badge').textContent = t(dashboardMode);
    if (dashboardData) updateFreshnessAge(freshnessInfo(dashboardData));
    setFreshnessState('error', { info: dashboardData ? freshnessInfo(dashboardData) : null });
    scheduleRefresh(dashboardData);
  }
}

function refreshLocalizedDashboard() {
  if (dashboardMode) document.getElementById('mode-badge').textContent = t(dashboardMode);
  if (dashboardData) renderData(dashboardData, { schedule: false, clearError: false });
  else if (mainFailure) setMainError(mainFailure);
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

bindHistoryTableControls();
if (typeof CodexPreferences === 'object') CodexPreferences.subscribe(refreshLocalizedDashboard);
refresh();
