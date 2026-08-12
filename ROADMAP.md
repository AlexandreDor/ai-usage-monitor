# Feuille de route des améliorations restantes

Cette feuille de route ne contient que les travaux qui restent à réaliser. Les
fonctionnalités déjà livrées ont été retirées au lieu d'être conservées avec un
statut `terminé`, et les anciennes spécifications consolidées ont été fusionnées
avec les objectifs correspondants afin d'éviter les doublons.

Le programme conserve les choix structurants suivants :

- Bash et Python standard library ;
- une architecture locale sans nouveau service cloud ;
- SQLite comme archive longue durée ;
- le dashboard principal et Analytics comme interfaces séparées ;
- la synchronisation Gist limitée aux données de quotas ;
- Linux et WSL comme environnements cibles.

Le multi-compte et les nouvelles plateformes de notification restent différés
jusqu'à la stabilisation du socle.

## Échelle d'effort

| Taille | Estimation |
|---|---:|
| XS | Moins d'une demi-journée |
| S | Entre une demi-journée et une journée |
| M | Entre deux et quatre jours |
| L | Une semaine ou plus |

## P0 - Fiabilité critique

### 1. Détecter les données périmées dans le dashboard principal

Analytics expose déjà la fraîcheur de ses données et de ses collecteurs. Le
dashboard principal considère encore un fichier JSON lisible comme valide quel
que soit son âge.

**Actions :**

- Comparer `scraped_at` à `sample_interval_seconds`.
- Afficher un avertissement après environ deux intervalles sans mise à jour.
- Distinguer visuellement les états `LOCAL`, `EXTERNAL` et `STALE`.
- Afficher l'âge réel des données dans une région `aria-live`.
- Conserver les dernières valeurs valides pendant une erreur de rafraîchissement.

**Critères de validation :**

- Des données anciennes sont distinguées des données fraîches sans dépendre
  uniquement de la couleur.
- Le dashboard indique depuis combien de temps la collecte est arrêtée.
- Une nouvelle collecte réussie restaure automatiquement l'état normal.
- Les états frais, périmés et en erreur sont couverts par les tests navigateur.

**Effort : S**

### 2. Suivre la livraison des alertes séparément par canal

L'état actuel sait rejouer une alerte en attente, mais considère la livraison
réussie dès qu'un canal a fonctionné. Il ne mémorise pas le résultat de Discord
et Telegram séparément pour une même alerte.

**Actions :**

- Donner un `alert_id` stable à chaque alerte.
- Conserver, pour chaque canal configuré, un état `pending`, `delivered` ou
  `failed`.
- Considérer l'alerte entièrement livrée uniquement lorsque tous les canaux
  configurés ont réussi.
- Ne pas retenter les erreurs HTTP 4xx permanentes ; retenter les erreurs 429,
  5xx et les timeouts en respectant `Retry-After`.
- Migrer les anciens états sans rejouer une alerte déjà livrée.
- Exclure les tokens et URL sensibles des diagnostics persistés.

**Critères de validation :**

- La réussite de Discord ne masque pas l'échec de Telegram, et inversement.
- Seuls les canaux encore en attente sont rejoués au cycle suivant.
- Les migrations depuis les formats d'état existants sont testées.
- Les réponses 4xx, 429, 5xx et les timeouts sont couvertes.

**Effort : M**

### 3. Accélérer les relevés pendant la consultation du dashboard

Lorsqu'un utilisateur consulte le dashboard local, le relevé principal doit être
actualisé toutes les 5 minutes, sans augmenter la densité de l'historique ni des
graphiques.

**Actions :**

- Faire signaler au serveur qu'un dashboard local est visible et actif.
- Conserver un heartbeat borné dans `runtime/`, sans identifiant utilisateur ni
  historique de navigation.
- Passer temporairement la collecte des quotas à un intervalle de 5 minutes
  lorsqu'une activité récente est détectée.
- Mettre à jour uniquement le snapshot principal lors des relevés
  intermédiaires.
- Continuer à alimenter `history.json`, SQLite et les séries graphiques avec au
  plus un point toutes les 15 minutes.
- Revenir automatiquement à l'intervalle normal après la fermeture ou
  l'inactivité du dashboard.
- Limiter cette fonction au mode local ; le dashboard statique/Gist ne doit pas
  nécessiter de callback vers le monitor.

**Critères de validation :**

- Un dashboard local actif obtient une nouvelle valeur au plus toutes les
  5 minutes.
