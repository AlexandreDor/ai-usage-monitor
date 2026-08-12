# Plan unifié — P0.2 : livraison fiable des alertes par canal

## Résumé

Adopter une architecture séparant la détection des alertes de leur suivi de livraison :

- conserver `.alert_state` pour la détection des seuils, resets, baselines et scripts locaux ;
- créer `local/runtime/alert-deliveries.json` comme source de vérité pour la livraison réseau ;
- centraliser dans `local/alerts.py` les identifiants, la validation du journal, les transitions d’état, la rétention et la classification HTTP ;
- enregistrer chaque occurrence avant tout appel réseau ;
- suivre Discord et Telegram indépendamment ;
- conserver exactement le même message et le même `alert_id` pendant les retries ;
- ne retenter que les canaux `pending`.

Deux adaptations sont intégrées :

1. L’`alert_id` ne dépend pas du timestamp de première observation.
2. Lorsqu’un seuil plus critique apparaît dans le même cycle, il remplace atomiquement le seuil précédent encore en attente.

## Objectifs et périmètre

P0.2 couvre uniquement les notifications réseau Discord et Telegram.

Sont hors périmètre :

- les scripts locaux `ALERT_SCRIPT_N`, qui conservent leur journal one-shot ;
- le dashboard, Analytics, SQLite et les formats publics `data.json`/`history.json` ;
- de nouveaux canaux ;
- la synchronisation Gist, dont le comportement fonctionnel reste inchangé ;
- toute nouvelle dépendance ou tout nouveau service.

Linux et WSL restent les environnements supportés. Python, Bash, curl et la bibliothèque standard sont les seules dépendances.

## Architecture retenue

### Responsabilités de `.alert_state`

Conserver `state_version=4` et les champs actuels pour :

- les baselines de pourcentage ;
- les seuils traités ;
- les seuils actuellement détectés ;
- les resets armés et traités ;
- l’appartenance au `limit_id` hebdomadaire ;
- le journal des scripts locaux.

Le fichier ne stockera plus le détail opérationnel des livraisons Discord/Telegram.

Le lecteur devra néanmoins reconnaître explicitement :

- absence de version : état historique v1 ;
- versions 2, 3 et 4 ;
- version supérieure à 4 : arrêter le traitement des alertes, ne pas réécrire le fichier et n’effectuer aucun envoi.

### Responsabilités du journal de livraison

Créer :

```text
local/runtime/alert-deliveries.json
```

Ce journal est la source de vérité pour :

- les occurrences d’alertes réseau ;
- leur message immuable ;
- les canaux requis ;
- les tentatives et résultats par canal ;
- les délais `Retry-After` ;
- les états terminaux ;
- la réconciliation avec `.alert_state`.

Le verrou global déjà pris par `monitor.sh` reste la protection contre plusieurs écrivains.

## Schéma du journal

Utiliser un document JSON de version 1 :

```json
{
  "schema_version": 1,
  "legacy_migration": {
    "source_state_version": 4,
    "completed_at": 1786599000
  },
  "alerts": [
    {
      "alert_id": "a1b2c3d4e5f60718293a4b5c",
      "kind": "threshold",
      "window": "5h",
      "selector": "25",
      "cycle_key": "limit:default|reset:1786608000",
      "message": "*Codex 5h limit at 23% remaining* ...",
      "event_data": {
        "limit_id": "default",
        "remaining_pct": 23,
        "reset_epoch": 1786608000,
        "covered_thresholds": [75, 50, 25]
      },
      "created_at": 1786599000,
      "expires_at": 1786608000,
      "status": "pending",
      "terminal_reason": null,
      "replacement_alert_id": null,
      "channels": {
        "discord": {
          "status": "delivered",
          "attempt_count": 1,
          "last_attempt_at": 1786599001,
          "next_attempt_at": 0,
          "last_http_status": 204,
          "last_curl_code": 0,
          "error_class": null
        },
        "telegram": {
          "status": "pending",
          "attempt_count": 3,
          "last_attempt_at": 1786599002,
          "next_attempt_at": 1786599900,
          "last_http_status": 503,
          "last_curl_code": 0,
          "error_class": "server_error"
        }
      },
      "completed_at": null,
      "detector_acknowledged_at": null
    }
  ]
}
```

