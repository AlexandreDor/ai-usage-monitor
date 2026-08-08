# Feuille de route des améliorations

Cette feuille de route regroupe les améliorations identifiées lors de l'audit du projet et remplace les anciens plans de travail séparés. Elle privilégie d'abord la fiabilité de la collecte et l'intégrité des données, puis l'API Analytics, les alertes, l'expérience utilisateur, la sécurité et la maintenance.

Le programme conserve les choix structurants suivants :

- Bash et Python standard library ;
- une architecture locale sans nouveau service cloud ;
- SQLite comme archive longue durée ;
- le dashboard principal et Analytics comme interfaces séparées ;
- la synchronisation Gist limitée aux données de quotas ;
- Linux et WSL comme environnements cibles.

Le multi-compte et les nouvelles plateformes de notification restent différés jusqu'à la stabilisation du socle.

## Échelle d'effort

| Taille | Estimation |
|---|---:|
| XS | Moins d'une demi-journée |
| S | Entre une demi-journée et une journée |
| M | Entre deux et quatre jours |
| L | Une semaine ou plus |

## P0 - Fiabilité critique

### 1. Fiabiliser les appels réseau

**Statut : terminé.**

**Problème :** les appels vers GitHub Gist, Discord et Telegram n'ont pas de timeout, de stratégie de retry bornée ni de vérification complète des réponses HTTP. Une panne réseau peut bloquer la collecte ou être considérée comme un succès.

**Actions :**

- Ajouter un timeout de connexion et un timeout global à chaque appel `curl`.
- Ajouter des retries limités avec attente progressive.
- Vérifier les statuts HTTP attendus pour chaque service.
- Rendre les transports indépendants : une panne Gist ne doit pas empêcher les alertes.
- Distinguer dans les logs une alerte détectée, une tentative d'envoi et une livraison réussie.
- Ne valider l'état d'une alerte qu'après une livraison réussie, ou conserver un état `pending`.

**Critères de validation :**

- Un service inaccessible ne bloque pas les collectes suivantes.
- Les réponses HTTP 4xx et 5xx sont signalées comme des échecs.
- Une panne d'un canal n'empêche pas l'envoi sur les autres canaux.
- Les scénarios de succès, timeout, 4xx et 5xx sont testés.

**Effort : S à M**

### 2. Corriger les alertes lors du franchissement de plusieurs seuils

**Statut : terminé.**

**Problème :** si le quota passe rapidement de 80 % à 4 %, seul le premier seuil rencontré est envoyé. Les seuils plus critiques sont ensuite définitivement perdus.

**Actions :**

- Envoyer une alerte unique mentionnant tous les seuils franchis, ou sélectionner le seuil le plus critique.
- Persister l'état par seuil et par fenêtre de quota.
- Définir clairement le comportement lors du premier relevé et après un reset.

**Critères de validation :**

- Les transitions `80 -> 70`, `80 -> 4`, `4 -> 100` et les oscillations autour d'un seuil sont testées.
- Une chute importante produit une alerte correspondant au niveau réellement critique.
- Chaque seuil n'est notifié qu'une fois par cycle.

**Effort : S**

### 3. Ajouter un verrou global sur chaque cycle

**Statut : terminé.**

**Problème :** le verrou actuel couvre uniquement la mise à jour de l'historique. Plusieurs instances peuvent collecter simultanément, envoyer des alertes en double ou écraser leur état.

**Actions :**

- Poser un verrou non bloquant autour du cycle complet : collecte, stockage, alertes et synchronisation Gist.
- Quitter proprement lorsqu'une autre instance est déjà active.
- Refuser de remplacer un snapshot récent par un snapshot plus ancien.

**Critères de validation :**

- Deux lancements simultanés ne produisent qu'une collecte et une série d'alertes.
- L'historique reste trié et sans doublons.
- L'état des alertes ne peut pas régresser.

**Effort : XS à S**

### 4. Détecter les données périmées

**Statut : différé.** La conservation et l'exploitation des données sur le long terme seront traitées séparément.

**Problème :** le dashboard considère les données comme valides tant que les fichiers JSON restent accessibles, même si le collecteur est arrêté depuis plusieurs heures.

**Actions :**

