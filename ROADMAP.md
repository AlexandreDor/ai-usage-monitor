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
3. Finaliser WAL et les sauvegardes SQLite.
4. Terminer l'accessibilité du dashboard.
5. Renforcer la CI.
6. Préparer les releases et le packaging.
7. Réduire progressivement le script monolithique.
8. Ajouter les évolutions P3 selon les besoins utilisateurs.

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
- SQLite est sauvegardé avant migration et fonctionne de manière fiable en WAL ;
- les tests shell, Python, HTTP et navigateur passent en CI ;
- la distribution comprend une version, un changelog, des unités systemd et des
  archives vérifiables.
