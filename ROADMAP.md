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

### 18. Estimer la valeur implicite de la limite hebdomadaire dans Analytics

Analytics doit afficher l'évolution de la valeur totale estimée de la limite
hebdomadaire à partir de la consommation observée, valorisée aux prix API, et
de la part de quota consommée ou perdue sur une fenêtre glissante d'une heure.
La formule conceptuelle est : **valeur totale implicite = coût API moyen ou
observé sur la fenêtre glissante de 1 h / fraction de la limite hebdomadaire
consommée sur cette même fenêtre**. Le pourcentage de quota doit être converti
en fraction avant le calcul (par exemple, 2 % devient 0,02) et l'unité monétaire
doit rester explicite.
Dans la table Analytics « Reset history » / « Previous limit resets », ajouter
deux colonnes explicitement en dollars : « Estimated cycle cost ($) », qui
indique l'équivalent en coût API estimé de la consommation effectivement
observée pendant le cycle terminé, et « Extrapolated 100% value ($) », qui
indique la valeur extrapolée à 100 % lorsque le reset a eu lieu alors qu'il
restait du quota. Cette extrapolation suit la formule conceptuelle **coût
estimé du cycle / fraction de quota consommée avant reset**.

**Actions :**

- Alimenter Analytics avec le coût API moyen ou observé et la part de quota
  consommée ou perdue correspondants à la même fenêtre glissante d'une heure.
- Tracer dans un graphique l'évolution de l'estimation et indiquer sa devise,
  sa fenêtre d'observation ainsi que, lorsque c'est possible, son niveau de
  confiance ou sa qualité de données.
- Segmenter les observations par `limit_id` et invalider la comparaison lors
  d'un reset ou d'un changement de limite, plutôt que de relier des fenêtres
  incomparables.
- Enrichir la table « Reset history » / « Previous limit resets » avec les
  colonnes « Estimated cycle cost ($) » et « Extrapolated 100% value ($) » ;
  calculer la seconde à partir du coût du cycle et de la fraction consommée
  avant reset, en la présentant surtout lorsqu'un quota restait disponible.
- Prévoir un seuil minimal de données et un traitement des pics ou du bruit
  afin que l'estimation reste lisible sans masquer une incertitude réelle.
- Refuser la division par zéro et gérer les coûts, pourcentages, prix ou
  relevés manquants ou invalides ; afficher clairement l'indisponibilité ou
  l'incertitude et sa cause au lieu d'une valeur trompeuse.
- Si la fraction consommée est nulle, si les données ou les prix sont
  incomplets, ou si le reset ou le `limit_id` est ambigu, afficher une valeur
  indisponible ou qualifiée plutôt qu'une extrapolation trompeuse.

**Critères de validation :**

- Le graphique Analytics montre la tendance de la valeur totale implicite avec
  une unité monétaire et une fenêtre glissante d'une heure clairement
  identifiables.
- Le calcul vérifié sur des valeurs connues applique bien la conversion du
  pourcentage en fraction et la formule documentée, sans mélange de fenêtres ou
  de `limit_id`.
- La table « Reset history » / « Previous limit resets » expose les deux
  colonnes en dollars ; « Estimated cycle cost ($) » correspond à la
  consommation observée du cycle terminé et « Extrapolated 100% value ($) »
  applique bien **coût estimé du cycle / fraction de quota consommée avant
  reset** lorsqu'un quota restait disponible.
- Un dénominateur nul, des données insuffisantes, un reset ou changement de
  `limit_id`, des prix absents et des relevés invalides rendent l'estimation
  indisponible ou explicitement incertaine, avec un message compréhensible.
- Les pics et le bruit ne produisent pas de valeur présentée comme fiable sans
  signalement ; les cas de fenêtre vide, de transition de limite et de données
  périmées sont couverts par des tests.

**Effort : M**

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
retirées de cette liste car elles sont déjà implémentées.

## Ordre d'exécution recommandé

1. Ajouter la détection des données périmées au dashboard principal.
2. Détecter les anomalies de quota.
3. Centraliser la configuration partagée.
4. Finaliser WAL et les sauvegardes SQLite.
5. Terminer l'accessibilité du dashboard.
6. Renforcer la CI.
7. Ajouter dans Analytics l'estimation de la valeur implicite de la limite
   hebdomadaire.
8. Préparer les releases et le packaging.
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
- Analytics présente une estimation explicitement qualifiée de la valeur
  implicite de la limite hebdomadaire sur une fenêtre glissante d'une heure ;
- les tests shell, Python, HTTP et navigateur passent en CI ;
- la distribution comprend une version, un changelog, des unités systemd et des
  archives vérifiables.
