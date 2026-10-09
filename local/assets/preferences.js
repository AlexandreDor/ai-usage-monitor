'use strict';

// Shared, client-only preferences for both dashboard pages.
(function initialisePreferences(root) {
  const STORAGE_KEY = 'codex-usage-monitor.preferences';
  const USD_TO_EUR_RATE = 0.86;
  const DEFAULTS = Object.freeze({ language: 'en', currency: 'EUR', timezone: 'Europe/Paris', usdToEurRate: USD_TO_EUR_RATE, rateDate: '' });
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
        advanced: 'Time and exchange rate', timezone: 'Time zone (IANA)', usdToEurRate: 'EUR per USD', rateDate: 'Rate date', invalidTimezone: 'Enter a valid IANA time zone.', invalidRate: 'Enter a positive exchange rate.', invalidDate: 'Enter a valid date.',
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
        forecastThresholdReached: 'Highlight threshold reached: {value}%',
        local: 'LOCAL',
        external: 'EXTERNAL',
        error: 'ERROR',
        fresh: 'FRESH',
        stale: 'STALE',
        dataUnavailable: 'Data unavailable',
        dataAge: '{age}',
        staleDataAge: '{age}; collection delayed by {overdue}',
        refreshFailedWithData: 'Refresh failed; showing the last valid data. {message}',
        refreshFailedWithoutData: 'Refresh failed; no valid data is available. {message}',
        lessThanMinute: 'less than a minute',
        durationMinutes: '{minutes} min',
        durationHours: '{hours} h',
        durationHoursMinutes: '{hours} h {minutes} min',
        durationDays: '{days} d',
        durationDaysHours: '{days} d {hours} h',
        fiveHourLimit: '5-Hour Limit',
        weeklyLimit: 'Weekly Limit',
        fiveHourQuotaLabel: '5-hour remaining quota',
        weeklyQuotaLabel: 'Weekly remaining quota',
        quotaRemaining: '{value} remaining',
        quotaUnavailable: 'Remaining quota unavailable',
        notAvailable: 'Unavailable',
        resetsAt: 'Resets at',
        resets: 'Resets',
        paceVsIdeal: 'Pace vs ideal',
        paceDelta: '{sign}{value} pts / {relative}% {direction}',
        paceDeltaPoints: '{sign}{value} pts / {direction}',
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
        points: 'pts',
        lastScraped: 'Last scraped {value}',
        fiveHourDataset: '5h Limit %',
        weeklyDataset: 'Weekly Limit %',
        idealDataset: 'Ideal weekly pace',
        forecast24hDataset: 'Forecast 24h',
        forecast6hDataset: 'Forecast 6h',
        dataNotFound: 'data.json not found; run monitor.sh first',
        historyNotFound: 'history.json not found',
        invalidDashboardData: 'Invalid dashboard data',
        unsupportedSchema: 'Unsupported snapshot schema version',
        invalidSnapshotSchema: 'Invalid snapshot schema version',
        invalidScrapedAt: 'Invalid or missing collection timestamp',
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
        navigationAria: 'Analytics navigation',
        backToLive: 'Live limits',
        githubLink: 'GitHub repository',
        eyebrow: 'Local intelligence',
        heading: 'Advanced Analytics',
        intro: 'Long-range limits, token consumption and API-equivalent cost, kept on this machine.',
        filtersAria: 'Analytics filters',
        dateRange: 'Date range',
        applications: 'Applications',
        models: 'Models',
        modelScope: 'Filter token usage and cost. Weekly value curves have their own selection.',
        hideModels: 'Collapse',
        showModels: 'Explore models',
        selectedModels: 'Selected models',
        searchModels: 'Search models',
        searchModelsPlaceholder: 'Search by model name…',
        modelFamilies: 'Model families',
        currentGpt: 'Current GPT',
        olderGpt: 'Other GPT',
        otherModels: 'Other models',
        addVisibleModels: 'Add visible',
        clearModelSelection: 'Clear selection',
        cancelModelChanges: 'Cancel changes',
        applyModelSelection: 'Apply selection',
        modelSelectionCount: '{selected} of {total} selected',
        modelResultsCount: '{count} models shown',
        modelNoResults: 'No matching models. Try another name or family.',
        modelNoAvailable: 'Models will appear here after usage is collected.',
        modelDraftPending: '{count} changes ready to apply.',
        modelDraftSaved: 'No pending selection changes.',
        modelDraftEmpty: 'Select at least one model to continue.',
        removeModel: 'Remove {model} from selection',
        selectGpt: 'GPT',
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
        apiCost: 'API-equivalent cost',
        points: 'pts',
        currentCatalogUsd: 'Current catalog · USD',
        randomWeeklyResets: 'Random weekly resets',
        randomImpactHint: 'Gain/loss versus ideal weekly pace',
        weeklyResets: 'Weekly resets',
        weeklyResetBreakdown: '{random} random · {regular} end of week',
        randomResets: 'Random resets',
        randomResetImpact: '{gained} gained · {lost} lost vs ideal pace',
        endWeekResets: 'End-of-week resets',
        endWeekImpactHint: 'Unused quota lost at reset',
        selectedPeriod: 'Selected period',
        granularityUnknown: '-',
        codexLimits: 'Codex limits',
        longTermAvailability: 'Long-term availability',
        weeklyValueModel: 'Curves to display',
        weeklyValueEstimate: 'Estimate',
        weeklyValueNoPoints: 'No estimate',
        weeklyValueAllModels: 'All models (aggregate)',
        weeklyValueModelDescription: 'Per-model values come from exclusive windows when available. Mixed usage may use a fit trained on adaptive non-overlapping intervals from the last 28 days. High-uncertainty estimates remain visible with cross markers and sensitivity ranges in the table. The last accepted value may be carried for up to 7 days across ordinary gaps and weekly resets.',
        weeklyValueReasonMixedModels: 'Window contains multiple models and could not be attributed safely.',
        weeklyValueInferred: 'Inferred from shared quota',
        weeklyValueInferredTitle: 'Historical no-intercept fit using {samples} prior non-overlapping windows. The quota drop is shared; the per-model value is inferred.',
        weeklyValueCarried: 'Carried from {date} ({quality})',
        weeklyValueCarriedTitle: '{method} estimate from {date}, {age} old. Current calculation unavailable: {reason}',
        weeklyValueCarriedDirect: 'Direct exclusive-window',
        weeklyValueCarriedInferred: 'Shared-quota inferred',
        weeklyValueUnknownProvider: 'unknown provider',
        weeklyValueMixedSampleCounts: '{samples} prior non-overlapping windows available; {minimum} required in this quota cycle.',
        weeklyValueReasonMixedInsufficient: 'Too few prior non-overlapping windows in this quota cycle.',
        weeklyValueReasonMixedFixedMix: 'Prior model costs do not vary independently enough for attribution.',
        weeklyValueReasonMixedIllConditioned: 'Prior model costs are too collinear for stable attribution.',
        weeklyValueReasonMixedPoorFit: 'Prior windows do not fit one stable model attribution.',
        weeklyValueReasonMixedNonPositive: 'The fitted model attribution is not positive.',
        weeklyValueReasonMixedUnstable: 'The fitted attribution is too sensitive to quota rounding.',
        weeklyValueReasonMixedTargetAbsent: 'This model was not used in the target window.',
        weeklyValueReasonMixedTargetMismatch: 'The held-out target window does not match the historical attribution.',
        weeklyLimitValueKicker: 'Weekly limit value',
        weeklyLimitValueTitle: 'Implicit weekly limit value',
        weeklyLimitValueWindow: 'Rolling window · 12 h · one point / 6 h · USD',
        weeklyLimitValueDescription: 'Aggregate values use a rolling twelve-hour window. Per-model mixed-usage values can use shorter measurable intervals and are inferred from the shared quota, not model-level quota observations. Hollow dashed points carry an earlier accepted estimate.',
        weeklyLimitValueQualityLegend: 'Quality: good · low confidence · high uncertainty · volatile. Sensitivity ranges assume a one-point error in each quota observation; they are not statistical confidence intervals. The table gives the sensitivity ranges.',
        showWeeklyLimitValueTable: 'Show weekly limit value table',
        weeklyLimitValueTableCaption: 'Implicit weekly limit value data',
        observedCostUsd: 'Observed cost ($)',
        quotaConsumed: 'Quota consumed',
        rawValueUsd: 'Raw value ($)',
        smoothedValueUsd: 'Smoothed value ($)',
        sensitivityRange: 'Sensitivity range',
        estimatedCycleCostUsd: 'Estimated cycle cost ($)',
        extrapolatedValueUsd: 'Extrapolated 100% value ($)',
        quality: 'Quality',
        explanation: 'Explanation',
        weeklyLimitValueSummary: '{valid} displayed estimates from {from} to {to}; {unavailable} unavailable points.',
        noWeeklyLimitValue: 'No comparable weekly limit value is available in this period.',
        weeklyValueCurrentUnavailable: 'Current estimate unavailable: the latest limit sample is stale.',
        weeklyValueAvailable: 'Comparable all-source window',
        weeklyValueUnavailable: 'Unavailable',
        weeklyValueDispersion: 'relative dispersion',
        weeklyValueQuality_good: 'Good',
        weeklyValueQuality_low_confidence: 'Low confidence',
        weeklyValueQuality_high_uncertainty: 'High uncertainty',
        weeklyValueQuality_volatile: 'Volatile',
        weeklyValueQuality_unavailable: 'Unavailable',
        weeklyValueSensitivityBounded: '{lower}–{upper} · 1-point quota-error sensitivity',
        weeklyValueSensitivityUnbounded: '{lower}–unbounded · 1-point quota-error sensitivity',
        weeklyValueSensitivityTitle: 'Coefficient {coefficient} ± {error} quota fraction per USD under the assumed one-point quota-error sensitivity.',
        weeklyValueUnbounded: 'unbounded',
        weeklyValueReasonAmbiguousLimit: 'Limit identity is ambiguous around the reset.',
        weeklyValueReasonDeadlineTransition: 'Weekly reset deadline changed in the window.',
        weeklyValueReasonIncompleteCycle: 'No previous reset gives a complete cycle.',
        weeklyValueReasonInsufficientDelta: 'Quota drop is below the 0.5-point signal threshold.',
        weeklyValueReasonInvalidEvent: 'A locally collected token event has invalid counters.',
        weeklyValueReasonInvalidQuota: 'Quota percentage is invalid.',
        weeklyValueReasonInvalidValue: 'The calculated value is not finite and positive.',
        weeklyValueReasonMissingDeadline: 'The weekly reset deadline is missing.',
        weeklyValueReasonMissingLimit: 'The quota limit identity is missing.',
        weeklyValueReasonLimitTransition: 'The limit identity changed during the comparison.',
        weeklyValueReasonMissingPrice: 'A locally collected model has no positive catalog price.',
        weeklyValueReasonNoCost: 'No positive API-equivalent cost was observed.',
        weeklyValueReasonNoEvents: 'No locally collected token events were observed.',
        weeklyValueReasonQuotaIncrease: 'Quota increased instead of being consumed.',
        weeklyValueReasonResetInWindow: 'A weekly reset occurred inside the window.',
        weeklyValueReasonFullyConsumed: 'Cycle was fully consumed; extrapolation is not applicable.',
        weeklyValueReasonWeeklyOnly: 'Cycle value applies only to weekly resets.',
        weeklyValueReasonStaleBoundary: 'Reset boundary is too far from the nearest limit samples.',
        weeklyValueReasonStaleData: 'The latest limit sample is stale for the current estimate.',
        weeklyValueReasonWindowDuration: 'No comparable window between 11 h 45 min and 12 h 15 min was found.',
        weeklyValueReasonZeroConsumed: 'No quota was consumed before this reset.',
        weeklyValueReasonZeroDelta: 'Quota did not decrease in the window.',
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
        tokenValue: '{value} tokens',
        resetHistory: 'Reset history',
        previousLimitResets: 'Previous limit resets',
        window: 'Window',
        fiveHour: '5-hour',
        weekly: 'Weekly',
        category: 'Category',
        scheduledReset: 'Scheduled reset',
        firstObservation: 'First observation',
        beforeAfter: 'Before → after',
        forecastBeforeReset: 'Forecast before reset',
        impact: 'Impact',
        delay: 'Delay',
        date: 'Date',
        showLimitTable: 'Show limit data table',
        showTokenTable: 'Show token data table',
        limitTableCaption: 'Limit history data',
        tokenTableCaption: 'Token consumption data',
        breakdownCaption: 'Token and cost breakdown by application, provider and model',
        breakdownPaginationAria: 'Model breakdown pagination',
        resetCaption: 'Detected limit resets',
        fiveHourResetMarkers: '5-hour reset markers',
        weeklyResetMarkers: 'Weekly reset markers',
        limitChartSummary: '{samples} limit samples and {forecasts} forecast samples from {from} to {to}; {resets} reset markers.',
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
        idealWeeklyPace: 'Ideal weekly pace',
        forecast24h: 'Forecast 24h',
        forecast6h: 'Forecast 6h',
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
        gptModelsUnavailable: 'No supported GPT model is available in this archive (GPT-6.1 Sol, GPT-6 Astra, Sol, Luna or GPT-5.6 Sol, Terra, Luna).',
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
        advanced: 'Heure et taux de change', timezone: 'Fuseau horaire (IANA)', usdToEurRate: 'EUR par USD', rateDate: 'Date du taux', invalidTimezone: 'Saisissez un fuseau horaire IANA valide.', invalidRate: 'Saisissez un taux de change positif.', invalidDate: 'Saisissez une date valide.',
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
        forecastThresholdReached: 'Seuil de mise en évidence atteint : {value} %',
        local: 'LOCAL',
        external: 'EXTERNE',
        error: 'ERREUR',
        fresh: 'À JOUR',
        stale: 'PÉRIMÉ',
        dataUnavailable: 'Données indisponibles',
        dataAge: '{age}',
        staleDataAge: '{age} ; collecte en retard de {overdue}',
        refreshFailedWithData: 'Échec du rafraîchissement ; dernières données valides affichées. {message}',
        refreshFailedWithoutData: 'Échec du rafraîchissement ; aucune donnée valide disponible. {message}',
        lessThanMinute: 'moins d’une minute',
        durationMinutes: '{minutes} min',
        durationHours: '{hours} h',
        durationHoursMinutes: '{hours} h {minutes} min',
        durationDays: '{days} j',
        durationDaysHours: '{days} j {hours} h',
        fiveHourLimit: 'Limite sur 5 heures',
        weeklyLimit: 'Limite hebdomadaire',
        fiveHourQuotaLabel: 'Quota restant sur 5 heures',
        weeklyQuotaLabel: 'Quota hebdomadaire restant',
        quotaRemaining: '{value} restant',
        quotaUnavailable: 'Quota restant indisponible',
        notAvailable: 'Indisponible',
        resetsAt: 'Réinitialisation à',
        resets: 'Réinitialisation',
        paceVsIdeal: 'Rythme vs idéal',
        paceDelta: '{sign}{value} pts / {relative} % {direction}',
        paceDeltaPoints: '{sign}{value} pts / {direction}',
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
        points: 'pts',
        lastScraped: 'Dernière collecte : {value}',
        fiveHourDataset: 'Limite 5 h %',
        weeklyDataset: 'Limite hebdomadaire %',
        idealDataset: 'Rythme hebdomadaire idéal',
        forecast24hDataset: 'Prévision 24 h',
        forecast6hDataset: 'Prévision 6 h',
        dataNotFound: 'data.json introuvable ; lancez monitor.sh d’abord',
        historyNotFound: 'history.json introuvable',
        invalidDashboardData: 'Données du tableau de bord invalides',
        unsupportedSchema: 'Version de schéma de snapshot non prise en charge',
        invalidSnapshotSchema: 'Version de schéma de snapshot invalide',
        invalidScrapedAt: 'Horodatage de collecte absent ou invalide',
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
        navigationAria: 'Navigation des analytics',
        backToLive: 'Limites en direct',
        githubLink: 'Dépôt GitHub',
        eyebrow: 'Intelligence locale',
        heading: 'Analytics avancées',
        intro: 'Limites à long terme, consommation de tokens et coût équivalent API, conservés sur cette machine.',
        filtersAria: 'Filtres des analytics',
        dateRange: 'Période',
        applications: 'Applications',
        models: 'Modèles',
        modelScope: 'Filtre les tokens et les coûts. Les courbes de valeur hebdomadaire ont leur propre sélection.',
        hideModels: 'Réduire',
        showModels: 'Explorer les modèles',
        selectedModels: 'Modèles sélectionnés',
        searchModels: 'Rechercher des modèles',
        searchModelsPlaceholder: 'Rechercher par nom de modèle…',
        modelFamilies: 'Familles de modèles',
        currentGpt: 'GPT actuels',
        olderGpt: 'Autres GPT',
        otherModels: 'Autres modèles',
        addVisibleModels: 'Ajouter les résultats',
        clearModelSelection: 'Vider la sélection',
        cancelModelChanges: 'Annuler les modifications',
        applyModelSelection: 'Appliquer la sélection',
        modelSelectionCount: '{selected} sélectionnés sur {total}',
        modelResultsCount: '{count} modèles affichés',
        modelNoResults: 'Aucun modèle trouvé. Essayez un autre nom ou une autre famille.',
        modelNoAvailable: 'Les modèles apparaîtront ici après la collecte de consommation.',
        modelDraftPending: '{count} modifications à appliquer.',
        modelDraftSaved: 'Aucune modification en attente.',
        modelDraftEmpty: 'Sélectionnez au moins un modèle pour continuer.',
        removeModel: 'Retirer {model} de la sélection',
        selectGpt: 'GPT',
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
        apiCost: 'Coût équivalent API',
        points: 'pts',
        currentCatalogUsd: 'Catalogue actuel · USD',
        randomWeeklyResets: 'Réinitialisations hebdomadaires aléatoires',
        randomImpactHint: 'Gain/perte par rapport au rythme hebdomadaire idéal',
        weeklyResets: 'Réinitialisations hebdomadaires',
        weeklyResetBreakdown: '{random} aléatoire · {regular} fin de semaine',
        randomResets: 'Réinitialisations aléatoires',
        randomResetImpact: '{gained} gagnés · {lost} perdus vs rythme idéal',
        endWeekResets: 'Réinitialisations de fin de semaine',
        endWeekImpactHint: 'Quota inutilisé perdu à la réinitialisation',
        selectedPeriod: 'Période sélectionnée',
        granularityUnknown: '-',
        codexLimits: 'Limites Codex',
        longTermAvailability: 'Disponibilité à long terme',
        weeklyValueModel: 'Courbes à afficher',
        weeklyValueEstimate: 'Estimation',
        weeklyValueNoPoints: 'Aucune estimation',
        weeklyValueAllModels: 'Tous les modèles (agrégat)',
        weeklyValueModelDescription: 'Les valeurs par modèle proviennent des fenêtres exclusives quand elles existent. Un usage mixte peut utiliser un ajustement entraîné sur des intervalles adaptatifs sans chevauchement des 28 derniers jours. Les estimations à forte incertitude restent visibles avec des marqueurs en croix et les plages de sensibilité dans le tableau. La dernière valeur acceptée peut être reportée jusqu’à 7 jours pendant les lacunes ordinaires et les resets hebdomadaires.',
        weeklyValueReasonMixedModels: 'La fenêtre contient plusieurs modèles et n’a pas pu être attribuée de façon fiable.',
        weeklyValueInferred: 'Inférée depuis le quota partagé',
        weeklyValueInferredTitle: 'Ajustement historique sans constante sur {samples} fenêtres antérieures sans chevauchement. La baisse de quota est partagée ; la valeur par modèle est inférée.',
        weeklyValueCarried: 'Reportée depuis le {date} ({quality})',
        weeklyValueCarriedTitle: 'Estimation {method} du {date}, âgée de {age}. Calcul actuel indisponible : {reason}',
        weeklyValueCarriedDirect: 'directe sur fenêtre exclusive',
        weeklyValueCarriedInferred: 'inférée depuis le quota partagé',
        weeklyValueUnknownProvider: 'fournisseur inconnu',
        weeklyValueMixedSampleCounts: '{samples} fenêtres antérieures sans chevauchement disponibles ; {minimum} requises dans ce cycle de quota.',
        weeklyValueReasonMixedInsufficient: 'Trop peu de fenêtres antérieures sans chevauchement dans ce cycle de quota.',
        weeklyValueReasonMixedFixedMix: 'Les coûts antérieurs des modèles ne varient pas assez indépendamment pour être attribués.',
        weeklyValueReasonMixedIllConditioned: 'Les coûts antérieurs des modèles sont trop colinéaires pour une attribution stable.',
        weeklyValueReasonMixedPoorFit: 'Les fenêtres antérieures ne correspondent pas à une attribution stable.',
        weeklyValueReasonMixedNonPositive: 'L’attribution ajustée par modèle n’est pas positive.',
        weeklyValueReasonMixedUnstable: 'L’attribution ajustée est trop sensible à l’arrondi du quota.',
        weeklyValueReasonMixedTargetAbsent: 'Ce modèle n’a pas été utilisé dans la fenêtre cible.',
        weeklyValueReasonMixedTargetMismatch: 'La fenêtre cible mise à l’écart ne correspond pas à l’attribution historique.',
        weeklyLimitValueKicker: 'Valeur de la limite hebdomadaire',
        weeklyLimitValueTitle: 'Valeur implicite de la limite hebdomadaire',
        weeklyLimitValueWindow: 'Fenêtre glissante · 12 h · un point / 6 h · USD',
        weeklyLimitValueDescription: 'Les valeurs agrégées utilisent une fenêtre glissante de douze heures. Les valeurs par modèle lors d’un usage mixte peuvent utiliser des intervalles mesurables plus courts et sont inférées depuis le quota partagé. Les points creux en pointillés reportent une estimation acceptée antérieure.',
        weeklyLimitValueQualityLegend: 'Qualité : bonne · confiance faible · forte incertitude · volatile. Les plages de sensibilité supposent une erreur d’un point dans chaque observation de quota ; ce ne sont pas des intervalles de confiance statistiques. Le tableau donne les plages de sensibilité.',
        showWeeklyLimitValueTable: 'Afficher le tableau de la valeur hebdomadaire',
        weeklyLimitValueTableCaption: 'Données de valeur implicite de la limite hebdomadaire',
        observedCostUsd: 'Coût observé ($)',
        quotaConsumed: 'Quota consommé',
        rawValueUsd: 'Valeur brute ($)',
        smoothedValueUsd: 'Valeur lissée ($)',
        sensitivityRange: 'Plage de sensibilité',
        estimatedCycleCostUsd: 'Coût estimé du cycle ($)',
        extrapolatedValueUsd: 'Valeur extrapolée à 100 % ($)',
        quality: 'Qualité',
        explanation: 'Explication',
        weeklyLimitValueSummary: '{valid} estimations affichées du {from} au {to} ; {unavailable} points indisponibles.',
        noWeeklyLimitValue: 'Aucune valeur hebdomadaire comparable n’est disponible sur cette période.',
        weeklyValueCurrentUnavailable: 'Estimation courante indisponible : le dernier relevé de limite est obsolète.',
        weeklyValueAvailable: 'Fenêtre comparable toutes sources',
        weeklyValueUnavailable: 'Indisponible',
        weeklyValueDispersion: 'dispersion relative',
        weeklyValueQuality_good: 'Bonne',
        weeklyValueQuality_low_confidence: 'Confiance faible',
        weeklyValueQuality_high_uncertainty: 'Forte incertitude',
        weeklyValueQuality_volatile: 'Volatile',
        weeklyValueQuality_unavailable: 'Indisponible',
        weeklyValueSensitivityBounded: '{lower}–{upper} · sensibilité à une erreur de quota d’un point',
        weeklyValueSensitivityUnbounded: '{lower}–sans limite · sensibilité à une erreur de quota d’un point',
        weeklyValueSensitivityTitle: 'Coefficient {coefficient} ± {error} de fraction de quota par USD selon la sensibilité supposée à une erreur de quota d’un point.',
        weeklyValueUnbounded: 'sans limite',
        weeklyValueReasonAmbiguousLimit: 'Identité de limite ambiguë autour du reset.',
        weeklyValueReasonDeadlineTransition: 'La date de reset hebdomadaire a changé dans la fenêtre.',
        weeklyValueReasonIncompleteCycle: 'Aucun reset précédent ne fournit un cycle complet.',
        weeklyValueReasonInsufficientDelta: 'La baisse du quota est sous le seuil de signal de 0,5 point.',
        weeklyValueReasonInvalidEvent: 'Un événement de tokens collecté localement possède des compteurs invalides.',
        weeklyValueReasonInvalidQuota: 'Le pourcentage de quota est invalide.',
        weeklyValueReasonInvalidValue: 'La valeur calculée n’est pas finie et positive.',
        weeklyValueReasonMissingDeadline: 'La date de reset hebdomadaire est absente.',
        weeklyValueReasonMissingLimit: 'L’identité de limite de quota est absente.',
        weeklyValueReasonLimitTransition: 'L’identité de limite a changé pendant la comparaison.',
        weeklyValueReasonMissingPrice: 'Un modèle collecté localement n’a pas de prix catalogue positif.',
        weeklyValueReasonNoCost: 'Aucun coût équivalent API positif n’a été observé.',
        weeklyValueReasonNoEvents: 'Aucun événement de tokens collecté localement n’a été observé.',
        weeklyValueReasonQuotaIncrease: 'Le quota a augmenté au lieu d’être consommé.',
        weeklyValueReasonResetInWindow: 'Un reset hebdomadaire a eu lieu dans la fenêtre.',
        weeklyValueReasonFullyConsumed: 'Le cycle a été entièrement consommé ; l’extrapolation ne s’applique pas.',
        weeklyValueReasonWeeklyOnly: 'La valeur de cycle concerne uniquement les resets hebdomadaires.',
        weeklyValueReasonStaleBoundary: 'La frontière du reset est trop éloignée des relevés de limite voisins.',
        weeklyValueReasonStaleData: 'Le dernier relevé de limite est obsolète pour l’estimation courante.',
        weeklyValueReasonWindowDuration: 'Aucune fenêtre comparable de 11 h 45 à 12 h 15 n’a été trouvée.',
        weeklyValueReasonZeroConsumed: 'Aucun quota n’a été consommé avant ce reset.',
        weeklyValueReasonZeroDelta: 'Le quota n’a pas diminué dans la fenêtre.',
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
        tokenValue: '{value} tokens',
        resetHistory: 'Historique des réinitialisations',
        previousLimitResets: 'Réinitialisations précédentes',
        window: 'Fenêtre',
        fiveHour: '5 heures',
        weekly: 'Hebdomadaire',
        category: 'Catégorie',
        scheduledReset: 'Réinitialisation prévue',
        firstObservation: 'Première observation',
        beforeAfter: 'Avant → après',
        forecastBeforeReset: 'Forecast avant le reset',
        impact: 'Impact',
        delay: 'Délai',
        date: 'Date',
        showLimitTable: 'Afficher le tableau des limites',
        showTokenTable: 'Afficher le tableau des tokens',
        limitTableCaption: 'Données historiques des limites',
        tokenTableCaption: 'Données de consommation des tokens',
        breakdownCaption: 'Répartition des tokens et coûts par application, fournisseur et modèle',
        breakdownPaginationAria: 'Pagination de la ventilation par modèle',
        resetCaption: 'Réinitialisations de limites détectées',
        fiveHourResetMarkers: 'Marqueurs de réinitialisation 5 h',
        weeklyResetMarkers: 'Marqueurs de réinitialisation hebdomadaire',
        limitChartSummary: '{samples} relevés de limite et {forecasts} relevés Forecast du {from} au {to} ; {resets} marqueurs de réinitialisation.',
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
        idealWeeklyPace: 'Rythme hebdomadaire idéal',
        forecast24h: 'Prévision 24 h',
        forecast6h: 'Prévision 6 h',
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
        gptModelsUnavailable: 'Aucun modèle GPT pris en charge n’est disponible dans cette archive (GPT-6.1 Sol, GPT-6 Astra, Sol, Luna ou GPT-5.6 Sol, Terra, Luna).',
        chooseBothDates: 'Choisissez les deux dates personnalisées.',
        chartFailed: 'Chart.js n’a pas pu être chargé',
        unableToLoadAnalytics: 'Impossible de charger les analytics',
        sourcePriceUnknown: 'Aucun prix catalogue ; valeur supposée nulle : {name}',
        collectorWarning: 'Collecteur {name} : {message}',
        pricingUnknownTitle: 'Modèle absent du catalogue tarifaire ; valeur supposée nulle',
      },
    },
  };

  Object.assign(translations.en.analytics, {
    comparePrevious: 'Compare previous period', comparison: 'Previous period', comparisonUnavailable: 'Previous-period comparison unavailable',
    exportCsv: 'Export CSV', exportDataset: 'Dataset', exportDownload: 'Download CSV', exportRaw: 'USD, full token counts and UTC dates',
    diagnostics: 'Monitor diagnostics', diagnosticsUnavailable: 'Diagnostics unavailable', loadingSection: 'Loading…',
    sectionFailed: 'Unable to load this section. Showing the last successful data when available.', unavailableModel: 'Unavailable in this archive',
    chartFallbackTable: 'Chart unavailable. The data table is open below.',
    restoredModelsRejected: 'The requested model filter exceeds 50 models. Default filters are shown.',
  });
  Object.assign(translations.fr.analytics, {
    comparePrevious: 'Comparer la période précédente', comparison: 'Période précédente', comparisonUnavailable: 'Comparaison précédente indisponible',
    exportCsv: 'Exporter CSV', exportDataset: 'Jeu de données', exportDownload: 'Télécharger CSV', exportRaw: 'USD, nombres de tokens complets et dates UTC',
    diagnostics: 'Diagnostic du moniteur', diagnosticsUnavailable: 'Diagnostic indisponible', loadingSection: 'Chargement…',
    sectionFailed: 'Impossible de charger cette section. Les dernières données valides sont affichées si disponibles.', unavailableModel: 'Indisponible dans cette archive',
    chartFallbackTable: 'Graphique indisponible. Le tableau de données est ouvert ci-dessous.',
    restoredModelsRejected: 'Le filtre demandé dépasse 50 modèles. Les filtres par défaut sont affichés.',
  });
  translations.en.analytics.diagnosticLabels = {
    monitor: 'Monitor', archive: 'Archive', status: 'Status', last_cycle_at: 'Last cycle', last_success_at: 'Last success',
    consecutive_failures: 'Consecutive failures', last_cycle_duration_ms: 'Cycle duration (ms)', interval_seconds: 'Interval (seconds)',
    age_seconds: 'Age (seconds)', last_error_at: 'Last error', error_code: 'Error code', error_message: 'Error', snapshots: 'Limit samples',
    token_events: 'Token events', resets: 'Resets', anomalies: 'Anomalies', pending_anomalies: 'Pending anomalies', last_snapshot_at: 'Last limit sample',
  };
  translations.fr.analytics.diagnosticLabels = {
    monitor: 'Moniteur', archive: 'Archive', status: 'État', last_cycle_at: 'Dernier cycle', last_success_at: 'Dernière réussite',
    consecutive_failures: 'Échecs consécutifs', last_cycle_duration_ms: 'Durée du cycle (ms)', interval_seconds: 'Intervalle (secondes)',
    age_seconds: 'Âge (secondes)', last_error_at: 'Dernière erreur', error_code: 'Code d’erreur', error_message: 'Erreur', snapshots: 'Relevés de limite',
    token_events: 'Événements de tokens', resets: 'Réinitialisations', anomalies: 'Anomalies', pending_anomalies: 'Anomalies en attente', last_snapshot_at: 'Dernier relevé de limite',
  };
  translations.en.analytics.diagnosticStatuses = { healthy: 'healthy', unhealthy: 'unhealthy', degraded: 'degraded', stale: 'stale', unavailable: 'unavailable', ok: 'healthy' };
  translations.fr.analytics.diagnosticStatuses = { healthy: 'bon', unhealthy: 'défaillant', degraded: 'dégradé', stale: 'périmé', unavailable: 'indisponible', ok: 'bon' };
  translations.en.analytics.diagnosticErrors = {
    alert_state_failed: 'Alert state could not be saved.', alert_journal_failed: 'Alert journal maintenance failed.',
    alert_cleanup_failed: 'Alert cleanup failed.', collection_failed: 'Collection or alert delivery failed.',
  };
  translations.fr.analytics.diagnosticErrors = {
    alert_state_failed: 'L’état des alertes n’a pas pu être enregistré.', alert_journal_failed: 'La maintenance du journal des alertes a échoué.',
    alert_cleanup_failed: 'Le nettoyage des alertes a échoué.', collection_failed: 'La collecte ou l’envoi des alertes a échoué.',
  };
  translations.en.analytics.diagnosticWarnings = { monitorUnavailable: 'Monitor health is unavailable.', monitorStale: 'Monitor health is stale.', archiveUnavailable: 'Archive is unavailable.', archiveUnsafe: 'Archive could not be read safely.', unknown: 'Diagnostics warning.' };
  translations.fr.analytics.diagnosticWarnings = { monitorUnavailable: 'L’état du moniteur est indisponible.', monitorStale: 'L’état du moniteur est périmé.', archiveUnavailable: 'L’archive est indisponible.', archiveUnsafe: 'L’archive n’a pas pu être lue en toute sécurité.', unknown: 'Avertissement du diagnostic.' };
  translations.en.analytics.diagnosticAnomalies = { quota_increase: 'Quota increased', reset_shift: 'Reset shifted', reset_in_past: 'Reset in the past', reset_missing: 'Reset missing', reset_oscillation: 'Reset oscillation' };
  translations.fr.analytics.diagnosticAnomalies = { quota_increase: 'Quota en hausse', reset_shift: 'Réinitialisation décalée', reset_in_past: 'Réinitialisation dans le passé', reset_missing: 'Réinitialisation absente', reset_oscillation: 'Réinitialisation instable' };
  Object.assign(translations.fr.preferences, {
    advanced: 'Heure et taux de change', timezone: 'Fuseau horaire (IANA)', usdToEurRate: 'EUR par USD', rateDate: 'Date du taux',
    invalidTimezone: 'Saisissez un fuseau horaire IANA valide.', invalidRate: 'Saisissez un taux de change positif.', invalidDate: 'Saisissez une date valide.',
  });
  const formatters = new Map();
  function formatter(kind, language, options = {}) {
    const key = JSON.stringify([kind, language, Object.entries(options).sort(([a], [b]) => a.localeCompare(b))]);
    if (!formatters.has(key)) {
      if (formatters.size >= 64) formatters.delete(formatters.keys().next().value);
      formatters.set(key, kind === 'date' ? new Intl.DateTimeFormat(language, options) : new Intl.NumberFormat(language, options));
    }
    return formatters.get(key);
  }
  function canonicalTimezone(value) {
    if (typeof value !== 'string' || value.length > 100 || !value) return null;
    try {
      const name = formatter('date', 'en', { timeZone: value }).resolvedOptions().timeZone;
      // Intl also accepts numeric offsets in newer browsers; the API uses
      // named IANA zones, including their canonical spelling and aliases.
      return typeof name === 'string' && !/^[+-]/.test(name) ? name : null;
    } catch (_error) { return null; }
  }
  function validTimezone(value) { return canonicalTimezone(value) !== null; }
  function validRate(value) { return value !== '' && Number.isFinite(Number(value)) && Number(value) > 0 && Number(value) <= 1000; }
  function validDate(value) {
    return value === '' || (typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value) && Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value);
  }

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
      timezone: canonicalTimezone(candidate.timezone) || DEFAULTS.timezone,
      usdToEurRate: validRate(candidate.usdToEurRate) ? Number(candidate.usdToEurRate) : DEFAULTS.usdToEurRate,
      rateDate: validDate(candidate.rateDate) ? candidate.rateDate : DEFAULTS.rateDate,
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
      ['data-i18n-aria-valuetext', 'aria-valuetext'],
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
    for (const select of documentRef.querySelectorAll('[data-preference-select], [data-preference-input]')) {
      const setting = select.getAttribute('data-preference-select') || select.getAttribute('data-preference-input');
      select.value = preferences[setting];
    }
    for (const button of documentRef.querySelectorAll('[data-preference-toggle]')) syncToggle(button);
  }

  function notify() {
    for (const listener of listeners) listener({ ...preferences });
  }

  function set(partial) {
    const next = normalize({ ...preferences, ...(partial || {}) });
    if (Object.keys(DEFAULTS).every(key => next[key] === preferences[key])) return;
    preferences = next;
    persist();
    applyDocument();
    notify();
  }

  function bindControls() {
    const documentRef = root.document;
    if (!documentRef || typeof documentRef.querySelectorAll !== 'function') return;
    for (const select of documentRef.querySelectorAll('[data-preference-select], [data-preference-input]')) {
      select.addEventListener('change', event => {
        const control = event.currentTarget;
        const setting = control.getAttribute('data-preference-select') || control.getAttribute('data-preference-input');
        const valid = setting === 'timezone' ? validTimezone(control.value) : setting === 'usdToEurRate' ? validRate(control.value) : setting === 'rateDate' ? validDate(control.value) : true;
        control.setCustomValidity?.(valid ? '' : translate(`preferences.${setting === 'timezone' ? 'invalidTimezone' : setting === 'rateDate' ? 'invalidDate' : 'invalidRate'}`));
        if (!valid) { control.reportValidity?.(); return; }
        set({ [setting]: control.value });
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
    timezone: () => preferences.timezone,
    convertUsd: value => Number(value) * (preferences.currency === 'EUR' ? preferences.usdToEurRate : 1),
    dateFormatter: options => formatter('date', locale(), { ...options, timeZone: preferences.timezone }),
    numberFormatter: (options = {}, language = numberLocale()) => formatter('number', language, options),
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
      if (!Number.isFinite(usd)) return '-';
      const amount = preferences.currency === 'EUR' ? usd * preferences.usdToEurRate : usd;
      const fractionDigits = Math.abs(amount) < 1 ? 4 : 2;
      return formatter('number', locale(), {
        style: 'currency',
        currency: preferences.currency,
        currencyDisplay: 'narrowSymbol',
        minimumFractionDigits: fractionDigits,
        maximumFractionDigits: fractionDigits,
      }).format(amount);
    },
    formatRate() {
      return formatter('number', numberLocale(), { minimumFractionDigits: 2, maximumFractionDigits: 6 }).format(preferences.usdToEurRate);
    },
  };
  root.CodexPreferences = api;
  initialiseDocument();
})(typeof globalThis !== 'undefined' ? globalThis : window);