- Comparer `scraped_at` à `sample_interval_seconds`.
- Afficher un avertissement après environ deux intervalles sans mise à jour.
- Rendre visible le statut `LOCAL`, `EXTERNAL` ou `STALE`.
- Afficher l'âge réel des données.
- Envisager un état de santé contenant le dernier succès et la dernière erreur.

**Critères de validation :**

- Des données anciennes sont visuellement distinguées des données fraîches.
- Le dashboard affiche depuis combien de temps la collecte est arrêtée.
- Une nouvelle collecte réussie restaure automatiquement l'état normal.

**Effort : S**

## P1 - Robustesse et qualité

### 5. Rendre la rétention réellement temporelle

**Statut : partiellement terminé.** L'archive SQLite longue durée applique désormais une rétention temporelle et un compactage par granularité. L'historique JSON utilisé par le dashboard principal reste toutefois limité par nombre d'entrées ; les critères ci-dessous restent donc ouverts pour ce flux.

**Problème :** l'historique est tronqué selon un nombre d'entrées calculé à partir de l'intervalle courant, pas selon l'âge réel des relevés. Un changement d'intervalle peut raccourcir ou allonger fortement la période conservée.

**Actions :**

- Filtrer les relevés selon `scraped_at` et `HISTORY_RETENTION_HOURS`.
- Dédupliquer et trier les entrées avant l'écriture.
- Ajouter un plafond défensif sur le nombre d'entrées et la taille du fichier.
- Évaluer JSONL ou SQLite si les intervalles courts deviennent un besoin réel.

**Critères de validation :**

- La durée conservée reste correcte après une interruption.
- Les changements d'intervalle `900 -> 60 -> 900` ne détruisent pas la fenêtre historique.
- Un fichier corrompu ne provoque pas une perte silencieuse de tout l'historique.

**Effort : S à M**

### 6. Renforcer le parsing des limites Codex

**Statut : terminé.**

**Problème :** les fenêtres de tous les snapshots sont aplaties, puis la première durée entre 1 et 360 minutes est considérée comme la fenêtre de cinq heures. Une évolution de l'API peut donc associer les mauvaises limites.

**Actions :**

- Conserver l'association entre une fenêtre et son `limitId`.
- Valider explicitement les durées et les champs attendus.
- Accepter les nombres JSON réels lorsqu'ils sont valides.
- Capturer un diagnostic `stderr` borné et nettoyé.
- Ajouter des fixtures représentant plusieurs versions de réponse.

**Critères de validation :**

- Les fenêtres courte et hebdomadaire ne peuvent pas provenir de limites incompatibles.
- Une réponse inconnue produit une erreur explicite. Une réponse partielle observée sur l'API réelle reste exploitable sans fusion de `limitId`, avec un avertissement et des champs indisponibles à `null`.
- Les variantes de réponse connues sont couvertes par des tests.

**Effort : M**

### 7. Valider toute la configuration au démarrage

**Statut : terminé.**

**Actions :**

- Valider et borner `LOOP_INTERVAL`, `CODEX_STATUS_TIMEOUT_SECONDS` et `HISTORY_RETENTION_HOURS`.
- Valider `TELEGRAM_CHAT_ID` et les paires de variables incomplètes.
- Rejeter les caractères de contrôle dans les secrets utilisés par `curl`.
- Documenter précisément la syntaxe acceptée dans `.env`.
- Afficher des messages d'erreur lisibles sans traceback Python.
- Documenter Python 3.9 ou supérieur et la dépendance à `tzdata`.

**Critères de validation :**

- Toute configuration invalide est rejetée avant la première collecte.
- Les valeurs extrêmes ne provoquent ni débordement ni consommation excessive.
- La référence de configuration décrit toutes les variables supportées.

**Effort : S**

### 8. Rendre le dashboard totalement autonome

**Statut : terminé.**

**Problème :** Chart.js et les polices sont chargés depuis des CDN. Une panne Internet peut rendre le dashboard local inutilisable malgré la disponibilité des données.

**Actions :**

- Fournir Chart.js comme actif local versionné.
- Utiliser des polices système ou auto-héberger les polices.
- Ajouter les nouveaux actifs à l'allowlist de `serve.sh`.
- Isoler les erreurs du graphique afin qu'elles n'effacent jamais les métriques principales.
- Séparer le JavaScript et le CSS pour réduire l'usage de `unsafe-inline` dans la CSP.

**Critères de validation :**

