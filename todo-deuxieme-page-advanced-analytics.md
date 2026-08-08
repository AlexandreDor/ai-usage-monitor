# Deuxième page « Advanced Analytics »

> **Statut : terminé sur la branche `dev`.** Toutes les propositions restantes ont été implémentées et vérifiées sans modifier le contrat `schema_version: 1`.

## État de vérification finale

Les points qui restaient ouverts sont maintenant couverts :

- [x] archive SQLite v2, migration v1, rétention, récupération après corruption et reconstruction des resets ;
- [x] mode `TOKEN_USAGE_SOURCES=auto` tolérant aux sources absentes ou vides, avec états de collecte ;
- [x] curseur Codex résistant aux lignes JSONL partielles, à la troncature et à la rotation, avec reprise idempotente ;
- [x] catalogue `TOKEN_PRICING_FILE` partagé avec le monitor et lu depuis `.env` sans exécuter sa syntaxe ;
- [x] API locale, filtres, dates Europe/Paris, coût par bucket, marqueurs de reset, fraîcheur et pagination bornée ;
- [x] interface Advanced Analytics, ventilation par application/fournisseur/modèle, métriques détaillées, bascule tokens/coût et tableaux accessibles ;
- [x] granularité harmonisée : 15 minutes jusqu'à 48 heures, 30 minutes jusqu'à 30 jours, puis 1 heure ;
- [x] tests de migration, collecte Codex/OpenCode/Hermes, concurrence lecture/écriture, DST, tarification personnalisée et maintien après erreur UI ;
- [x] documentation README, feuille de route, `.env.example` et sorties de test ignorées.

## Résumé

Ajouter une page locale `analytics.html`, accessible depuis la page principale, consacrée :

- à l’historique longue durée des limites Codex ;
- à une chronologie commune des resets 5 h et hebdomadaires ;
- à la consommation de tokens de Codex, OpenCode et Hermes, ventilée par application, fournisseur, modèle et type de token ;
- à une estimation en USD du coût API équivalent ;
- à des périodes de 24 h, 7 j, 30 j, 90 j, 1 an, toute la rétention, ou personnalisées.

La collecte des tokens s’exécutera à chaque cycle du moniteur, donc toutes les 15 minutes avec la configuration par défaut. La page restera locale : aucune donnée analytique ne sera envoyée vers GitHub Gist.

## Architecture retenue

### Stockage

Faire évoluer `runtime/usage-history.sqlite3` vers un schéma v2 partagé entre les limites et les tokens.

Ajouter un module Python commun de stockage/migration afin d’éviter que `archive.py` et le nouveau collecteur ne gèrent séparément `PRAGMA user_version`.

Tables nouvelles :

- `reset_events`
  - `window` : `5h` ou `weekly`
  - `reset_at_epoch`
  - `observed_at_epoch`
  - `before_pct`
  - `after_pct`
  - `detection_method`
  - clé unique `(window, reset_at_epoch)`

- `token_usage_events`
  - `occurred_at_epoch`
  - `source` : `codex`, `opencode`, `hermes`
  - `provider`
  - `model`
  - `input_tokens`
  - `cache_read_tokens`
  - `cache_write_tokens`
  - `output_tokens`, raisonnement inclus
  - `reasoning_tokens`, sous-ensemble informatif de la sortie
  - `external_id` idempotent
  - `imported`
  - `quality`
  - clé unique `(source, external_id)`

- `collector_state`
  - curseurs de fichiers Codex ;
  - watermarks OpenCode ;
  - derniers compteurs cumulés Hermes ;
  - baselines antérieures au suivi.

- `collector_runs`
  - dernier essai et dernier succès par source ;
  - statut `ok`, `disabled`, `unavailable` ou `error` ;
  - erreur bornée et version de schéma source reconnue.

Index sur la date, la source, le modèle et le fournisseur.

La rétention de `ARCHIVE_RETENTION_DAYS` s’appliquera également aux événements de tokens et aux resets. La valeur actuelle de 365 jours reste le défaut ; `0` reste illimité.