- Une consultation prolongée ne crée jamais plus d'un point graphique par
  tranche de 15 minutes.
- La fermeture de la page restaure automatiquement la fréquence normale.
- Plusieurs onglets ne provoquent ni collectes concurrentes ni multiplication
  des points.
- Les alertes et la détection de fraîcheur utilisent explicitement la fréquence
  réellement applicable.

**Effort : M à L**

## P1 - Robustesse et qualité

### 4. Alerter sur les mouvements de quota anormaux

Le monitor reconnaît déjà les resets planifiés et certains resets hebdomadaires
anticipés. Il ne signale pas encore les variations incohérentes qui ne
correspondent pas à un reset identifiable.

**Actions :**

- Détecter une augmentation du quota sans reset ni changement de groupe de
  limites.
- Détecter un déplacement significatif de la date de reset sans remontée du
  quota.
- Signaler une date de reset qui recule dans le passé, oscille de manière
  répétée ou disparaît alors que la fenêtre était disponible.
- Comparer uniquement des observations cohérentes appartenant au même
  `limit_id`.
- Ajouter des tolérances et, lorsque nécessaire, une confirmation sur deux
  relevés pour éviter les faux positifs.
- Dédupliquer les alertes et conserver dans SQLite leur type, leur date de
  détection ainsi que les valeurs avant et après.

**Critères de validation :**

- Un reset planifié, un reset hebdomadaire anticipé reconnu ou un changement de
  `limit_id` ne produit pas d'alerte d'anomalie.
- Une hausse isolée du quota et un déplacement isolé de la date sont signalés
  avec une explication compréhensible.
- Une oscillation ne déclenche pas la même alerte à chaque cycle.
- Les anomalies des fenêtres 5 heures et hebdomadaire sont couvertes par des
  tests.

**Effort : M**

### 5. Rendre l'historique JSON réellement temporel

L'archive SQLite applique déjà une rétention temporelle et un compactage. Le
fichier `history.json` du dashboard principal reste géré inline dans
`monitor.sh` et tronqué selon un nombre d'entrées dérivé de l'intervalle courant.

**Actions :**

- Extraire la gestion de l'historique dans `local/history.py`.
- Valider les snapshots et normaliser leurs timestamps en epoch.
- Refuser les pourcentages hors de l'intervalle `0..100`.
- Trier et dédupliquer selon le timestamp réel.
- Appliquer `HISTORY_RETENTION_HOURS` selon l'âge des relevés.
- Écrire atomiquement et sauvegarder sous un nom unique tout historique
  corrompu.
- Conserver un plafond défensif de 10 000 entrées et 16 MiB.

**Critères de validation :**

- La durée conservée reste correcte après une interruption ou un changement
  d'intervalle `900 -> 60 -> 900`.
- Une corruption ne provoque pas la perte silencieuse de l'historique.
- Les entrées invalides, dupliquées, trop anciennes ou trop nombreuses sont
  traitées sans crash.

**Effort : S à M**

### 6. Centraliser la configuration partagée

La configuration est validée par le monitor et `serve.sh` sait déjà relire le
catalogue tarifaire sans exécuter `.env`. Cette logique reste toutefois répartie
entre plusieurs scripts.

**Actions :**

- Créer `local/config.py` pour lire `.env` comme des données et effectuer la
  validation typée et le contrôle des permissions.
- Partager les valeurs nécessaires entre le monitor et le serveur.
- Appliquer partout l'ordre de priorité suivant : option CLI, variable
  d'environnement, `local/.env`, valeur par défaut.
- Conserver des messages d'erreur lisibles sans traceback ni secret.

**Critères de validation :**

- Le monitor et le serveur interprètent de la même manière une configuration
  valide ou invalide.
- Un fichier `.env` n'est jamais exécuté comme du code shell.
- Les priorités et les cas de variables incomplètes sont testés.

**Effort : M**

### 7. Finaliser la durabilité et la concurrence SQLite

La migration v1 vers v2, le rejet des versions inconnues, `quick_check`,
`busy_timeout` et un test de lecture/écriture concurrente sont en place. La base
utilise encore le journal `DELETE` et aucune sauvegarde pré-migration n'est
créée.

**Actions :**

- Sauvegarder une base existante avant toute migration susceptible de
  l'altérer.
- Passer progressivement du journal `DELETE` à `WAL`.
- Gérer explicitement les erreurs `locked` avec des retries bornés.
- Nettoyer les fichiers WAL de manière contrôlée lors des opérations de
  récupération ou de maintenance.

