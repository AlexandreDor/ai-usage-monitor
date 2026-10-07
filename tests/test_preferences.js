'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

function fail(message) {
  throw new Error(message);
}

function createContext(initialValue = null) {
  const values = new Map();
  if (initialValue !== null) values.set('codex-usage-monitor.preferences', initialValue);
  const context = vm.createContext({
    Intl,
    localStorage: {
      getItem: key => values.get(key) || null,
      setItem: (key, value) => values.set(key, value),
    },
  });
  const source = fs.readFileSync(path.join(__dirname, '..', 'local', 'assets', 'preferences.js'), 'utf8');
  vm.runInContext(source, context, { filename: 'preferences.js' });
  return context;
}

const defaults = createContext();
if (JSON.stringify(defaults.CodexPreferences.get()) !== JSON.stringify({ language: 'en', currency: 'EUR', timezone: 'Europe/Paris', usdToEurRate: 0.86, rateDate: '' })) {
  fail('default preferences are incorrect');
}
if (defaults.CodexPreferences.formatCurrency(11.25) !== '€9.68') fail('default EUR formatting is incorrect');
if (defaults.CodexPreferences.formatRate() !== '0.86') fail('conversion rate formatting is incorrect');
if (defaults.CodexPreferences.t('analytics.showCost') !== 'Show cost') fail('analytics cost toggle translation is missing');
if (defaults.CodexPreferences.t('dashboard.globalResetForecast') !== 'Global reset forecast') fail('dashboard forecast translation is missing');
if (defaults.CodexPreferences.t('dashboard.stale') !== 'STALE') fail('dashboard freshness translation is missing');
if (defaults.CodexPreferences.t('dashboard.dataAge', { age: '1 min' }) !== '1 min') fail('dashboard freshness duration contains an extra label');
if (defaults.CodexPreferences.t('dashboard.staleDataAge', { age: '5 min', overdue: '1 min' }).includes('—')) fail('dashboard stale summary contains an em dash');
const paceDelta = defaults.CodexPreferences.t('dashboard.paceDelta', { sign: '+', value: '1.0', relative: '2.5', direction: 'above' });
const paceDeltaPoints = defaults.CodexPreferences.t('dashboard.paceDeltaPoints', { sign: '+', value: '1.0', direction: 'above' });
if (paceDelta !== '+1.0 pts / 2.5% above' || paceDelta.includes(';')) fail('English pace delta separator is incorrect');
if (paceDeltaPoints !== '+1.0 pts / above' || paceDeltaPoints.includes(';')) fail('English points-only pace delta separator is incorrect');
if (defaults.CodexPreferences.t('analytics.granularityUnknown') !== '-') fail('analytics missing-value placeholder is incorrect');
if (defaults.CodexPreferences.formatCurrency('invalid') !== '-') fail('invalid currency placeholder is incorrect');
if (!defaults.CodexPreferences.t('dashboard.refreshFailedWithData', { message: 'HTTP 503' }).includes('last valid data')) fail('dashboard refresh error translation is missing');
if (defaults.CodexPreferences.t('analytics.randomResets') !== 'Random resets') fail('random reset translation is missing');
if (!defaults.CodexPreferences.t('analytics.randomResetImpact', { gained: '1 pt', lost: '2 pts' }).includes('ideal pace')) fail('random reset impact does not mention ideal pace');
if (defaults.CodexPreferences.t('analytics.uncachedInput') !== 'Uncached input') fail('analytics metric translation is missing');
if (defaults.CodexPreferences.t('analytics.tokenValue', { value: '1,000' }) !== '1,000 tokens') fail('analytics token tooltip translation is missing');
if (defaults.CodexPreferences.t('analytics.idealWeeklyPace') !== 'Ideal weekly pace') fail('ideal weekly pace translation is missing');
if (defaults.CodexPreferences.t('analytics.breakdownPaginationAria') !== 'Model breakdown pagination') fail('breakdown pagination translation is missing');

