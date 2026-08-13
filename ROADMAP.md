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
- Conserver le contexte `LOCAL` ou `EXTERNAL` des dernières valeurs valides et
  annoncer séparément une erreur de rafraîchissement.

**Critères de validation :**

- Des données anciennes sont distinguées des données fraîches sans dépendre
  uniquement de la couleur.
- Le dashboard indique depuis combien de temps la collecte est arrêtée.
- Une nouvelle collecte réussie restaure automatiquement l'état normal.
- Les états frais, périmés et en erreur sont couverts par les tests navigateur.

**Effort : S**

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
- Généraliser aux anomalies la segmentation par `limit_id` déjà utilisée pour
  les resets hebdomadaires anticipés.
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

### 6. Centraliser la configuration partagée

La configuration est validée par le monitor et `serve.sh` sait déjà relire le
catalogue tarifaire sans exécuter `.env`. Cette logique reste toutefois répartie
entre plusieurs scripts.

**Actions :**

- Extraire dans `local/config.py` les parseurs et validations déjà présents dans
  `monitor.sh` et `serve.sh`, y compris les contrôles de permissions et de
  liens symboliques.
- Partager les valeurs nécessaires entre le monitor et le serveur.
- Appliquer partout l'ordre de priorité suivant : option CLI, variable
  d'environnement, `local/.env`, valeur par défaut.
- Conserver des messages d'erreur lisibles sans traceback ni secret.

**Critères de validation :**

- Le monitor et le serveur interprètent de la même manière une configuration
  valide ou invalide.
- La garantie existante qu'un fichier `.env` n'est jamais exécuté comme du code
  shell ne régresse pas.
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
- Paginer côté serveur le tableau par application, fournisseur et modèle par
  groupes de 50 lignes, avec un total et un offset bornés.

**Critères de validation :**

- Les tokens sans tarif restent visibles sans être ajoutés au coût estimé.
- Un résultat de plus de 50 groupes reste navigable au clavier sans réponse API
  démesurée.
- L'indication existante que le coût est une estimation API et que le reasoning
  est inclus dans l'output ne régresse pas.
- La pagination et le changement de langue sont couverts par les tests
  navigateur.

**Effort : S**

### 12. Compléter les contrôles de qualité de la CI

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

### 13. Terminer l'accessibilité du dashboard principal

Analytics possède déjà des résumés et tableaux alternatifs, des régions
`aria-live` et une navigation clavier. Le dashboard principal n'offre pas encore
de résumé accessible de son graphique, et les détails d'allure reposent encore
en partie sur l'attribut `title`.

**Actions :**

- Fournir un résumé textuel et un tableau alternatif de l'historique.
- Donner aux jauges des labels accessibles complets.
- Afficher dans le contenu visible les valeurs réelle et idéale encore limitées
  à l'attribut `title`, en plus du delta déjà visible.
- Vérifier la navigation clavier et l'état sans couleur.

**Critères de validation :**

- Le quota, l'allure, la fraîcheur et l'historique sont compréhensibles sans
  graphique, couleur ou attribut `title`.
- Les scénarios historique vide, données périmées et graphique indisponible
  passent les tests Playwright et axe-core.

**Effort : M**

### 14. Finaliser l'aide CLI du monitor

Les modes `--once`, `--loop [SECONDS]`, `--check`, `--status-json` et
`--fail-fast` sont implémentés, mais `monitor.sh` ne fournit pas encore d'aide
intégrée.

**Actions :**

- Ajouter `--help` et `-h` sans initialiser la configuration ni contacter Codex.
- Décrire les modes, leurs incompatibilités et les valeurs par défaut.
- Tester la sortie et le code de retour.

**Effort : XS**

### 15. Mettre la documentation en cohérence

**Actions :**

- Remplacer les URL de clonage génériques par l'URL canonique du dépôt.
- Vérifier les procédures LXC, systemd et GitHub Pages avec les noms et chemins
  actuels.
- Supprimer ou synchroniser la liste d'idées du README avec la section P3 afin
  d'éviter deux feuilles de route divergentes.
- Expliquer les états de fraîcheur.
- Documenter la sauvegarde et la restauration de SQLite, y compris le mode WAL.
- Maintenir la référence de configuration avec les changements de `config.py`.

**Effort : S**

### 16. Préparer le packaging et les releases

**Actions :**

- Ajouter des unités systemd réelles prêtes à être validées par la CI.
- Ajouter `CHANGELOG.md`, définir une politique SemVer et publier le premier tag
  conformément à cette politique.
- Publier des archives de release avec checksums.
- Documenter installation, mise à jour, retour arrière et désinstallation.

**Effort : M**

### 17. Réduire progressivement le script monolithique

Le stockage, l'historique, l'archivage et la collecte Analytics sont déjà
séparés en modules Python. Le protocole Codex, la validation principale et
l'orchestration restent concentrés dans `monitor.sh`.

**Objectif :** améliorer la testabilité sans lancer une réécriture prématurée.

**Actions :**

- Définir un schéma versionné pour les snapshots et l'historique JSON.
- Déplacer progressivement le protocole Codex et la validation vers des modules
  Python testables.
- Extraire en priorité `config.py` et un client du protocole Codex, puis limiter
  Bash au parsing CLI et à l'orchestration.

**Effort : L**

## P3 - Évolutions fonctionnelles différées

Ces évolutions viendront après la stabilisation des fonctions existantes :

- support de plusieurs comptes Codex ;
- notifications Slack, ntfy ou e-mail ;
- exposition contrôlée des données déjà maintenues dans `runtime/health.json`,
  puis export Prometheus distinct ;
- rollups quotidiens persistants pour les historiques longs ;
- fuseau horaire configurable ;
- transformation des fixtures anonymisées existantes en mode simulation
  documenté pour développer sans compte Codex, sans notification ni Gist par
  défaut.

La langue et la devise configurables ainsi que les commandes `--check`,
`--once`, `--loop`, `--status-json`, `--fail-fast`, `--bind` et `--port` ont été
retirées de cette liste car elles sont déjà implémentées. Seule l'aide intégrée
du monitor reste à ajouter dans l'objectif 14.

## Ordre d'exécution recommandé

1. Ajouter la détection des données périmées au dashboard principal.
2. Détecter les anomalies de quota.
3. Centraliser la configuration partagée.
4. Finaliser WAL, les sauvegardes SQLite et l'empreinte du catalogue.
5. Terminer les éléments Analytics restants.
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
- les mouvements de quota anormaux sont détectés sans confondre les resets
  légitimes ;
- le monitor et le serveur partagent une configuration non exécutable ;
- SQLite est sauvegardé avant migration et fonctionne de manière fiable en WAL ;
- le catalogue Analytics est identifiable par son empreinte ;
- les tests shell, Python, HTTP et navigateur passent en CI ;
- la distribution comprend une version, un changelog, des unités systemd et des
  archives vérifiables.