- Le dashboard fonctionne sans accès Internet.
- Une erreur du graphique laisse les quotas et les resets visibles.
- La politique CSP n'autorise que les ressources nécessaires.

**Effort : S à M**

### 9. Corriger et optimiser le graphique historique

**Statut : terminé.**

**Actions :**

- Calculer l'allure idéale avec le `weekly_reset_at` de chaque relevé.
- Détruire ou vider le graphique lorsque l'historique devient indisponible.
- Faire correspondre le titre à la période réellement affichée.
- Ajouter une décimation ou une agrégation pour les longues séries.
- Réutiliser le graphique lorsque cela évite une reconstruction complète.

**Critères de validation :**

- La courbe reste correcte lorsqu'elle traverse un reset hebdomadaire.
- Un historique vide ne laisse pas un ancien graphique affiché.
- Le dashboard reste fluide avec la rétention maximale supportée.

**Effort : S**

### 10. Sécuriser l'exposition réseau

**Statut : terminé.**

**Actions :**

- Écouter sur `127.0.0.1` par défaut.
- Exiger une activation explicite pour l'accès LAN.
- Documenter clairement l'absence d'authentification et de TLS.
- Ajouter des options CLI nommées `--bind` et `--port`.
- Envisager une limitation simple de concurrence pour le serveur HTTP.

**Critères de validation :**

- Une installation par défaut n'expose rien sur le réseau local.
- Les fichiers sensibles restent inaccessibles, y compris via des chemins encodés ou du path traversal.

**Effort : XS à S**

### 11. Mettre en place les tests et la CI

**Statut : terminé.**

**Actions :**

- Déplacer les effets de bord de `monitor.sh` dans `main` afin de rendre ses fonctions importables.
- Rendre les chemins, commandes externes et URL injectables dans les tests.
- Ajouter `bash -n`, ShellCheck et éventuellement shfmt à la CI.
- Tester les transports réseau, le parsing Codex, la rétention, la concurrence et la corruption JSON.
- Tester l'allowlist et les en-têtes de `serve.sh`.
- Ajouter des tests Playwright et axe-core pour le dashboard.

**Critères de validation :**

- Les tests ne lisent pas le vrai `.env` et ne modifient pas le runtime du développeur.
- Chaque pull request exécute automatiquement les validations.
- Les principaux scénarios d'échec ont un test de non-régression.

**Effort : M**

### 12. Améliorer l'observabilité

**Statut : terminé.**

**Actions :**

- Journaliser la durée et le résultat de chaque cycle.
- Conserver le dernier succès, la dernière erreur et le nombre d'échecs consécutifs.
- Capturer un diagnostic Codex borné en mode debug, sans exposer de secret.
- Préserver une copie d'un historique corrompu avant reconstruction.
- Ajouter une commande `--check` pour vérifier dépendances, configuration, authentification et permissions.
- Prévoir un mode `--fail-fast` adapté à systemd.

**Critères de validation :**

- Une panne permanente est identifiable depuis les logs sans reproduire manuellement le problème.
- systemd peut redémarrer le service après des échecs répétés.
- Une corruption de données n'est jamais silencieuse.

**Effort : M**

## P2 - Expérience utilisateur et maintenance

### 13. Améliorer l'accessibilité du dashboard

**Statut : partiellement terminé.** La structure sémantique, les barres natives `<progress>`, les messages d'erreur et `prefers-reduced-motion` sont en place. Il reste un résumé accessible des graphiques, l'annonce de fraîcheur et les détails d'allure hors attribut `title`.

**Actions :**

- Ajouter une structure sémantique avec `<main>`, `<section>` et des titres.
- Exposer les jauges avec `role="progressbar"` et les attributs ARIA associés.
- Ajouter des régions `aria-live` pour la fraîcheur et les erreurs.
- Fournir un résumé textuel ou tabulaire de l'historique.
- Afficher les détails d'allure sans dépendre uniquement de l'attribut `title`.
- Respecter `prefers-reduced-motion`.
- Ne pas communiquer la criticité uniquement par la couleur.

**Effort : M**

### 14. Mettre la documentation en cohérence

**Statut : partiellement terminé.** L'architecture, la configuration et l'analytics locale sont documentés. Les URL de clonage contiennent encore `YOUR_USERNAME` et les exemples de test d'alertes exécutent encore `.env` avec `source`.

