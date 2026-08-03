# Feuille de route des améliorations

Cette feuille de route regroupe les améliorations identifiées lors de l'audit du projet. Elle privilégie d'abord la fiabilité de la collecte et des alertes, puis la qualité du code, l'expérience utilisateur et les nouvelles fonctionnalités.

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

**Statut : différé.** La politique actuelle est conservée en attendant la conception des calculs d'utilisation à long terme.

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

**Actions :**

- Versionner les scripts avec le bit exécutable.
- Ajouter des unités systemd réelles et les vérifier avec `systemd-analyze verify`.
- Ajouter `CHANGELOG.md`, des tags et une politique de version.
- Publier des archives de release avec checksums.
- Documenter installation, mise à jour, retour arrière et désinstallation.

**Effort : M**

### 16. Réduire progressivement le script monolithique

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

## Plan d'exécution recommandé

### Phase 1 - Stabilisation

1. Fiabiliser les appels réseau.
2. Corriger les alertes de seuil.
3. Ajouter le verrou global.
4. Détecter les données périmées.

### Phase 2 - Robustesse des données

1. Rendre la rétention temporelle.
2. Renforcer le parsing Codex.
3. Valider toute la configuration.
4. Améliorer l'observabilité.

### Phase 3 - Qualité continue

1. Isoler les effets de bord.
2. Étendre les tests.
3. Ajouter la CI.
4. Ajouter les tests HTTP et navigateur.

### Phase 4 - Dashboard et sécurité

1. Rendre le dashboard autonome.
2. Corriger et optimiser le graphique.
3. Améliorer l'accessibilité.
4. Sécuriser l'exposition réseau.

### Phase 5 - Distribution et fonctionnalités

1. Corriger la documentation.
2. Préparer le packaging et les releases.
3. Réduire progressivement le script monolithique.
4. Ajouter les nouvelles fonctionnalités selon les besoins utilisateurs.

## Définition globale de terminé

Une amélioration est considérée comme terminée lorsque :

- son comportement attendu est documenté ;
- les erreurs sont explicites et ne provoquent pas de perte silencieuse ;
- un test de non-régression couvre le chemin principal et les principaux échecs ;
- la CI valide le changement ;
- la documentation utilisateur est mise à jour ;
- aucun secret ou identifiant de compte n'est ajouté aux données exposées.
