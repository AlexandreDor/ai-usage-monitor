# Feuille de route clôturée

Les propositions P0, P1 et P2 de cette feuille de route sont implémentées dans
la branche `agent/implement-roadmap-p0-p2-v2`. Ce document est conservé comme
référence de périmètre et de validation; les évolutions P3 restent différées.

Les choix structurants restent les suivants :

- Bash comme lanceur léger et Python standard library pour la logique complexe ;
- architecture locale sans nouveau service cloud ;
- SQLite pour l'archive longue durée ;
- dashboard principal et Analytics séparés ;
- synchronisation Gist limitée aux quotas et à leur historique JSON ;
- Linux et WSL comme environnements cibles.

Effort indicatif : **S** (moins d'une journée), **M** (deux à quatre jours),
**L** (une semaine ou plus).

## P0 — Fiabilité et intégrité des données

### 1. Suivre la livraison des alertes par canal — M

Faire évoluer l'état des alertes vers `state_version=4`.

Travail restant :

- attribuer un `alert_id` stable à chaque alerte ;
- suivre séparément Discord et Telegram avec les états `pending`, `delivered`
  ou `failed` ;
- considérer une alerte comme entièrement livrée uniquement lorsque tous les
  canaux configurés ont réussi ;
- ne pas retenter les erreurs HTTP 4xx permanentes ;
- retenter les erreurs 429, 5xx et les timeouts avec une attente bornée tenant
  compte de `Retry-After` ;
- migrer les états v1 à v3 sans rejouer une alerte déjà livrée ;
- conserver des diagnostics utiles sans token, URL sensible ou identifiant de
  canal.

Validation :

- la réussite d'un canal ne masque pas l'échec de l'autre ;
- un canal déjà livré n'est pas sollicité une seconde fois ;
- les migrations, timeouts, 4xx, 429, 5xx et livraisons partielles sont testés.

### 2. Rendre l'historique JSON réellement temporel — M

Extraire la gestion de `history.json` de `monitor.sh` vers `local/history.py`
sans modifier le format public consommé par le dashboard et le Gist.

Travail restant :

- valider les snapshots et normaliser `scraped_at` en epoch ;
- refuser les pourcentages hors de l'intervalle `0..100` ;
- trier et dédupliquer selon l'instant réel, pas selon la chaîne du timestamp ;
- appliquer `HISTORY_RETENTION_HOURS` selon l'âge des relevés ;
- conserver au maximum 10 000 entrées et 16 MiB ;
- traiter ces deux plafonds comme des limites défensives et avertir lorsqu'ils
  raccourcissent la fenêtre temporelle demandée ;
- écrire atomiquement et créer une sauvegarde au nom unique avant de reconstruire
  un historique corrompu.

Validation :

- les changements d'intervalle `900 -> 60 -> 900` préservent la durée demandée
  tant que les plafonds défensifs ne sont pas atteints ;
- une interruption de collecte ne réduit pas artificiellement la rétention ;
- les timestamps équivalents avec des offsets différents sont dédupliqués ;
- les limites de taille et les corruptions répétées ne provoquent aucune perte
  silencieuse.

### 3. Sécuriser les migrations et la concurrence SQLite — M

Travail restant :

- sauvegarder une base v1 avant sa migration en place vers v2 ;
- passer du journal `DELETE` à `WAL` ;
- gérer explicitement les erreurs `locked` avec des retries courts et bornés ;
- contrôler la fermeture et le nettoyage des fichiers WAL sans supprimer un
  journal actif.

Validation :

- une migration v1 conserve les snapshots et produit une sauvegarde restaurable ;
- lectures Analytics et écritures du monitor peuvent s'exécuter simultanément ;
- une contention prolongée échoue proprement sans corruption ni boucle infinie ;
- `quick_check` reste valide après migration et après accès concurrent.

### 4. Finaliser la fraîcheur et l'accessibilité du dashboard principal — M

Travail restant :

- comparer `scraped_at` à `sample_interval_seconds` ;
- afficher l'âge réel du dernier relevé ;
- passer en état `STALE` après environ deux intervalles sans succès, tout en
  conservant l'origine `LOCAL` ou `EXTERNAL` ;
- annoncer les changements de fraîcheur avec une région `aria-live` ;
- revenir automatiquement à l'état normal après une collecte réussie ;
- donner un nom accessible explicite aux deux jauges `<progress>` ;
- fournir un résumé textuel et un tableau alternatif du graphique historique ;
- exposer visiblement les valeurs réelle et idéale utilisées pour l'allure
  hebdomadaire, sans dépendre de l'attribut `title` ;
- garantir que disponibilité, criticité et allure restent compréhensibles sans
  couleur et au clavier.

Validation :

- les états frais, périmé, erreur puis récupération sont testés dans le navigateur ;
- les quotas restent visibles lorsque les données sont anciennes ;
- le dashboard reste compréhensible sans Chart.js et sans couleur ;
- les tests couvrent le clavier, un historique vide et le tableau alternatif ;
- axe-core ne remonte aucune violation critique ou sérieuse.

## P1 — Architecture, API et qualité

### 5. Centraliser la configuration et compléter l'aide CLI — M

Créer `local/config.py` comme source unique pour la lecture non exécutable de
`.env`, la validation typée et le contrôle des permissions.

Travail restant :

- partager la même résolution de configuration entre le monitor et le serveur ;
- appliquer l'ordre de priorité : option CLI, variable d'environnement,
  `local/.env`, valeur par défaut ;
- permettre à chaque consommateur de demander uniquement les valeurs nécessaires
  sans afficher les secrets ;
- ajouter `monitor.sh --help` et documenter `--once`, `--loop [SECONDS]`,
  `--check`, `--status-json` et `--fail-fast` ;
- rendre l'aide disponible sans installation ni authentification Codex valide.

Validation :

- les variables d'environnement remplacent bien les valeurs de `.env` ;
- le monitor et l'API utilisent toujours le même `TOKEN_PRICING_FILE` ;
- une ligne `.env` malveillante reste du texte et n'est jamais exécutée ;
- les erreurs de configuration restent lisibles et sans traceback.

### 6. Borner la ventilation Analytics et identifier le catalogue — M

Conserver `schema_version: 1` et ajouter les éléments suivants sans casser les
consommateurs existants :

- l'empreinte SHA-256 du catalogue dans `pricing` ;
- une pagination serveur du tableau application/fournisseur/modèle, avec des
  pages de 50 lignes et une limite maximale de 100 ;
- les métadonnées `offset`, `limit` et `total` associées à cette pagination ;
- les contrôles de pagination correspondants dans `analytics.html`.

Validation :

- une requête sans paramètres de pagination conserve le comportement actuel de
  `tokens.breakdown` ;
- une requête paginée retourne la page dans `tokens.breakdown` avec ses
  métadonnées, sans changer `schema_version` ;
- les nouveaux paramètres répétés, contradictoires ou hors limites retournent
  HTTP 400 ;
- l'empreinte change lorsque le catalogue change ;
- les pages vides sont testées côté API et navigateur.

### 7. Durcir la suite de validation et la CI — M

Travail restant :

- fixer explicitement les versions de Python et Node utilisées en CI ;
- compiler les modules Python dans le workflow ;
- mesurer la couverture des nouveaux modules Python ;
- auditer les dépendances npm ;
- ajouter un test ciblé pour la modification d'un fichier Codex pendant sa
  lecture.

Validation :

- le workflow échoue sur une erreur de compilation, une dépendance vulnérable ou
  une régression de migration/concurrence ;
- les tests restent indépendants du vrai `.env` et du runtime du développeur.

### 8. Corriger les derniers écarts de documentation — S

Travail restant :

- remplacer les URL de clonage génériques par
  `https://github.com/AlexandreDor/ai-usage-monitor.git` ;
- aligner les exemples de logs Gist sur la sortie réelle du monitor ;
- compléter la structure du projet avec les modules Python, `tests/` et la CI ;
- préciser qu'un Gist secret est non répertorié, mais pas privé ;
- mettre à jour la référence de configuration après les chantiers 2 et 5.

Validation :

- toutes les commandes documentées sont exécutables telles quelles ;
- aucune procédure ne demande d'exécuter `.env` avec `source` ;
- les chemins, options et messages cités correspondent au dépôt.

## P2 — Distribution et maintenance

### 9. Préparer des releases installables — M

Travail restant :

- ajouter des unités systemd versionnées pour le monitor et le dashboard ;
- les vérifier avec `systemd-analyze verify` ;
- créer `CHANGELOG.md` et définir une politique de version ;
- publier des tags et des archives accompagnées de checksums ;
- documenter installation, mise à jour, retour arrière, sauvegarde, restauration
  et désinstallation.

Validation :

- une installation neuve et une mise à jour depuis la version précédente sont
  reproductibles ;
- le retour arrière conserve la configuration et les archives locales ;
- les checksums publiés correspondent aux archives de release.

### 10. Réduire le reste de `monitor.sh` — L

Ce chantier vient après l'extraction de l'historique et de la configuration afin
d'éviter deux migrations concurrentes du même code.

Travail restant :

- déplacer le protocole `codex app-server` vers `local/codex_status.py` ;
- isoler les interfaces externes et les effets de bord restants ;
- conserver Bash comme lanceur et orchestrateur léger ;
- préserver les formats JSON, les options CLI et les codes de sortie existants.

Validation :

- les fixtures Codex existantes passent sans modification de comportement ;
- `monitor.sh` ne contient plus de bloc Python inline métier ;
- les erreurs et timeouts restent identiques du point de vue utilisateur.

## P3 — Évolutions différées

Ces sujets ne doivent commencer qu'après les chantiers P0 et P1 :

- endpoint de santé et export Prometheus ;
- agrégation quotidienne pour les historiques très longs ;
- fuseau horaire configurable.

## Définition de terminé

Un chantier est terminé lorsque :

- le chemin principal et les principaux échecs ont des tests de non-régression ;
- aucune erreur ne provoque de perte silencieuse ;
- les migrations, lorsqu'il y en a, sont rétrocompatibles et disposent d'une
  stratégie de retour arrière ;
- la CI valide le changement ;
- la documentation utilisateur est à jour ;
- aucune donnée privée, chemin local, identité de compte ou secret n'est ajouté
  aux fichiers ou API exposés.

## Clôture

Les contrôles de clôture ont été exécutés: tests shell, Python et Node,
couverture bloquante, compilation Python, `bash -n`, ShellCheck, `git diff
--check`, `npm audit`, Playwright avec axe-core, vérification systemd,
installation/mise à jour/rollback, sauvegarde/restauration, désinstallation
avec conservation des données, reproductibilité des archives et validation des
checksums.