### Valeurs autorisées

Types d’événement :

```text
threshold
reset
```

Fenêtres :

```text
5h
weekly
```

États d’un canal :

```text
pending
delivered
failed
```

États agrégés :

- `delivered` si tous les canaux requis sont livrés ;
- `pending` tant qu’au moins un canal est en attente ;
- `failed` lorsqu’il ne reste aucun canal en attente et qu’au moins un a échoué.

Classes d’erreur :

```text
client_error
rate_limited
server_error
timeout
transport_error
invalid_response
channel_unconfigured
superseded
expired_after_reset
```

Raisons terminales :

```text
delivered
permanent_failure
superseded
expired_after_reset
channel_unconfigured
```

### Canaux requis

Le champ `channels` contient uniquement les canaux correctement configurés lors de la création.

Règles :

- un canal ajouté ultérieurement ne reçoit pas les alertes historiques ;
- une rotation de credentials conserve le même canal et permet de terminer ses alertes en attente ;
- un canal retiré alors qu’il est `pending` devient `failed/channel_unconfigured` ;
- un canal `delivered` ou `failed` est terminal ;
- aucun canal configuré entraîne un acquittement local immédiat, sans entrée dans le journal.

Aucun secret, endpoint, corps de réponse ou en-tête brut n’est stocké.

## Identifiants stables

Calculer les 24 premiers caractères hexadécimaux de :

```text
SHA-256(
  "alert-v1" + NUL +
  kind + NUL +
  window + NUL +
  selector + NUL +
  cycle_key
)
```

### Clés de cycle

Pour un seuil normal :

```text
limit:<limit_id>|reset:<armed_reset_epoch>
```

Si aucune échéance n’est disponible :

```text
limit:<limit_id>|unarmed
```

Ce fallback conserve la sémantique actuelle : sans reset identifiable, le monitor ne prétend pas distinguer artificiellement deux cycles.

Pour un reset :

```text
limit:<limit_id>|reset:<due_reset_epoch>
```

Pour un reset hebdomadaire anticipé, utiliser l’époque persistée dans `weekly_armed_reset_at`, correspondant à la première observation ayant confirmé le reset.

Pour une migration :

```text
legacy-v<source_version>|limit:<limit_id>|reset:<epoch>
```

ou, sans échéance :

```text
legacy-v<source_version>|limit:<limit_id>|unarmed
```

Le timestamp de première observation reste une métadonnée `created_at`, mais n’entre jamais dans l’identifiant.

## Nouveau module `local/alerts.py`

Créer un module standard-library importable par les tests et exposant une CLI interne.

Commandes :

```text
alerts.py validate JOURNAL
alerts.py init JOURNAL --source-state-version VERSION
alerts.py register JOURNAL
alerts.py due JOURNAL --now EPOCH
alerts.py record JOURNAL
alerts.py terminal-unacknowledged JOURNAL
alerts.py acknowledge JOURNAL ALERT_ID --at EPOCH
alerts.py expire JOURNAL --now EPOCH
alerts.py prune JOURNAL --now EPOCH
alerts.py classify CURL_CODE HTTP_STATUS ATTEMPT BASE_DELAY HEADERS_FILE --now EPOCH
alerts.py telegram-delivered RESPONSE_FILE
```

Les commandes `init`, `register` et `record` reçoivent leurs données structurées en JSON sur stdin. Le message n’est pas passé en argument de processus.

### `register`

La requête contient :

```json
{
  "kind": "threshold",
  "window": "5h",
  "selector": "25",
  "cycle_key": "limit:default|reset:1786608000",
  "message": "...",
  "event_data": {},
  "created_at": 1786599000,
  "expires_at": 1786608000,
  "channels": ["discord", "telegram"],
  "replace_pending_thresholds": true,
  "expire_threshold_cycle": null
}
```

Le traitement doit être atomique et idempotent :