### Nouveaux modules

- `local/storage.py` : connexions SQLite, intégrité, migrations v1 → v2 et permissions.
- `local/token_usage.py` : adaptateurs Codex/OpenCode/Hermes, normalisation, import et requêtes agrégées.
- `local/pricing.json` : catalogue tarifaire local, versionné et validé.

`archive.py` conservera l’ingestion et le compactage des limites, mais utilisera le stockage partagé et reconstruira les événements de reset.

## Collecte des tokens

### Codex

Lire uniquement les rollouts JSONL de `~/.codex/sessions` et `~/.codex/archived_sessions`, sans ouvrir `auth.json`, les prompts ou le contenu des messages.

Pour chaque rollout :

- identifier le modèle courant grâce aux événements `turn_context` ;
- lire les événements `token_count` ;
- calculer les deltas positifs entre deux `total_token_usage` cumulés ;
- normaliser :
  - entrée non mise en cache = `input_tokens - cached_input_tokens - cache_write_input_tokens` ;
  - sortie facturable = `output_tokens`, déjà raisonnement compris ;
  - `reasoning_output_tokens` reste un sous-compteur ;
- sauvegarder un curseur par session/fichier ;
- en cas de déplacement, troncature ou rotation, rescanner de façon idempotente grâce à `external_id`.

Les rollouts explicitement marqués comme initiés par Hermes seront attribués à Hermes ou ignorés côté Codex afin d’éviter un double comptage. Les recouvrements impossibles à prouver seront signalés dans les métadonnées de qualité.

### OpenCode

Ouvrir `~/.local/share/opencode/opencode.db` en lecture seule avec `busy_timeout`.

Lire les messages assistant terminés et leur structure JSON :

- modèle et fournisseur ;
- input ;
- output ;
- reasoning ;
- cache read/write ;
- dates de création et fin.

Normalisation OpenCode :

- `input` est l’entrée non mise en cache ;
- cache read/write restent séparés ;
- sortie facturable = `output + reasoning` ;
- l’identifiant du message devient l’identifiant externe ;
- une ligne encore modifiée par OpenCode est mise à jour par UPSERT.

### Hermes

Ouvrir `~/.hermes/state.db` en lecture seule et privilégier `session_model_usage`, qui préserve les changements de modèle.

À chaque cycle :

- lire les compteurs cumulés par session, modèle, fournisseur, mode de facturation et tâche ;
- calculer le delta depuis le dernier relevé ;
- attribuer ce delta à `last_seen`, avec une précision maximale de 15 minutes ;
- remettre seulement la baseline à jour si un compteur régresse, sans créer de consommation négative.

Lors du premier démarrage, les cumuls Hermes déjà existants seront enregistrés comme « pre-monitor baseline » et exclus des graphiques et totaux filtrés par dates. Ils seront présentés séparément, sans répartition temporelle artificielle.

Une variante de compatibilité basée sur la table `sessions` sera prévue pour les versions Hermes ne possédant pas encore `session_model_usage`.

### Import initial prudent

Au premier cycle :

- importer les événements historiques datables de Codex et OpenCode dans la limite de rétention ;
- créer une baseline non datée pour Hermes ;
- marquer les données importées ;
- ignorer les fichiers manifestement antérieurs à la rétention ;
- journaliser durée, nombre d’événements importés et sources indisponibles.

L’import restera entièrement idempotent et transactionnel.

## Intégration au cycle de 15 minutes

Modifier `monitor.sh` pour que la collecte des tokens soit indépendante de la lecture des limites Codex :

1. tenter la collecte des limites ;
2. archiver le snapshot et traiter alertes/Gist si disponible ;
3. lancer les trois adaptateurs de tokens ;
4. mettre à jour les statuts de collecte ;
5. produire un état global réussi, dégradé ou échoué.

Ainsi, une panne de `account/rateLimits/read` n’empêchera pas la récupération des tokens locaux.

Configuration nouvelle :

