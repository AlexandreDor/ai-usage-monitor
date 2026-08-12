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
if (JSON.stringify(defaults.CodexPreferences.get()) !== JSON.stringify({ language: 'en', currency: 'EUR' })) {
  fail('default preferences are incorrect');
}
if (defaults.CodexPreferences.formatCurrency(11.25) !== '€9.68') fail('default EUR formatting is incorrect');
if (defaults.CodexPreferences.formatRate() !== '0.86') fail('conversion rate formatting is incorrect');
if (defaults.CodexPreferences.t('analytics.showCost') !== 'Show cost') fail('analytics cost toggle translation is missing');
if (defaults.CodexPreferences.t('dashboard.globalResetForecast') !== 'Global reset forecast') fail('dashboard forecast translation is missing');
if (defaults.CodexPreferences.t('analytics.randomResets') !== 'Random resets') fail('random reset translation is missing');
if (!defaults.CodexPreferences.t('analytics.randomResetImpact', { gained: '1 pt', lost: '2 pts' }).includes('ideal pace')) fail('random reset impact does not mention ideal pace');
if (defaults.CodexPreferences.t('analytics.uncachedInput') !== 'Uncached input') fail('analytics metric translation is missing');
if (defaults.CodexPreferences.t('analytics.tokenValue', { value: '1,000' }) !== '1,000 tokens') fail('analytics token tooltip translation is missing');

defaults.CodexPreferences.set({ language: 'fr', currency: 'USD' });
if (defaults.CodexPreferences.formatCurrency(11.25) !== '11,25 $') fail('French USD formatting is incorrect');
if (defaults.CodexPreferences.get().language !== 'fr') fail('language preference was not saved in memory');
if (defaults.CodexPreferences.t('analytics.showCost') !== 'Afficher le coût') fail('French analytics cost toggle translation is missing');
if (defaults.CodexPreferences.t('dashboard.forecastUnavailable') !== 'Prévision indisponible') fail('French dashboard forecast translation is missing');
if (defaults.CodexPreferences.t('analytics.randomResets') !== 'Réinitialisations aléatoires') fail('French random reset translation is missing');
if (!defaults.CodexPreferences.t('analytics.randomResetImpact', { gained: '1 pt', lost: '2 pts' }).includes('rythme idéal')) fail('French random reset impact does not mention ideal pace');
if (defaults.CodexPreferences.t('analytics.freshness') !== 'Fraîcheur') fail('French analytics freshness translation is missing');
if (defaults.CodexPreferences.t('analytics.tokenValue', { value: '1 000' }) !== '1 000 tokens') fail('French analytics token tooltip translation is missing');

const invalid = createContext('{not-json');
if (JSON.stringify(invalid.CodexPreferences.get()) !== JSON.stringify({ language: 'en', currency: 'EUR' })) {
  fail('invalid stored preferences did not fall back to defaults');
}

console.log('PASS: preference tests');