- réutiliser une entrée existante possédant le même ID et le même contenu ;
- refuser le même ID s’il désigne un message ou événement différent ;
- avec `replace_pending_thresholds=true`, enregistrer le nouveau seuil et clôturer dans la même écriture les seuils moins critiques encore `pending` pour la même fenêtre et le même cycle ;
- renseigner `terminal_reason=superseded` et `replacement_alert_id` sur les anciennes occurrences ;
- avec `expire_threshold_cycle`, clôturer les seuils pending du cycle terminé avant d’ajouter l’alerte de reset.

### `due`

Retourner du JSON Lines, trié par :

1. `created_at` ;
2. `alert_id` ;
3. Discord avant Telegram.

Ne retourner que les canaux :

- en état `pending` ;
- dont `next_attempt_at <= now` ;
- encore configurés selon les informations fournies par `monitor.sh`.

### `record`

Journaliser immédiatement chaque tentative HTTP :

- incrémenter `attempt_count` ;
- enregistrer les codes curl/HTTP autorisés ;
- enregistrer la classe d’erreur ;
- passer à `delivered`, `failed` ou conserver `pending` ;
- calculer l’état agrégé ;
- renseigner `completed_at` lorsqu’il devient terminal.

## Persistance et sécurité du journal

Chaque mutation doit :

1. lire et valider entièrement le journal ;
2. produire le document suivant en mémoire ;
3. créer un fichier temporaire dans `runtime/` ;
4. appliquer le mode `0600` ;
5. écrire, vider les buffers et appeler `fsync` ;
6. remplacer atomiquement le journal ;
7. synchroniser le répertoire lorsque la plateforme le permet ;
8. supprimer le temporaire en cas d’échec.

Contraintes :

- journal invalide ou version future : échec fermé, aucun envoi ;
- journal supérieur à 16 MiB : échec explicite, jamais de troncature silencieuse ;
- aucune occurrence `pending` ou terminale non réconciliée ne peut être purgée ;
- conserver les entrées terminales réconciliées pendant 30 jours ;
- conserver au maximum les 500 entrées terminales réconciliées les plus récentes ;
- appliquer la purge uniquement après une réconciliation réussie.

## Flux complet d’un cycle

### 1. Chargement

Sous le verrou global :

1. lire et valider `.alert_state` ;
2. initialiser ou valider le journal ;
3. terminer, si nécessaire, la migration historique ;
4. réconcilier les occurrences terminales non acquittées ;
5. détecter les nouveaux resets et seuils ;
6. enregistrer atomiquement les nouvelles occurrences ;
7. livrer les couples alerte/canal arrivés à échéance ;
8. réconcilier les nouveaux résultats terminaux ;
9. exécuter les scripts locaux selon leur logique actuelle ;
10. persister `.alert_state` ;
11. purger le journal.

Aucun appel réseau ne peut être lancé si l’enregistrement préalable de l’occurrence échoue.

### 2. Seuils

Pour chaque fenêtre :

- conserver au maximum un seuil réseau `pending` par cycle ;
- si aucun seuil plus critique n’est détecté, continuer les retries du seuil existant ;
- si un seuil plus critique est franchi, remplacer atomiquement l’ancien par le nouveau ;
- le nouveau message utilise les valeurs observées lors de sa création et ne sera plus modifié ;
- `covered_thresholds` contient tous les seuils franchis entre la baseline et le seuil critique ;
- une occurrence livrée ou définitivement échouée applique ces marqueurs dans `.alert_state` afin de ne pas être recréée ;
- une occurrence `superseded` n’applique pas elle-même les marqueurs : ils seront couverts par sa remplaçante.

### 3. Resets

Lorsqu’un reset est dû :

- expirer atomiquement tous les seuils encore pending du cycle terminé avec `expired_after_reset` ;
- enregistrer une occurrence de reset distincte ;
- conserver la validité actuelle :
  - cinq heures pour un reset 5h ;
  - sept jours pour un reset weekly ;
- une occurrence de reset dépassant cette fenêtre devient terminale sans nouvel appel réseau ;
- la détection des resets weekly anticipés et la séparation par `limit_id` restent inchangées.

### 4. Ordre des canaux

