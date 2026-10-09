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

## P3 - Évolutions fonctionnelles différées

Ces évolutions viendront après la stabilisation des fonctions existantes :

- support de plusieurs comptes Codex ;
- notifications Slack, ntfy ou e-mail ;
- export Prometheus distinct à partir des diagnostics locaux ;
- rollups quotidiens persistants pour les historiques longs ;
- transformation des fixtures anonymisées existantes en mode simulation
  documenté pour développer sans compte Codex, sans notification ni Gist par
  défaut.

Les performances de chargement, diagnostics, exports CSV, comparaisons de
périodes, filtres mémorisés, fuseau et taux EUR configurables, et sauvegardes
planifiées sont implémentés. Les agrégats persistants restent différés : le cache
borné réutilise les calculs sans réduire les événements bruts ni la précision.

La langue et la devise configurables ainsi que les commandes `--check`,
`--once`, `--loop`, `--status-json`, `--fail-fast`, `--bind` et `--port` ont été
retirées de cette liste car elles sont déjà implémentées.

## Ordre d'exécution recommandé

1. Suivre les budgets de chargement et la stabilité sur les archives réelles.
2. Ajouter les évolutions P3 selon les besoins utilisateurs.

## Définition globale de terminé

Une amélioration est considérée comme terminée lorsque :

- son comportement attendu est documenté ;
- les erreurs sont explicites et ne provoquent pas de perte silencieuse ;
- un test de non-régression couvre le chemin principal et les principaux échecs ;
- la CI valide le changement ;
- la documentation utilisateur est mise à jour ;
- aucun secret, chemin local ou identifiant de compte n'est ajouté aux données
  exposées.

Les données périmées et les anomalies de quota sont déjà détectées et testées.
Les tests shell, Python, HTTP, navigateur et performance restent des conditions
de validation pour chaque nouvelle évolution.