- `TOKEN_USAGE_SOURCES=auto` par défaut ;
- valeurs acceptées : `auto`, `none` ou liste parmi `codex,opencode,hermes` ;
- `CODEX_DATA_DIR` pour remplacer `~/.codex` ;
- `OPENCODE_DB_PATH` pour remplacer le chemin XDG par défaut ;
- `HERMES_DB_PATH` pour remplacer `~/.hermes/state.db` ;
- `TOKEN_PRICING_FILE` pour remplacer le catalogue versionné.

En mode `auto`, une application absente sera simplement marquée `disabled`. Lorsqu’une source est explicitement demandée mais absente ou incompatible, le cycle sera marqué dégradé.

`monitor.sh --check` vérifiera également les chemins, permissions, schémas reconnus et validité du catalogue tarifaire.

## Historique des resets

Reconstruire les resets à partir des snapshots conservés, dans la transaction d’archivage.

Pour deux snapshots chronologiques consécutifs, enregistrer un reset lorsque le `reset_at` connu du premier snapshot se situe entre les dates des deux relevés.

Chaque événement contiendra :

- fenêtre 5 h ou hebdomadaire ;
- heure planifiée du reset ;
- première observation après le reset ;
- pourcentage avant et après ;
- retard d’observation lié à l’intervalle ou à une interruption du moniteur.

Ne pas inventer de resets manqués pendant une longue interruption. Si la fenêtre 5 h est absente des réponses Codex, afficher un état vide explicite.

## Catalogue tarifaire

### Format

`local/pricing.json` contiendra :

- `schema_version`
- `currency: "USD"`
- `as_of`
- source documentaire et URL ;
- entrées indexées par fournisseur et modèle ;
- alias de modèles ;
- tarifs par million de tokens :
  - input non caché ;
  - cache read ;
  - cache write ;
  - output ;
- notes et hypothèses éventuelles.

Le coût sera calculé à la lecture avec le catalogue courant :

```text
input × tarif_input
+ cache_read × tarif_cache_read
+ cache_write × tarif_cache_write
+ output_facturable × tarif_output
```

Les tokens de raisonnement ne seront pas ajoutés une deuxième fois lorsqu’ils sont déjà inclus dans la sortie facturable.

### Catalogue initial

Inclure au minimum les modèles observés dans l’environnement de développement :

- GPT-5.6 Sol : 5,00 $ input, 0,50 $ cached input, 30,00 $ output par million ;
- GPT-5.6 Terra : 2,00 $, 0,20 $, 12,00 $ ;
- GPT-5.6 Luna : 0,20 $, 0,02 $, 1,20 $.