Pour une même occurrence :

1. Discord ;
2. persistance de son résultat ;
3. Telegram ;
4. persistance de son résultat.

Un échec Discord ne bloque pas Telegram, et inversement.

## Réconciliation entre les deux fichiers

Le journal est autoritaire pour la livraison. `.alert_state` reste autoritaire pour la détection.

`terminal-unacknowledged` retourne les occurrences terminales dont le résultat n’a pas encore été appliqué au détecteur.

Ordre obligatoire :

1. appliquer idempotemment le résultat à `.alert_state` ;
2. persister `.alert_state` atomiquement ;
3. marquer l’occurrence `detector_acknowledged_at`.

Si le processus s’arrête après l’étape 2, la réconciliation sera répétée sans effet secondaire au prochain cycle.

### Application des résultats

Seuil livré ou en échec permanent :

- ajouter `covered_thresholds` à `notified_*_thresholds` ;
- effacer le `pending_*_threshold` correspondant ;
- avancer la baseline jusqu’au `remaining_pct` enregistré ;
- ne jamais déclarer l’alerte livrée si un canal a échoué.

Seuil `superseded` :

- ne pas modifier les marqueurs de seuil ;
- acquitter uniquement l’entrée remplacée dans le journal.

Seuil `expired_after_reset` :

- ne pas ajouter de seuil notifié ;
- laisser la logique du reset réinitialiser le cycle.

Reset livré, définitivement échoué ou expiré :

- mettre à jour le marqueur `last_notified_*_reset_at` comme marqueur terminal de déduplication ;
- ne vider les données d’un cycle que si l’époque correspond encore au reset concerné ;
- ne jamais effacer un nouveau reset déjà armé avec une autre époque.

## Transport HTTP

Séparer clairement :

- une primitive effectuant une seule requête et capturant le résultat ;
- l’orchestrateur de retries des notifications ;
- le wrapper Gist, qui conserve son contrat booléen actuel et ne touche jamais au journal.

Variables internes retournées par une tentative :

```text
HTTP_LAST_CURL_CODE
HTTP_LAST_STATUS
HTTP_LAST_ERROR_CLASS
HTTP_LAST_RETRYABLE
HTTP_LAST_RETRY_DELAY
```

Les fichiers temporaires de réponse, headers et stderr sont privés et supprimés sur tous les chemins de sortie.

### Succès

- Discord : curl réussi et HTTP `204`.
- Telegram : curl réussi, HTTP `200`, JSON objet avec `ok: true`.

### Erreurs permanentes

Une seule tentative :

- HTTP 400–499, sauf 408 et 429 ;
- HTTP 2xx inattendu ;
- HTTP 3xx ;
- Telegram HTTP 200 avec JSON invalide ou `ok` différent de `true` ;
- canal devenu non configuré.

### Erreurs temporaires

- HTTP 408 ;
- HTTP 429 ;
- HTTP 500–599 ;
- timeout curl ;
- autre erreur de transport curl.

Après épuisement des tentatives du cycle, le canal reste `pending`.

## Politique `Retry-After`

Accepter :

- un entier positif ou nul en secondes ;
- une date HTTP ;
- une date passée, interprétée comme délai nul.

Ignorer les valeurs invalides.

Calcul du délai :

1. utiliser `Retry-After` lorsqu’il est valide ;
2. sinon utiliser `CURL_RETRY_DELAY_SECONDS × 2^(tentative-1)` ;
3. borner la valeur persistée à 24 heures.

Comportement :

- délai inférieur ou égal à 60 secondes : attendre puis retenter dans le même cycle si le budget de tentatives le permet ;
- délai supérieur à 60 secondes : ne pas bloquer le monitor, renseigner `next_attempt_at` et passer au canal suivant ;
- maximum `CURL_RETRIES + 1` tentatives par canal et par cycle ;
- après la dernière tentative temporaire sans `Retry-After`, mettre `next_attempt_at=0` afin que le prochain cycle puisse retenter.

Aucune nouvelle variable `.env` n’est ajoutée. Les bornes de 60 secondes et 24 heures sont des constantes internes documentées.