**Actions :**

- Remplacer les anciens chemins `local/data.json` par `local/runtime/data.json`.
- Décrire la collecte via `codex app-server` plutôt que comme un scraping de `/status`.
- Remplacer l'URL de clonage contenant `YOUR_USERNAME` par l'URL canonique.
- Corriger les procédures LXC, systemd et GitHub Pages.
- Supprimer les exemples qui exécutent `.env` avec `source`.
- Documenter toutes les variables et leurs bornes.
- Expliquer qu'un Gist secret est non répertorié, mais pas privé.
- Ajouter les commandes de test et le dossier `tests/` à la structure du projet.

**Effort : S**

### 15. Préparer le packaging et les releases

**Statut : non commencé.**

**Actions :**

- Versionner les scripts avec le bit exécutable.
- Ajouter des unités systemd réelles et les vérifier avec `systemd-analyze verify`.
- Ajouter `CHANGELOG.md`, des tags et une politique de version.
- Publier des archives de release avec checksums.
- Documenter installation, mise à jour, retour arrière et désinstallation.

**Effort : M**

### 16. Réduire progressivement le script monolithique

**Statut : partiellement terminé.** Le stockage, l'archivage et la collecte analytics sont désormais séparés en modules Python. Le protocole Codex, la validation principale et l'orchestration restent concentrés dans `monitor.sh`.

**Objectif :** améliorer la testabilité sans lancer une réécriture prématurée.

**Actions :**

- Commencer par isoler les effets de bord et les interfaces externes.
- Définir un schéma versionné pour les snapshots, l'historique et l'état d'alerte.
- Déplacer progressivement le protocole Codex, la validation et le stockage dans un module Python.
- Conserver Bash comme lanceur léger tant que cela reste utile.

**Effort : L**

## P3 - Évolutions fonctionnelles

Ces évolutions sont utiles, mais doivent venir après la stabilisation des fonctions existantes.

- Support de plusieurs comptes Codex.
- Notifications Slack, ntfy ou e-mail.
- Endpoint de santé et export Prometheus.
- Agrégation quotidienne pour les historiques longs.
- Fuseau horaire et langue configurables.
- Interface CLI complète : `--help`, `--check`, `--once`, `--loop`, `--bind` et `--port`.
- Mode simulation avec fixtures anonymisées pour développer sans compte Codex.

## Spécifications techniques consolidées

Les éléments ci-dessous précisent les comportements attendus pour les chantiers encore ouverts. Ils complètent les priorités et statuts précédents sans remettre en cause les fonctionnalités déjà terminées.

### Collecte des tokens et tolérance aux sources absentes

Pour `TOKEN_USAGE_SOURCES=auto` :

- un chemin absent, un répertoire Codex vide ou une base OpenCode/Hermes absente produit l'état `disabled` ;
- un schéma non reconnu produit l'état `disabled` avec un avertissement ;
- une erreur de permission, une corruption ou une erreur de lecture produit l'état `error` et un cycle dégradé.

Pour une source explicitement demandée :

- un chemin absent ou un schéma invalide produit l'état `unavailable` ;
- une erreur de lecture produit l'état `error` et marque le cycle en échec.

Chaque source conserve `last_success_at` et `last_error`. Une erreur ne supprime jamais les données collectées précédemment.

Le collecteur Codex doit utiliser un curseur robuste par fichier contenant au minimum :

```json
{
  "device": 0,
  "inode": 0,
  "offset": 0,
  "size": 0,
  "mtime": 0,
  "session_id": "",
  "totals": {},
  "model": "",
  "provider": ""
}
```

Le collecteur doit :

- lire uniquement les lignes JSONL terminées ;
- reprendre une ligne partielle au cycle suivant ;
- réinitialiser l'offset après un changement d'inode ou une troncature ;
- rescanner après une rotation ;
- garantir l'idempotence au moyen de `external_id` ;
- ne pas utiliser uniquement `mtime` pour ignorer un fichier ancien.

Les tests doivent couvrir une ligne partielle, une troncature, une rotation, un changement de modèle, un événement dupliqué et un fichier modifié pendant sa lecture.

### Historique JSON et configuration partagée

Extraire la gestion inline de l'historique de `monitor.sh` vers `local/history.py`. Le module doit :

