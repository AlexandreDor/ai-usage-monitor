'use strict';

// Shared, client-only preferences for both dashboard pages.
(function initialisePreferences(root) {
  const STORAGE_KEY = 'codex-usage-monitor.preferences';
  const USD_TO_EUR_RATE = 0.86;
  const DEFAULTS = Object.freeze({ language: 'en', currency: 'EUR' });
  const LANGUAGE_LOCALES = Object.freeze({ en: 'en-GB', fr: 'fr-FR' });
  const CURRENCIES = Object.freeze({ EUR: 'EUR', USD: 'USD' });
  const translations = {
    en: {
      preferences: {
        ariaLabel: 'Display preferences',
        language: 'Language',
        currency: 'Currency',
        euro: '€ Euro',
        dollar: '$ US dollar',
      },
      languages: { en: 'English', fr: 'Français' },
      currencies: { EUR: '€ EUR', USD: '$ USD' },
      dashboard: {
        pageTitle: 'Codex Usage Monitor',
        description: 'Live dashboard for OpenAI Codex CLI usage limits',
        heading: 'Codex Limits',
        navigationAria: 'Dashboard navigation',
        analyticsLink: 'Advanced analytics',
        githubLink: 'GitHub repository',
        forecastAria: 'Global reset forecast from a third-party service',
        globalResetForecast: 'Global reset forecast',
        thirdParty: 'Third-party',
        chance24h: '24h chance',
        chance6h: '6h chance',
        forecastUpdated: 'Forecast updated {value}',
        forecastUnavailable: 'Forecast unavailable',
        local: 'LOCAL',
        external: 'EXTERNAL',
        error: 'ERROR',
        fiveHourLimit: '5-Hour Limit',
        weeklyLimit: 'Weekly Limit',
        resetsAt: 'Resets at',
        resets: 'Resets',
        paceVsIdeal: 'Pace vs ideal',
        history: 'History',
        historyUnavailable: 'History unavailable',
        historyTitleSingle: 'History / {start}',
        historyTitleRange: 'History / {start} - {end}',
        warningPrefix: 'Warning',
        warningFallback: 'Unable to load dashboard data',
        chartPrefix: 'Chart',
        chartFallback: 'Unable to render history',
        weeklyPaceUnavailable: 'Weekly pace unavailable',
        onPace: 'on pace',
        above: 'above',
        below: 'below',
        actualRemaining: 'Actual remaining',
        idealRemaining: 'Ideal remaining',
        points: 'pts',
        lastScraped: 'Last scraped {value}',
        fiveHourDataset: '5h Limit %',
        weeklyDataset: 'Weekly Limit %',
        idealDataset: 'Ideal weekly pace',
        dataNotFound: 'data.json not found; run monitor.sh first',
        historyNotFound: 'history.json not found',
        invalidDashboardData: 'Invalid dashboard data',
        invalidHistory: 'history.json is not an array',
        historyEmpty: 'History is empty',
        historyNoValidSamples: 'History contains no valid samples',
        chartFailed: 'Chart.js failed to load',
        unableToLoadHistory: 'Unable to load history',
        githubApiError: 'GitHub API returned HTTP {status}; check GIST_ID',
        gistDataNotFound: 'data.json not found in Gist',
        gistHistoryNotFound: 'history.json not found in Gist',
        unableToLoadData: 'Unable to load dashboard data',
      },
      analytics: {
        pageTitle: 'Advanced Analytics · Codex Usage Monitor',
        description: 'Long-term limits, reset history, local token usage and API-equivalent cost estimates',
        backToLive: 'Live limits',
        eyebrow: 'Local intelligence',
        heading: 'Advanced Analytics',
        intro: 'Long-range limits, token consumption and API-equivalent cost—kept on this machine.',
        filtersAria: 'Analytics filters',
        dateRange: 'Date range',
        applications: 'Applications',
        models: 'Models',
        selectGpt: 'GPT 5.6',
        allModels: 'All models',
        from: 'From',
        to: 'To',
        apply: 'Apply',
        all: 'All',
        custom: 'Custom',
        metricSummaryAria: 'Period summary',
        freshness: 'Freshness',
        loading: 'Loading analytics…',
        localOnly: 'Advanced analytics are available in LOCAL mode only.',
        showingLastData: 'Showing the last successful data.',
        lastLimitSample: 'Last limit sample',
        noLimitSample: 'No limit sample available',
        dataAge: 'Age',
        lastAttempt: 'Last attempt',
        lastError: 'Last error',
        billableTokens: 'Billable tokens',
        billableTokensTitle: '{value} billable tokens',
        tokenDetail: 'Input, cache and output',
        uncachedInput: 'Uncached input',
        inputDescription: 'Input tokens excluding cache',
        cacheRead: 'Cache read',
        cacheReadDescription: 'Tokens read from cache',
        cacheWrite: 'Cache write',
        cacheWriteDescription: 'Tokens written to cache',
        outputDescription: 'Reasoning included',
        reasoning: 'Reasoning',
        reasoningDescription: 'Subset of output',
        assumedZero: 'Assumed-zero tokens',
        assumedZeroDescription: 'Models without a catalog price',
        apiCost: 'API-equivalent cost',
        points: 'pts',
        currentCatalogUsd: 'Current catalog · USD',
        randomWeeklyResets: 'Random weekly resets',
        randomImpactHint: 'Gain/loss versus ideal weekly pace',
        weeklyResets: 'Weekly resets',
        weeklyResetBreakdown: '{random} random · {regular} end of week',
        randomResets: 'Random resets',
        randomResetImpact: '{gained} gained · {lost} lost',
        endWeekResets: 'End-of-week resets',
        endWeekImpactHint: 'Unused quota lost at reset',
        selectedPeriod: 'Selected period',
        granularityUnknown: '—',
        codexLimits: 'Codex limits',
        longTermAvailability: 'Long-term availability',
        overlayTokens: 'Overlay tokens',
        showTokensSeparately: 'Show tokens separately',
        showCost: 'Show cost',
        showTokens: 'Show tokens',
        localConsumption: 'Local consumption',
        tokensOverTime: 'Tokens over time',
        costAllocation: 'Cost allocation',
        byApplicationModel: 'By application and model',
        totalEstimatedCost: 'Total estimated cost',
        application: 'Application',
        allApplications: 'All applications',
        provider: 'Provider',
        model: 'Model',
        providerModel: 'Provider / model',
        input: 'Input',
        cache: 'Cache',
        cacheReadWrite: 'Cache read/write',
        output: 'Output',
        total: 'Total',
        pricingStatus: 'Pricing',
        estimatedCost: 'Est. cost',
        resetHistory: 'Reset history',
        previousLimitResets: 'Previous limit resets',
        window: 'Window',
        fiveHour: '5-hour',
        weekly: 'Weekly',
        category: 'Category',
        scheduledReset: 'Scheduled reset',
        firstObservation: 'First observation',
        beforeAfter: 'Before → after',
        impact: 'Impact',
        delay: 'Delay',
        date: 'Date',
        showLimitTable: 'Show limit data table',
        showTokenTable: 'Show token data table',
        limitTableCaption: 'Limit history data',
        tokenTableCaption: 'Token consumption data',
        breakdownCaption: 'Token and cost breakdown by application, provider and model',
        resetCaption: 'Detected limit resets',
        fiveHourResetMarkers: '5-hour reset markers',
        weeklyResetMarkers: 'Weekly reset markers',
        limitChartSummary: '{samples} limit samples from {from} to {to}; {resets} reset markers.',
        tokenChartSummary: '{events} token events across {applications} applications.',
        previous: 'Previous',
        next: 'Next',
        dataHealth: 'Data health',
        collectors: 'Collectors',
        costsFooter: 'Costs are estimates based on the current local pricing catalog. Request, tool and contract charges are excluded.',
        catalog: 'Catalog {date} · {currency}',
        catalogConverted: 'Catalog {date} · Fixed rate: 1 USD = €{rate}',
        currencyTooltip: 'Converted from USD using fixed rate: 1 USD = €{rate}',
        bucketsOf: 'Buckets of {value}',
        fiveHourRemaining: '5-hour remaining',
        weeklyRemaining: 'Weekly remaining',
        samples: '{value} samples',
        events: '{value} events',
        noLimitSamples: 'No limit samples in this period.',
        noTokenEvents: 'No token events in this period.',
        noModelConsumption: 'No model consumption to display.',
        noResetObserved: 'No reset observed in this period.',
        lastSuccess: 'Last success {value}',
        noSuccessfulCollection: 'No successful collection yet',
        hermesBaseline: 'Hermes pre-monitor baseline excluded from dated totals: {value} tokens.',
        random: 'Random',
        endOfWeek: 'End of week',
        scheduled: 'Scheduled',
        gain: 'Gain',
        loss: 'loss',
        vsIdealPace: 'vs ideal pace',
        unusedExpired: '{value}% unused expired',
        ofUnusedQuotaExpired: '{value} of unused quota expired',
        pageOf: '{from}–{to} of {total}',
        gptModelsUnavailable: 'No GPT 5.6 Sol, Terra, or Luna model is available in this archive.',
        chooseBothDates: 'Choose both custom dates.',
        chartFailed: 'Chart.js failed to load',
        unableToLoadAnalytics: 'Unable to load analytics',
        sourcePriceUnknown: 'No catalog price; assumed zero: {name}',
        collectorWarning: '{name} collector: {message}',
        pricingUnknownTitle: 'Model absent from pricing catalog; assumed zero',
      },
    },
    fr: {
      preferences: {
        ariaLabel: "Préférences d'affichage",
        language: 'Langue',
        currency: 'Monnaie',
        euro: '€ Euro',
        dollar: '$ Dollar américain',
      },
      languages: { en: 'English', fr: 'Français' },
      currencies: { EUR: '€ EUR', USD: '$ USD' },
      dashboard: {
        pageTitle: 'Moniteur d’utilisation Codex',
        description: 'Tableau de bord en direct des limites d’utilisation de la CLI OpenAI Codex',
        heading: 'Limites Codex',
        navigationAria: 'Navigation du tableau de bord',
        analyticsLink: 'Analytics avancées',
        githubLink: 'Dépôt GitHub',
        forecastAria: 'Prévision globale des réinitialisations fournie par un service tiers',
        globalResetForecast: 'Prévision globale des resets',
        thirdParty: 'Service tiers',
        chance24h: 'Chance sur 24 h',
        chance6h: 'Chance sur 6 h',
        forecastUpdated: 'Prévision actualisée le {value}',
        forecastUnavailable: 'Prévision indisponible',
        local: 'LOCAL',
        external: 'EXTERNE',
        error: 'ERREUR',
        fiveHourLimit: 'Limite sur 5 heures',
        weeklyLimit: 'Limite hebdomadaire',
        resetsAt: 'Réinitialisation à',
        resets: 'Réinitialisation',
        paceVsIdeal: 'Rythme vs idéal',
        history: 'Historique',
        historyUnavailable: 'Historique indisponible',
        historyTitleSingle: 'Historique / {start}',
        historyTitleRange: 'Historique / {start} - {end}',
        warningPrefix: 'Avertissement',
        warningFallback: 'Impossible de charger les données du tableau de bord',
        chartPrefix: 'Graphique',
        chartFallback: 'Impossible d’afficher l’historique',
        weeklyPaceUnavailable: 'Rythme hebdomadaire indisponible',
        onPace: 'dans le rythme',
        above: 'au-dessus',
        below: 'en dessous',
        actualRemaining: 'Restant réel',
        idealRemaining: 'Restant idéal',
        points: 'pts',
        lastScraped: 'Dernière collecte : {value}',
        fiveHourDataset: 'Limite 5 h %',
        weeklyDataset: 'Limite hebdomadaire %',
        idealDataset: 'Rythme hebdomadaire idéal',
        dataNotFound: 'data.json introuvable ; lancez monitor.sh d’abord',
        historyNotFound: 'history.json introuvable',
        invalidDashboardData: 'Données du tableau de bord invalides',
        invalidHistory: 'history.json n’est pas un tableau',
        historyEmpty: 'L’historique est vide',
        historyNoValidSamples: 'L’historique ne contient aucun échantillon valide',
        chartFailed: 'Chart.js n’a pas pu être chargé',
        unableToLoadHistory: 'Impossible de charger l’historique',
        githubApiError: 'L’API GitHub a renvoyé HTTP {status} ; vérifiez GIST_ID',
        gistDataNotFound: 'data.json est absent du Gist',
        gistHistoryNotFound: 'history.json est absent du Gist',
        unableToLoadData: 'Impossible de charger les données du tableau de bord',
      },
      analytics: {
        pageTitle: 'Analytics avancées · Moniteur d’utilisation Codex',
        description: 'Limites à long terme, historique des réinitialisations, usage local des tokens et estimation du coût équivalent API',
        backToLive: 'Limites en direct',
        eyebrow: 'Intelligence locale',
        heading: 'Analytics avancées',
        intro: 'Limites à long terme, consommation de tokens et coût équivalent API — conservés sur cette machine.',
        filtersAria: 'Filtres des analytics',
        dateRange: 'Période',
        applications: 'Applications',
        models: 'Modèles',
        selectGpt: 'GPT 5.6',
        allModels: 'Tous les modèles',
        from: 'Du',
        to: 'Au',
        apply: 'Appliquer',
        all: 'Tout',
        custom: 'Personnalisée',
        metricSummaryAria: 'Résumé de la période',
        freshness: 'Fraîcheur',
        loading: 'Chargement des analytics…',
        localOnly: 'Les analytics avancées sont disponibles uniquement en mode LOCAL.',
        showingLastData: 'Dernières données valides affichées.',
        lastLimitSample: 'Dernier relevé de limite',
        noLimitSample: 'Aucun relevé de limite disponible',
        dataAge: 'Âge',
        lastAttempt: 'Dernière tentative',
        lastError: 'Dernière erreur',
        billableTokens: 'Tokens facturables',
        billableTokensTitle: '{value} tokens facturables',
        tokenDetail: 'Entrée, cache et sortie',
        uncachedInput: 'Entrée non mise en cache',
        inputDescription: 'Tokens d’entrée hors cache',
        cacheRead: 'Lecture cache',
        cacheReadDescription: 'Tokens lus depuis le cache',
        cacheWrite: 'Écriture cache',
        cacheWriteDescription: 'Tokens écrits dans le cache',
        outputDescription: 'Raisonnement inclus',
        reasoning: 'Raisonnement',
        reasoningDescription: 'Sous-ensemble de la sortie',
        assumedZero: 'Tokens supposés nuls',
        assumedZeroDescription: 'Modèles sans prix catalogue',
        apiCost: 'Coût équivalent API',
        points: 'pts',
        currentCatalogUsd: 'Catalogue actuel · USD',
        randomWeeklyResets: 'Réinitialisations hebdomadaires aléatoires',
        randomImpactHint: 'Gain/perte par rapport au rythme hebdomadaire idéal',
        weeklyResets: 'Réinitialisations hebdomadaires',
        weeklyResetBreakdown: '{random} aléatoire · {regular} fin de semaine',
        randomResets: 'Réinitialisations aléatoires',
        randomResetImpact: '{gained} gagnés · {lost} perdus',
        endWeekResets: 'Réinitialisations de fin de semaine',
        endWeekImpactHint: 'Quota inutilisé perdu à la réinitialisation',
        selectedPeriod: 'Période sélectionnée',
        granularityUnknown: '—',
        codexLimits: 'Limites Codex',
        longTermAvailability: 'Disponibilité à long terme',
        overlayTokens: 'Superposer les tokens',
        showTokensSeparately: 'Afficher les tokens séparément',
        showCost: 'Afficher le coût',
        showTokens: 'Afficher les tokens',
        localConsumption: 'Consommation locale',
        tokensOverTime: 'Tokens au fil du temps',
        costAllocation: 'Répartition des coûts',
        byApplicationModel: 'Par application et modèle',
        totalEstimatedCost: 'Coût total estimé',
        application: 'Application',
        allApplications: 'Toutes les applications',
        provider: 'Fournisseur',
        model: 'Modèle',
        providerModel: 'Fournisseur / modèle',
        input: 'Entrée',
        cache: 'Cache',
        cacheReadWrite: 'Lecture/écriture cache',
        output: 'Sortie',
        total: 'Total',
        pricingStatus: 'Tarification',
        estimatedCost: 'Coût estimé',
        resetHistory: 'Historique des réinitialisations',
        previousLimitResets: 'Réinitialisations précédentes',
        window: 'Fenêtre',
        fiveHour: '5 heures',
        weekly: 'Hebdomadaire',
        category: 'Catégorie',
        scheduledReset: 'Réinitialisation prévue',
        firstObservation: 'Première observation',
        beforeAfter: 'Avant → après',
        impact: 'Impact',
        delay: 'Délai',
        date: 'Date',
        showLimitTable: 'Afficher le tableau des limites',
        showTokenTable: 'Afficher le tableau des tokens',
        limitTableCaption: 'Données historiques des limites',
        tokenTableCaption: 'Données de consommation des tokens',
        breakdownCaption: 'Répartition des tokens et coûts par application, fournisseur et modèle',
        resetCaption: 'Réinitialisations de limites détectées',
        fiveHourResetMarkers: 'Marqueurs de réinitialisation 5 h',
        weeklyResetMarkers: 'Marqueurs de réinitialisation hebdomadaire',
        limitChartSummary: '{samples} relevés de limite du {from} au {to} ; {resets} marqueurs de réinitialisation.',
        tokenChartSummary: '{events} événements de tokens sur {applications} applications.',
        previous: 'Précédente',
        next: 'Suivante',
        dataHealth: 'État des données',
        collectors: 'Collecteurs',
        costsFooter: 'Les coûts sont des estimations basées sur le catalogue local actuel. Les frais de requête, d’outils et de contrat sont exclus.',
        catalog: 'Catalogue {date} · {currency}',
        catalogConverted: 'Catalogue {date} · Taux fixe : 1 USD = {rate} €',
        currencyTooltip: 'Converti depuis USD avec le taux fixe : 1 USD = {rate} €',
        bucketsOf: 'Périodes de {value}',
        fiveHourRemaining: 'Restant sur 5 heures',
        weeklyRemaining: 'Restant hebdomadaire',
        samples: '{value} échantillons',
        events: '{value} événements',
        noLimitSamples: 'Aucun échantillon de limite sur cette période.',
        noTokenEvents: 'Aucun événement de token sur cette période.',
        noModelConsumption: 'Aucune consommation de modèle à afficher.',
        noResetObserved: 'Aucune réinitialisation observée sur cette période.',
        lastSuccess: 'Dernière réussite : {value}',
        noSuccessfulCollection: 'Aucune collecte réussie pour le moment',
        hermesBaseline: 'Baseline Hermes avant surveillance exclue des totaux datés : {value} tokens.',
        random: 'Aléatoire',
        endOfWeek: 'Fin de semaine',
        scheduled: 'Prévue',
        gain: 'Gain',
        loss: 'perte',
        vsIdealPace: 'vs rythme idéal',
        unusedExpired: '{value}% inutilisés expirés',
        ofUnusedQuotaExpired: '{value} du quota inutilisé a expiré',
        pageOf: '{from}–{to} sur {total}',
        gptModelsUnavailable: 'Aucun modèle GPT 5.6 Sol, Terra ou Luna n’est disponible dans cette archive.',
        chooseBothDates: 'Choisissez les deux dates personnalisées.',
        chartFailed: 'Chart.js n’a pas pu être chargé',
        unableToLoadAnalytics: 'Impossible de charger les analytics',
        sourcePriceUnknown: 'Aucun prix catalogue ; valeur supposée nulle : {name}',
        collectorWarning: 'Collecteur {name} : {message}',
        pricingUnknownTitle: 'Modèle absent du catalogue tarifaire ; valeur supposée nulle',
      },
    },
  };

  let preferences = { ...DEFAULTS };
  let initialised = false;
  const listeners = new Set();

  function storage() {
    try {
      return root.localStorage;
    } catch (_error) {
      return null;
    }
  }

  function normalize(value) {
    const candidate = value && typeof value === 'object' ? value : {};
    return {
      language: Object.prototype.hasOwnProperty.call(LANGUAGE_LOCALES, candidate.language)
        ? candidate.language
        : DEFAULTS.language,
      currency: Object.prototype.hasOwnProperty.call(CURRENCIES, candidate.currency)
        ? candidate.currency
        : DEFAULTS.currency,
    };
  }

  function load() {
    const store = storage();
    if (!store) return { ...DEFAULTS };
    try {
      return normalize(JSON.parse(store.getItem(STORAGE_KEY) || '{}'));
    } catch (_error) {
      return { ...DEFAULTS };
    }
  }

  function persist() {
    const store = storage();
    if (!store) return;
    try {
      store.setItem(STORAGE_KEY, JSON.stringify(preferences));
    } catch (_error) {
      // Private browsing and locked-down contexts may reject localStorage.
    }
  }

  function locale() {
    return LANGUAGE_LOCALES[preferences.language];
  }

  function numberLocale() {
    return preferences.language === 'fr' ? 'fr-FR' : 'en';
  }

  function lookup(key, language) {
    return key.split('.').reduce((value, part) => value && value[part], translations[language]);
  }

  function translate(key, values = {}) {
    const value = lookup(key, preferences.language) || lookup(key, DEFAULTS.language) || key;
    if (typeof value !== 'string') return key;
    return value.replace(/\{(\w+)\}/g, (_match, name) => values[name] === undefined ? `{${name}}` : String(values[name]));
  }

  function applyAttributeTranslations(documentRef) {
    const attributes = [
      ['data-i18n-aria-label', 'aria-label'],
      ['data-i18n-title', 'title'],
      ['data-i18n-placeholder', 'placeholder'],
      ['data-i18n-content', 'content'],
    ];
    for (const [source, target] of attributes) {
      for (const element of documentRef.querySelectorAll(`[${source}]`)) {
        element.setAttribute(target, translate(element.getAttribute(source)));
      }
    }
  }

  function preferenceValueLabel(setting, value) {
    if (setting === 'language') return translate(`languages.${value}`);
    if (setting === 'currency') return translate(`currencies.${value}`);
    return value;
  }

  function syncToggle(button) {
    const setting = button.getAttribute('data-preference-toggle');
    const selected = preferences[setting];
    const values = (button.getAttribute('data-preference-values') || '').split(',').filter(Boolean);
    button.dataset.selected = selected;
    button.setAttribute('aria-pressed', String(values.indexOf(selected) === 1));
    button.setAttribute('aria-label', `${translate(`preferences.${setting}`)}: ${preferenceValueLabel(setting, selected)}`);
  }

  function applyDocument() {
    const documentRef = root.document;
    if (!documentRef || typeof documentRef.querySelectorAll !== 'function') return;
    if (documentRef.documentElement) documentRef.documentElement.lang = preferences.language;
    for (const element of documentRef.querySelectorAll('[data-i18n]')) {
      element.textContent = translate(element.getAttribute('data-i18n'));
    }
    applyAttributeTranslations(documentRef);
    for (const select of documentRef.querySelectorAll('[data-preference-select]')) {
      const setting = select.getAttribute('data-preference-select');
      select.value = preferences[setting];
    }
    for (const button of documentRef.querySelectorAll('[data-preference-toggle]')) syncToggle(button);
  }

  function notify() {
    for (const listener of listeners) listener({ ...preferences });
  }

  function set(partial) {
    const next = normalize({ ...preferences, ...(partial || {}) });
    if (next.language === preferences.language && next.currency === preferences.currency) return;
    preferences = next;
    persist();
    applyDocument();
    notify();
  }

  function bindControls() {
    const documentRef = root.document;
    if (!documentRef || typeof documentRef.querySelectorAll !== 'function') return;
    for (const select of documentRef.querySelectorAll('[data-preference-select]')) {
      select.addEventListener('change', event => {
        const setting = event.currentTarget.getAttribute('data-preference-select');
        set({ [setting]: event.currentTarget.value });
      });
    }
    for (const button of documentRef.querySelectorAll('[data-preference-toggle]')) {
      button.addEventListener('click', event => {
        const setting = event.currentTarget.getAttribute('data-preference-toggle');
        const values = (event.currentTarget.getAttribute('data-preference-values') || '').split(',').filter(Boolean);
        if (values.length !== 2) return;
        set({ [setting]: preferences[setting] === values[0] ? values[1] : values[0] });
      });
    }
  }

  function initialiseDocument() {
    if (initialised) return;
    initialised = true;
    preferences = load();
    applyDocument();
    bindControls();
    if (typeof root.addEventListener === 'function') {
      root.addEventListener('storage', event => {
        if (event.key !== STORAGE_KEY) return;
        preferences = load();
        applyDocument();
        notify();
      });
    }
  }

  preferences = load();
  const api = {
    DEFAULTS,
    STORAGE_KEY,
    USD_TO_EUR_RATE,
    get: () => ({ ...preferences }),
    locale,
    numberLocale,
    t: translate,
    set,
    subscribe(listener) {
      if (typeof listener !== 'function') return () => {};
      listeners.add(listener);
      listener({ ...preferences });
      return () => listeners.delete(listener);
    },
    formatCurrency(value) {
      const usd = Number(value);
      if (!Number.isFinite(usd)) return '—';
      const amount = preferences.currency === 'EUR' ? usd * USD_TO_EUR_RATE : usd;
      const fractionDigits = Math.abs(amount) < 1 ? 4 : 2;
      return new Intl.NumberFormat(locale(), {
        style: 'currency',
        currency: preferences.currency,
        currencyDisplay: 'narrowSymbol',
        minimumFractionDigits: fractionDigits,
        maximumFractionDigits: fractionDigits,
      }).format(amount);
    },
    formatRate() {
      return new Intl.NumberFormat(numberLocale(), { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(USD_TO_EUR_RATE);
    },
  };
  root.CodexPreferences = api;
  initialiseDocument();
})(typeof globalThis !== 'undefined' ? globalThis : window);