## Statut du cycle

Le cycle courant échoue lorsqu’au moins un des événements suivants survient :

- une tentative réseau due échoue ;
- un canal passe pour la première fois en échec permanent ;
- un canal requis vient d’être retiré ;
- le journal ou `.alert_state` est invalide ;
- une persistance ou une réconciliation échoue.

Un canal déjà en échec terminal ne fait pas échouer indéfiniment les cycles suivants.

Une alerte pending dont `next_attempt_at` est encore futur ne fait pas échouer à elle seule les cycles intermédiaires.

## Migration v1–v4

La migration s’exécute uniquement lorsque le journal n’existe pas encore.

Elle est construite entièrement en mémoire puis publiée par un remplacement atomique. Un crash produit donc soit aucun journal, soit un journal complet.

### Alertes déjà traitées

Pour les seuils présents dans `notified_*_thresholds` et les resets présents dans `last_notified_*_reset_at` :

- ne créer aucune occurrence ;
- conserver les marqueurs existants ;
- ne produire aucun appel réseau.

### Seuil historique pending

Pour chaque `pending_*_threshold` :

- construire un ID avec le préfixe `legacy-vN` ;
- utiliser les canaux configurés au moment de la migration ;
- reconstruire le message avec l’observation courante et le format existant ;
- conserver le champ pending tant que l’occurrence n’est pas terminale.

Si l’observation courante ne permet pas de construire un message fiable :

- ne pas abandonner le pending ;
- ne pas envoyer de message approximatif ;
- différer la migration ;
- faire échouer le traitement des alertes avec un diagnostic sans secret.

### Reset historique

Un reset armé, arrivé et non traité :

- devient une occurrence uniquement s’il se trouve encore dans sa fenêtre de validité ;
- est ignoré comme événement réseau s’il n’est pas encore arrivé, car le flux normal l’enregistrera à échéance ;
- est clôturé localement sans envoi s’il est déjà expiré.

La limite historique est documentée : une ancienne tentative ayant réussi à distance juste avant un crash peut être rejouée, les API ne fournissant pas de clé d’idempotence exploitable.

## Diagnostics et confidentialité

Les diagnostics autorisés sont limités à :

- canal logique ;
- `alert_id` ;
- numéro de tentative ;
- code curl ;
- statut HTTP ;
- classe d’erreur ;
- délai avant prochaine tentative.

Ne jamais inclure dans le journal, `health.json`, stdout ou stderr :

- webhook Discord ;
- token Telegram ;
- chat ID ;
- PAT GitHub ;
- URL complète ;
- paramètres d’authentification ;
- corps ou headers de réponse ;
- sortie brute de curl.

Le journal reste sous `runtime/`, déjà exclu de Git, et ne doit jamais être exposé par `serve.sh` ou envoyé au Gist.

## Fichiers à modifier

- `local/alerts.py`
  - nouveau module de journalisation, IDs, états, rétention et classification HTTP.
- `local/monitor.sh`
  - intégration du journal ;
  - transport HTTP structuré ;
  - enregistrement avant envoi ;
  - distribution par canal ;
  - réconciliation ;
  - migration historique.
- `tests/test_alerts.py`
  - tests unitaires du module.
- `tests/fixtures/fake-curl.sh`
  - séquences, headers, corps, codes curl et comptage par canal.
- `tests/test_monitor_network.sh`
  - scénarios de livraison partielle et retries.
- `tests/test_monitor_alerts.sh`
  - migration, resets et réconciliation.
- `tests/test_monitor_thresholds.sh`
  - remplacement par un seuil plus critique.
- `tests/test_monitor_scripts.sh`
  - non-régression des hooks.
- `tests/test_http.sh`
  - confirmer que le journal ne peut pas être servi.
- `tests/run.sh`
  - exécuter `tests/test_alerts.py`.
- `README.md` et `local/.env.example`
  - documenter le comportement sans ajouter de configuration.
- `ROADMAP.md`
  - retirer P0.2 uniquement après validation complète.

## Tests unitaires de `alerts.py`

Couvrir :