- valider les snapshots et normaliser les timestamps en epoch ;
- refuser les pourcentages hors de l'intervalle `0..100` ;
- trier et dédupliquer selon le timestamp réel ;
- appliquer une rétention temporelle ;
- écrire atomiquement ;
- sauvegarder sous un nom unique tout historique corrompu ;
- conserver au plus 10 000 entrées et 16 MiB sans provoquer de crash.

La rétention JSON par défaut reste fixée à `HISTORY_RETENTION_HOURS=192`.

Créer `local/config.py` pour assurer une lecture non exécutable de `.env`, une validation typée, le contrôle des permissions et le partage des valeurs entre le monitor et le serveur. Le serveur doit lire le même `TOKEN_PRICING_FILE` depuis `.env` que le monitor. L'ordre de priorité est :

1. option CLI explicite ;
2. variable d'environnement ;
3. valeur de `local/.env` ;
4. valeur par défaut.

L'aide de `monitor.sh` doit documenter `--once`, `--loop [SECONDS]`, `--check`, `--status-json` et `--fail-fast`.

### Migrations et concurrence SQLite

Le stockage doit :

- lire `PRAGMA user_version` et rejeter les versions inconnues ou supérieures ;
- migrer la version 1 vers la version 2 dans une transaction ;
- sauvegarder toute base existante avant une opération susceptible de l'altérer ;
- conserver les snapshots existants ;
- exécuter `quick_check` après une migration.

Le test de migration doit partir d'une véritable base version 1 préexistante.

Passer progressivement du journal `DELETE` à `WAL`, avec un `busy_timeout` explicite, une gestion des erreurs `locked`, un test de lecture/écriture concurrente et un nettoyage contrôlé des fichiers WAL.

### Contrat et robustesse de l'API Analytics

Conserver la réponse Analytics en `schema_version: 1` pour les consommateurs existants et y ajouter :

- la période effective, le fuseau et la granularité ;
- la date du dernier relevé de limites, son âge, son statut de fraîcheur et l'intervalle d'échantillonnage ;
- la devise, la date et l'empreinte SHA-256 du catalogue tarifaire.

L'API ne doit jamais exposer de chemin local, identifiant de session, prompt, contenu de message, compte ou secret d'authentification.

La granularité cible est :

- jusqu'à 48 heures : 15 minutes ;
- jusqu'à 30 jours : 30 minutes ;
- au-delà : 1 heure.

Chaque bucket de quota conserve le dernier relevé observé. Les volumes et coûts de tokens sont additionnés, avec un regroupement possible par application et par bucket.

Les erreurs de catalogue ou SQLite retournent HTTP 503 ; les dates invalides retournent HTTP 400. L'API doit également refuser les paramètres contradictoires ou répétés, borner les filtres et le nombre de points, et toujours retourner un JSON d'erreur court. Les tests couvrent catalogue invalide, base absente ou corrompue, date extrême, requête trop grande et accès concurrent.

### Livraison fiable des alertes

Faire évoluer l'état vers `state_version=4` et suivre séparément, pour chaque `alert_id`, l'état `pending`, `delivered` ou `failed` de Discord et Telegram.

- Une alerte est entièrement livrée uniquement lorsque tous les canaux configurés ont réussi.
- Les erreurs HTTP 4xx permanentes ne sont pas retentées.
- Les erreurs 429, 5xx et les timeouts sont retentés en respectant `Retry-After`.
- Les états v1 à v3 restent lisibles.
- Une alerte déjà livrée ne doit jamais être rejouée après migration.
- Les diagnostics ne doivent contenir aucun token ni URL sensible.

### Finalisation d'Analytics et de l'accessibilité

L'interface Analytics doit ajouter :

- des marqueurs de reset sur les quotas ;
- des séries de tokens par application ;
- une bascule tokens/coût et un coût par bucket ;
- une légende explicite pour les données estimées ;
- des cartes distinctes pour input non mis en cache, cache read, cache write, output, reasoning, total, tokens sans tarif et coût API équivalent ;
- un tableau par application, fournisseur et modèle, paginé par groupes de 50 lignes.

Le reasoning reste un sous-ensemble de l'output et ne doit pas être facturé deux fois. Le coût présenté est une estimation API, pas une facture réelle.

Chaque collecteur affiche son statut, sa dernière tentative, son dernier succès, sa dernière erreur et l'âge de la dernière donnée. Après un échec, les dernières données valides restent visibles avec un avertissement.