**Critères de validation :**

- Une migration conserve les snapshots et laisse une sauvegarde récupérable.
- Les lectures Analytics restent disponibles pendant les écritures du monitor.
- Les scénarios de verrouillage, checkpoint et récupération WAL sont testés.

**Effort : M**

### 8. Compléter les métadonnées du catalogue Analytics

Le contrat Analytics v1, la période effective, la granularité, la fraîcheur, les
bornes de réponse et les erreurs HTTP 400/503 sont déjà implémentés. Il manque
encore l'empreinte du catalogue utilisé pour produire l'estimation.

**Actions :**

- Ajouter l'empreinte SHA-256 du catalogue dans l'objet `pricing` sans rompre
  `schema_version: 1`.
- Documenter le champ et vérifier qu'il ne révèle aucun chemin local.
- Tester le catalogue par défaut et un catalogue personnalisé.

**Effort : XS**

### 9. Terminer les derniers éléments de l'interface Analytics

Les graphiques, les marqueurs de reset, les séries par application, la bascule
tokens/coût, les cartes principales et les tableaux alternatifs sont déjà en
place. Deux éléments de la spécification initiale restent absents.

**Actions :**

- Ajouter une carte distincte pour les tokens associés à un modèle sans tarif.
- Paginer le tableau par application, fournisseur et modèle par groupes de
  50 lignes.
- Conserver l'indication explicite que le coût est une estimation API et que le
  reasoning est inclus dans l'output.

**Critères de validation :**

- Les tokens sans tarif restent visibles sans être ajoutés au coût estimé.
- Un résultat de plus de 50 groupes reste navigable au clavier sans réponse API
  démesurée.
- La pagination et le changement de langue sont couverts par les tests
  navigateur.

**Effort : S**

### 10. Ajouter un lien vers Codex Forecast

Ajouter au dashboard un accès explicite à
`https://codex.lunarwerx.com/`, qui fournit une prévision statistique globale des
resets Codex. Ce lien doit rester clairement distinct des échéances personnelles
du compte surveillé.

**Actions :**

- Ajouter un lien « Prévisions globales des resets » dans l'interface du
  dashboard.
- Indiquer visuellement qu'il s'agit d'un service tiers et d'un lien externe.
- Ouvrir le lien avec `rel="noopener noreferrer"`.
- Traduire son libellé en français et en anglais.

**Critères de validation :**

- Le lien est accessible au clavier et compréhensible hors contexte.
- L'interface ne présente pas la prévision globale comme la date de reset du
  compte local.
- L'ajout ne modifie pas la CSP ni le caractère autonome du dashboard.

**Effort : XS**

### 11. Compléter les contrôles de qualité de la CI

La CI exécute déjà les tests shell, Python, HTTP et navigateur ainsi que
ShellCheck. Les contrôles de distribution et de couverture restent à ajouter.

**Actions :**

- Fixer explicitement les versions de Python et Node utilisées par la CI.
- Compiler les modules Python avant les tests.
- Mesurer la couverture utile des modules Python.
- Auditer les dépendances npm et les migrations.
- Ajouter une vérification `systemd-analyze verify` lorsque les unités systemd
  seront disponibles.

**Critères de validation :**

- Chaque pull request exécute les contrôles avec des versions reproductibles.
- Une erreur de syntaxe Python, une migration cassée ou une vulnérabilité de
  dépendance détectable fait échouer la CI.

**Effort : S à M**

## P2 - Expérience utilisateur et maintenance

### 12. Terminer l'accessibilité du dashboard principal

Analytics possède déjà des résumés et tableaux alternatifs, des régions
`aria-live` et une navigation clavier. Le dashboard principal n'offre pas encore
de résumé accessible de son graphique, et les détails d'allure reposent encore
en partie sur l'attribut `title`.

**Actions :**

- Fournir un résumé textuel et un tableau alternatif de l'historique.
- Donner aux jauges des labels accessibles complets.
- Afficher les détails d'allure dans le contenu visible.
- Vérifier la navigation clavier et l'état sans couleur.

**Critères de validation :**

- Le quota, l'allure, la fraîcheur et l'historique sont compréhensibles sans
  graphique, couleur ou attribut `title`.
- Les scénarios historique vide, données périmées et graphique indisponible
  passent les tests Playwright et axe-core.

**Effort : M**

### 13. Finaliser l'aide CLI du monitor