- déterminisme et séparation des IDs ;
- absence du timestamp d’observation dans l’ID ;
- validation stricte du schéma ;
- enregistrement idempotent ;
- conflit d’ID avec un autre message ;
- agrégation des états ;
- sélection des seuls canaux dus ;
- remplacement atomique d’un seuil ;
- expiration des seuils au reset ;
- réconciliation et acquittement ;
- rétention 30 jours/500 entrées ;
- refus des journaux corrompus, futurs ou supérieurs à 16 MiB ;
- parsing numérique et HTTP-date de `Retry-After` ;
- classification des statuts et codes curl ;
- validation Telegram.

## Tests d’intégration réseau

Couvrir au minimum :

- Discord livré, Telegram temporairement indisponible, puis seul Telegram est rappelé ;
- scénario symétrique ;
- les deux canaux livrés, sans rejeu au cycle suivant ;
- 400, 401, 403 et 404 : une tentative, état terminal ;
- 408, 429, 500 et 503 : retries bornés puis état pending ;
- timeout et autre erreur curl ;
- Telegram 200 avec `ok:false` ou JSON invalide ;
- `Retry-After` court, long, passé, invalide et excessif ;
- ajout ultérieur d’un canal ;
- retrait d’un canal pending ;
- rotation des credentials ;
- absence de canal ;
- absence de secrets dans tous les fichiers et diagnostics.

## Tests de seuils, resets et crashs

Couvrir :

- même événement et même cycle : même ID ;
- même seuil dans un nouveau cycle : nouvel ID ;
- seuil plus critique : remplacement, pas accumulation ;
- seuil remplacé partiellement livré : nouvelle occurrence indépendante ;
- reset expirant les seuils pending ;
- reset hebdomadaire anticipé ;
- changement de `limit_id` ;
- crash après enregistrement mais avant envoi ;
- crash après succès Discord persisté mais avant Telegram ;
- crash après terminaison du journal mais avant mise à jour de `.alert_state` ;
- crash après mise à jour de `.alert_state` mais avant acquittement du journal ;
- journal illisible ou écriture interrompue ;
- aucune réussite déjà persistée n’est rejouée.

## Tests de migration

Créer des fixtures v1, v2, v3 et v4 couvrant :

- état sans pending : journal vide et aucun appel ;
- seuil 5h pending ;
- seuil weekly pending ;
- reset encore valide ;
- reset expiré ;
- marqueurs déjà livrés ;
- migration différée faute d’observation exploitable ;
- migration interrompue puis relancée ;
- préservation des baselines, `limit_id` et journaux de scripts ;
- refus conservateur d’une version future.

## Validation finale

Exécuter :

```bash
python3 tests/test_alerts.py
bash -n local/monitor.sh
bash tests/test_monitor_network.sh
bash tests/test_monitor_alerts.sh
bash tests/test_monitor_thresholds.sh
bash tests/test_monitor_scripts.sh
bash tests/test_http.sh
bash tests/run.sh
npm run test:browser
```

La feature est acceptée lorsque :

- chaque occurrence possède un ID stable et un message immuable ;
- Discord et Telegram sont suivis indépendamment ;
- un canal livré n’est jamais rappelé après persistance ;
- seules les erreurs temporaires restent pending ;
- les longs `Retry-After` ne bloquent pas la collecte ;
- un seuil plus critique remplace le seuil pending devenu obsolète ;
- les migrations ne rejouent aucune alerte historiquement traitée ;
- une corruption provoque un arrêt fermé sans envoi ;
- aucun secret n’est persisté ou journalisé ;
- les scripts locaux et le Gist conservent leur comportement ;
- la suite complète reste verte.

## Hypothèses et garanties

- La livraison possède une sémantique « au moins une fois ».
- Une duplication reste possible si le processus meurt après acceptation distante mais avant persistance locale.
- Discord et Telegram ne fournissent pas de mécanisme d’idempotence permettant de supprimer cette dernière fenêtre.
- Le journal de livraison est interne et n’introduit aucune API publique.
- Les commandes publiques de `monitor.sh`, les payloads et le texte initial des messages restent compatibles.
