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

## P2 - Expérience utilisateur et maintenance

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
3. Préparer les releases et le packaging.
4. Réduire progressivement le script monolithique.
5. Ajouter les évolutions P3 selon les besoins utilisateurs.

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
- les tests shell, Python, HTTP et navigateur passent en CI ;
- la distribution comprend une version, un changelog, des unités systemd et des
  archives vérifiables.