defaults.CodexPreferences.set({ language: 'fr', currency: 'USD' });
if (defaults.CodexPreferences.formatCurrency(11.25) !== '11,25 $') fail('French USD formatting is incorrect');
if (defaults.CodexPreferences.get().language !== 'fr') fail('language preference was not saved in memory');
if (defaults.CodexPreferences.t('analytics.showCost') !== 'Afficher le coût') fail('French analytics cost toggle translation is missing');
if (defaults.CodexPreferences.t('dashboard.forecastUnavailable') !== 'Prévision indisponible') fail('French dashboard forecast translation is missing');
if (defaults.CodexPreferences.t('dashboard.stale') !== 'PÉRIMÉ') fail('French dashboard freshness translation is missing');
if (defaults.CodexPreferences.t('dashboard.dataAge', { age: '1 min' }) !== '1 min') fail('French dashboard freshness duration contains an extra label');
if (!defaults.CodexPreferences.t('dashboard.staleDataAge', { age: '5 min', overdue: '1 min' }).includes('retard')) fail('French dashboard stale summary translation is missing');
const frenchPaceDelta = defaults.CodexPreferences.t('dashboard.paceDelta', { sign: '+', value: '1,0', relative: '2,5', direction: 'au-dessus' });
const frenchPaceDeltaPoints = defaults.CodexPreferences.t('dashboard.paceDeltaPoints', { sign: '+', value: '1,0', direction: 'au-dessus' });
if (frenchPaceDelta !== '+1,0 pts / 2,5 % au-dessus' || frenchPaceDelta.includes(';')) fail('French pace delta separator is incorrect');
if (frenchPaceDeltaPoints !== '+1,0 pts / au-dessus' || frenchPaceDeltaPoints.includes(';')) fail('French points-only pace delta separator is incorrect');
if (defaults.CodexPreferences.t('analytics.randomResets') !== 'Réinitialisations aléatoires') fail('French random reset translation is missing');
if (!defaults.CodexPreferences.t('analytics.randomResetImpact', { gained: '1 pt', lost: '2 pts' }).includes('rythme idéal')) fail('French random reset impact does not mention ideal pace');
if (defaults.CodexPreferences.t('analytics.freshness') !== 'Fraîcheur') fail('French analytics freshness translation is missing');
if (defaults.CodexPreferences.t('analytics.tokenValue', { value: '1 000' }) !== '1 000 tokens') fail('French analytics token tooltip translation is missing');
if (defaults.CodexPreferences.t('analytics.idealWeeklyPace') !== 'Rythme hebdomadaire idéal') fail('French ideal weekly pace translation is missing');
if (defaults.CodexPreferences.t('analytics.breakdownPaginationAria') !== 'Pagination de la ventilation par modèle') fail('French breakdown pagination translation is missing');

const invalid = createContext('{not-json');
if (JSON.stringify(invalid.CodexPreferences.get()) !== JSON.stringify({ language: 'en', currency: 'EUR', timezone: 'Europe/Paris', usdToEurRate: 0.86, rateDate: '' })) {
  fail('invalid stored preferences did not fall back to defaults');
}

const api = defaults.CodexPreferences;
const first = api.numberFormatter({ maximumFractionDigits: 2 });
if (first !== api.numberFormatter({ maximumFractionDigits: 2 })) fail('number formatter was not reused');
const dateFirst = api.dateFormatter({ year: 'numeric' });
if (dateFirst !== api.dateFormatter({ year: 'numeric' })) fail('date formatter was not reused');
api.set({ language: 'en', currency: 'EUR', timezone: 'UTC', usdToEurRate: 0.9, rateDate: '2026-10-07' });
if (api.numberFormatter({ maximumFractionDigits: 2 }) === first) fail('locale switch reused the wrong number formatter');
if (api.dateFormatter({ year: 'numeric' }) === dateFirst) fail('timezone switch reused the wrong date formatter');
if (api.formatCurrency(10) !== '€9.00' || api.convertUsd(10) !== 9) fail('custom exchange rate was not applied');
if (api.timezone() !== 'UTC' || api.get().rateDate !== '2026-10-07') fail('custom timezone/rate date not saved');
api.set({ timezone: 'Invalid/Zone', usdToEurRate: -3, rateDate: '2026-02-31' });
if (api.timezone() !== 'Europe/Paris' || api.get().usdToEurRate !== 0.86 || api.get().rateDate !== '') fail('invalid preferences accepted');
for (const [input, expected] of [['PST', 'America/Los_Angeles'], ['utc', 'UTC'], ['europe/paris', 'Europe/Paris'], ['Etc/GMT-2', 'Etc/GMT-2']]) {
  api.set({ timezone: input });
  if (api.timezone() !== expected) fail(`timezone ${input} was not normalized to its IANA name`);
}
const storedAlias = createContext(JSON.stringify({ timezone: 'PST' }));
if (storedAlias.CodexPreferences.timezone() !== 'America/Los_Angeles') fail('stored alias was not normalized on load');
api.set({ timezone: '+02:00' });
if (api.timezone() !== 'Europe/Paris') fail('numeric UTC offset accepted as an IANA zone');
console.log('PASS: preference tests');