Ces valeurs seront figées avec la date du catalogue et la [page officielle de comparaison OpenAI](https://developers.openai.com/api/docs/models/compare) comme source.

Pour OpenAI, un cache write distinct sera valorisé au tarif input, faute de tarif d’écriture séparé publié. Le schéma permettra néanmoins des tarifs lecture/écriture différents, nécessaires notamment pour les multiplicateurs de cache documentés par [Anthropic](https://platform.claude.com/docs/en/about-claude/pricing) et les tarifs de cache spécifiques de [Gemini](https://ai.google.dev/gemini-api/docs/pricing).

Conformément au choix produit, un modèle absent du catalogue aura un coût estimé de zéro. Il restera affiché avec le statut `assumed-zero` et le nombre de tokens concernés, afin de ne pas présenter cette hypothèse comme un tarif confirmé.

L’estimation exclura les frais par requête, outils, recherches web, stockage temporel de cache, remises batch, contrats privés et conversion monétaire.

## API locale en lecture seule

Faire évoluer le serveur Python intégré dans `serve.sh` avec :

```text
GET /api/analytics
```

Paramètres :

- `range=24h|7d|30d|90d|1y|all`
- ou `from_date=YYYY-MM-DD&to_date=YYYY-MM-DD`
- `source=all|codex|opencode|hermes`
- `model=<nom exact>` facultatif
- `reset_type=all|5h|weekly`
- `reset_offset`
- `reset_limit`, borné à 100

Les dates personnalisées seront interprétées comme des journées civiles dans `Europe/Paris`.

Réponse versionnée :

- période réelle et granularité ;
- fraîcheur des limites et des trois collecteurs ;
- sources et modèles disponibles ;
- série longue des limites ;
- résumé et série des tokens ;
- ventilation par application/modèle ;
- coût API équivalent ;
- nombre de tokens au coût supposé nul ;
- resets paginés ;
- baselines antérieures non datées ;
- avertissements de qualité ou de déduplication.

Granularité automatique :

- jusqu'à 48 h : 15 minutes ;
- jusqu'à 30 jours : 30 minutes ;
- au-delà : 1 heure.

L’API utilisera uniquement des requêtes SQL paramétrées, limitera le nombre de points retournés et n’exposera jamais session, prompt, chemin de projet, compte, jeton d’authentification ou contenu de message.

Réponses invalides : HTTP 400 avec JSON court. Base absente ou illisible : HTTP 503. Les autres chemins restent soumis à l’allowlist.

## Deuxième page

Ajouter :

- `local/analytics.html`
- `local/assets/analytics.js`
- `local/assets/analytics.css`

Ajouter ces fichiers à l’allowlist de `serve.sh`. Réutiliser `dashboard.css` pour le thème commun et Chart.js déjà auto-hébergé.

### Navigation

Ajouter dans les deux pages une navigation :

- `Overview`
- `Advanced analytics`

La nouvelle page et ses libellés seront en anglais, comme l’interface actuelle.

Si l’API locale n’est pas disponible, afficher : « Advanced analytics are available in LOCAL mode only ». Aucun fichier analytique ne sera ajouté à la synchronisation Gist.

### Contenu de la page

En haut :

- sélection de période ;
- champs de dates personnalisées ;
- filtre application ;
- filtre modèle ;
- fraîcheur des données et état des collecteurs.

Cartes de synthèse :

- total tokens ;
- uncached input ;
- cache read ;
- cache write ;
- output ;
- reasoning inclus dans output ;
- API-equivalent cost ;
- tokens valued at assumed zero.

Graphiques :

1. limites 5 h et hebdomadaires sur la période, avec marqueurs de reset ;
2. consommation de tokens empilée par application ;
3. bascule de métrique du deuxième graphique entre tokens et coût API équivalent.

Tableau de ventilation :

- application ;
- fournisseur ;
- modèle ;
- input ;
- cache read/write ;
- output ;
- reasoning ;
- total ;
- coût ;
- statut tarifaire.

Chronologie des resets :

- tableau commun 5 h + hebdomadaire ;
- filtre de type ;
- date du reset ;
- première observation ;
- pourcentage avant/après ;
- retard d’observation ;
- pagination de 50 lignes.

Les filtres application/modèle affecteront seulement les statistiques de tokens. La période affectera toutes les sections.

La page se rafraîchira sur les mêmes frontières temporelles que la page principale. En cas d’erreur, les dernières données valides resteront visibles avec un avertissement.

## Accessibilité et sécurité

- Utiliser titres, sections, formulaires et tableaux sémantiques.
- Associer chaque contrôle à un `<label>`.
- Fournir des régions `aria-live` pour chargement, fraîcheur et erreurs.
- Donner aux graphiques un résumé textuel/tabulaire.
- Ne pas transmettre l’état uniquement par la couleur.
- Respecter `prefers-reduced-motion`.
- Conserver la CSP locale et `connect-src 'self'`.
- Documenter que le mode LAN expose désormais modèles, volumes de tokens et estimations de coûts.
- Conserver la base SQLite et les états de collecte hors allowlist.

## Tests

### Stockage et migrations

- migration automatique d’une base v1 réelle vers v2 ;
- conservation des snapshots et métadonnées existants ;
- permissions `0600` ;
- récupération après corruption ;
- rétention 365 jours et mode illimité ;
- concurrence lecture API/écriture moniteur.

### Adaptateurs

Codex :

- import historique ;
- reprise à l’offset ;
- rotation/troncature ;
- modèle changé en cours de session ;
- delta cumulatif ;
- doublon de `token_count` ;
- cache inclus dans input ;
- rollout Hermes exclu du total Codex.

OpenCode :

- message assistant complet/incomplet ;
- mise à jour d’un message ;
- variantes de modèle ;
- raisonnement ajouté à la sortie facturable ;
- base occupée ou schéma incompatible.

Hermes :

- baseline initiale ;
- delta après 15 minutes ;
- nouveau modèle en cours de session ;
- compteur réinitialisé ;
- table `session_model_usage` et fallback `sessions`.

### Tarification

- calcul input/output/cache ;
- absence de double facturation du raisonnement ;
- résolution d’alias ;
- catalogue invalide ;
- modèle inconnu valorisé à zéro et marqué `assumed-zero` ;
- recalcul historique lorsque le catalogue versionné change.

### Resets

- reset 5 h ;
- reset hebdomadaire ;
- snapshot exactement à l’heure ;
- observation tardive ;
- fenêtre partielle à `null` ;
- interruption couvrant plusieurs cycles sans événements inventés ;
- reconstruction idempotente après migration/compactage.

### API HTTP

- presets et dates personnalisées ;
- interprétation Europe/Paris et changement heure été/hiver ;
- filtres et pagination ;
- agrégation automatique ;
- paramètres invalides ;
- plafonds de réponse ;
- absence de chemins, contenus et identifiants privés ;
- base indisponible ;
- refus d’accès direct au SQLite et aux états internes.

### Interface

- rendu hors ligne ;
- navigation entre les deux pages ;
- changement de période, source et modèle ;
- graphiques tokens/coût ;
- tableau et pagination des resets ;
- source indisponible ;
- historique vide ;
- coût supposé nul ;
- maintien des données après erreur ;
- affichage mobile ;
- absence de violation Axe critique.

Les tests shell/Node existants et les trois tests Playwright actuels devront continuer à passer. L’état de référence vérifié avant implémentation est entièrement vert.

## Documentation

Mettre à jour :

- l’architecture et l’arborescence du README ;
- la procédure de démarrage ;
- la configuration des trois sources ;
- le schéma du catalogue tarifaire ;
- la signification « API-equivalent cost » ;
- les limites de précision de l’import Hermes ;
- la rétention et les granularités ;
- le caractère local uniquement de la page avancée ;
- les risques supplémentaires du mode LAN ;
- la procédure d’ajout ou de mise à jour manuelle d’un tarif.

## Ordre d’implémentation

1. Introduire le schéma v2 partagé et les migrations.
2. Ajouter la détection/reconstruction des resets.
3. Implémenter et tester les trois adaptateurs de tokens.
4. Ajouter le catalogue tarifaire et la normalisation canonique.
5. Intégrer la collecte indépendante dans `monitor.sh`.
6. Ajouter la requête analytique et l’endpoint HTTP borné.
7. Construire `analytics.html`, ses filtres, graphiques et tableaux.
8. Ajouter la navigation à la page principale.
9. Étendre les tests shell, Python, Node, HTTP et Playwright.
10. Mettre à jour README, `.env.example`, la CI et la feuille de route.

## Hypothèses verrouillées

- La page avancée est locale uniquement.
- L’interface reste en anglais.
- Le coût affiché est un équivalent API, pas la facture réelle ni le coût marginal de l’abonnement.
- Les tarifs sont locaux, versionnés et non actualisés automatiquement.
- Les modèles sans tarif valent zéro, mais restent signalés comme hypothèse.
- La devise est uniquement USD.
- L’import initial est exact pour Codex/OpenCode et non réparti dans le temps pour Hermes.
- Les resets 5 h et hebdomadaires partagent une chronologie filtrable.
- Les presets et dates personnalisées sont tous deux disponibles.
- La collecte suit `LOOP_INTERVAL`, soit 900 secondes par défaut.
- Les données brutes privées des conversations ne sont jamais copiées dans la base analytique ni retournées par l’API.