Les modes `--once`, `--loop [SECONDS]`, `--check`, `--status-json` et
`--fail-fast` sont implémentés, mais `monitor.sh` ne fournit pas encore d'aide
intégrée.

**Actions :**

- Ajouter `--help` et `-h` sans initialiser la configuration ni contacter Codex.
- Décrire les modes, leurs incompatibilités et les valeurs par défaut.
- Tester la sortie et le code de retour.

**Effort : XS**

### 14. Mettre la documentation en cohérence

**Actions :**

- Remplacer les URL de clonage génériques par l'URL canonique du dépôt.
- Vérifier les procédures LXC, systemd et GitHub Pages avec les noms et chemins
  actuels.
- Expliquer les états de fraîcheur et le suivi par canal des alertes.
- Documenter la sauvegarde et la restauration de SQLite, y compris le mode WAL.
- Maintenir la référence de configuration avec les changements de `config.py`.

**Effort : S**

### 15. Préparer le packaging et les releases

**Actions :**

- Ajouter des unités systemd réelles prêtes à être validées par la CI.
- Ajouter `CHANGELOG.md`, des tags et une politique de version.
- Publier des archives de release avec checksums.
- Documenter installation, mise à jour, retour arrière et désinstallation.

**Effort : M**

### 16. Réduire progressivement le script monolithique

Le stockage, l'archivage et la collecte Analytics sont déjà séparés en modules
Python. Le protocole Codex, la validation principale et l'orchestration restent
concentrés dans `monitor.sh`.

**Objectif :** améliorer la testabilité sans lancer une réécriture prématurée.

**Actions :**

- Définir un schéma versionné pour les snapshots et l'historique JSON.
- Déplacer progressivement le protocole Codex et la validation vers des modules
  Python testables.
- Conserver Bash comme lanceur léger tant que cela reste utile.

**Effort : L**

## P3 - Évolutions fonctionnelles différées

Ces évolutions viendront après la stabilisation des fonctions existantes :

- support de plusieurs comptes Codex ;
- notifications Slack, ntfy ou e-mail ;
- endpoint de santé et export Prometheus ;
- agrégation quotidienne pour les historiques longs ;
- fuseau horaire configurable ;
- mode simulation avec fixtures anonymisées pour développer sans compte Codex.

La langue et la devise configurables ainsi que les commandes `--check`,
`--once`, `--loop`, `--status-json`, `--fail-fast`, `--bind` et `--port` ont été
retirées de cette liste car elles sont déjà implémentées. Seule l'aide intégrée
du monitor reste à ajouter dans l'objectif 13.

## Ordre d'exécution recommandé

1. Ajouter la détection des données périmées et le rafraîchissement adaptatif au
   dashboard principal.
2. Fiabiliser le suivi des alertes par canal, puis détecter les anomalies de
   quota.
3. Extraire l'historique JSON et centraliser la configuration.
4. Finaliser WAL, les sauvegardes SQLite et l'empreinte du catalogue.
5. Terminer les éléments Analytics restants et intégrer le lien vers Codex
   Forecast.
6. Terminer l'accessibilité du dashboard.
7. Renforcer la CI.
8. Ajouter l'aide CLI, corriger la documentation et préparer les releases.
9. Réduire progressivement le script monolithique.
10. Ajouter les évolutions P3 selon les besoins utilisateurs.

## Définition globale de terminé

Une amélioration est considérée comme terminée lorsque :

- son comportement attendu est documenté ;
- les erreurs sont explicites et ne provoquent pas de perte silencieuse ;
- un test de non-régression couvre le chemin principal et les principaux échecs ;
- la CI valide le changement ;
- la documentation utilisateur est mise à jour ;
- aucun secret, chemin local ou identifiant de compte n'est ajouté aux données
  exposées.

Le programme restant est terminé lorsque :

- le dashboard principal détecte et annonce les données périmées ;
- un dashboard local actif actualise le relevé principal toutes les 5 minutes
  sans densifier les historiques ;
- l'historique JSON applique une rétention temporelle robuste ;
- les alertes sont suivies indépendamment pour chaque canal ;
- les mouvements de quota anormaux sont détectés sans confondre les resets
  légitimes ;
- le monitor et le serveur partagent une configuration non exécutable ;
- SQLite est sauvegardé avant migration et fonctionne de manière fiable en WAL ;
- le catalogue Analytics est identifiable par son empreinte ;
- les tests shell, Python, HTTP et navigateur passent en CI ;
- la distribution comprend une version, un changelog, des unités systemd et des
  archives vérifiables.