L'accessibilité doit inclure un résumé textuel et un tableau alternatif des graphiques, des régions `aria-live`, des labels complets, des jauges ARIA, un état compréhensible sans la couleur et une navigation clavier complète. Les tests navigateur couvrent notamment langue, devise, historique vide, données périmées, collecteur en erreur et absence de graphique.

### Sécurité réseau, tests et distribution

Le serveur reste lié par défaut à `127.0.0.1`. Tout bind non local exige `--allow-insecure-lan` et un avertissement explicite. L'authentification et TLS restent délégués à un reverse proxy. L'allowlist, la CSP, l'absence d'accès SQLite direct et l'absence de synchronisation Analytics vers Gist restent obligatoires.

La suite de validation doit comprendre des tests unitaires Python, migrations, concurrence, changement d'heure, rotation Codex, réinitialisation Hermes, catalogue personnalisé, limites de l'API et reprise après erreur. La CI fixe les versions de Python et Node, compile le Python, vérifie le shell, mesure la couverture, contrôle les migrations et audite les dépendances.

Ajouter au `.gitignore` les sorties générées suivantes lorsqu'elles ne sont pas encore ignorées :

```text
test-results/
playwright-report/
coverage/
.pytest_cache/
.mypy_cache/
.ruff_cache/
```

La documentation de release doit corriger les références obsolètes, expliquer la personnalisation du catalogue et les états de fraîcheur, puis fournir sauvegarde, restauration, installation, mise à jour et désinstallation. Le projet doit disposer d'un `CHANGELOG.md`, d'une version publiée et d'archives avec checksum.

## Plan d'exécution recommandé

### Phase 1 - Stabilisation de la collecte

1. Corriger le comportement de `TOKEN_USAGE_SOURCES`.
2. Fiabiliser le curseur et la rotation du collecteur Codex.
3. Extraire et fiabiliser l'historique JSON.
4. Détecter les données périmées.

### Phase 2 - Configuration et stockage

1. Centraliser et valider la configuration.
2. Partager le catalogue tarifaire.
3. Versionner et tester les migrations SQLite.
4. Fiabiliser la concurrence avec `busy_timeout` et des retries bornés.

### Phase 3 - API et alertes

1. Renforcer le contrat Analytics v1 sans rupture de compatibilité.
2. Appliquer la granularité et les bornes de réponse.
3. Normaliser les erreurs HTTP.
4. Migrer les alertes vers un suivi par canal.

### Phase 4 - Interface et accessibilité

1. Finaliser les graphiques, cartes et tableaux Analytics.
2. Exposer la fraîcheur et les erreurs de chaque collecteur.
3. Terminer l'accessibilité et les tests navigateur.
4. Vérifier le fonctionnement autonome du dashboard.

### Phase 5 - Sécurité, qualité et distribution

1. Verrouiller l'exposition réseau et documenter le reverse proxy.
2. Étendre les tests, la CI et l'observabilité.
3. Corriger la documentation et préparer les releases.
4. Réduire progressivement le script monolithique.
5. Ajouter les évolutions P3 selon les besoins utilisateurs.

## Définition globale de terminé

Une amélioration est considérée comme terminée lorsque :

- son comportement attendu est documenté ;
- les erreurs sont explicites et ne provoquent pas de perte silencieuse ;
- un test de non-régression couvre le chemin principal et les principaux échecs ;
- la CI valide le changement ;
- la documentation utilisateur est mise à jour ;
- aucun secret ou identifiant de compte n'est ajouté aux données exposées.

Le programme consolidé est terminé lorsque, en plus de ces règles générales :

- une source absente en mode `auto` ne fait plus échouer le cycle ;
- aucune ligne JSONL partielle n'est perdue et une rotation est correctement reprise ;
- l'API et le monitor utilisent le même catalogue tarifaire ;
- une base SQLite v1 est migrée sans perte ;
- les erreurs Analytics renvoient un statut 400 ou 503 sans traceback ;
- les quotas affichés proviennent de valeurs réellement observées ;
- les alertes sont suivies indépendamment pour chaque canal ;
- les tests shell, Python, HTTP et navigateur passent en CI ;
- aucune donnée privée, aucun chemin local et aucun secret n'est exposé.
