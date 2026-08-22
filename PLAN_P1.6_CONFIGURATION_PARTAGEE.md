# Plan d’implémentation — P1.6 Configuration partagée

## 1. Résultat attendu

Le monitor et le serveur doivent charger et valider leur configuration à partir
d’un module Python commun, `local/config.py`, sans exécuter `local/.env` comme du
code shell.

Pour chaque option qui existe dans plusieurs sources, la priorité devient :

```text
option CLI > variable du processus > local/.env > valeur par défaut
```

Une même valeur partagée, notamment le catalogue tarifaire et l’intervalle
d’activité du dashboard, doit être acceptée ou rejetée de façon identique par
les deux programmes. Les erreurs restent courtes, actionnables et exemptes de
traceback, de valeur secrète et de contenu brut de `.env`.

## 2. Périmètre et décisions structurantes

- Conserver Bash comme couche de parsing CLI et d’orchestration de
  `monitor.sh` et `serve.sh` ; ne pas réécrire leur logique métier.
- Ajouter un module Python standard library unique qui possède le catalogue des
  clés, les valeurs par défaut, le parsing de `.env`, la résolution des sources,
  la normalisation et la validation.
- Ne pas ajouter de dépendance, de service, de format de données persistant ni
  de nouveau paramètre utilisateur uniquement pour satisfaire l’abstraction.
- Conserver les exceptions process-only documentées
  (`DASHBOARD_ANALYTICS_DATABASE`, `DASHBOARD_PRICING_FILE` et
  `CODEX_BIN_OVERRIDE`) ; elles participent à la couche « variable du
  processus » sans devenir des clés acceptées dans `.env`.
- Conserver `serve.sh --bind` et `--port` comme options CLI, et
  `monitor.sh --loop SECONDS` comme surcharge CLI de `LOOP_INTERVAL`. Aucune
  nouvelle variable générique `PORT` ou `BIND` n’est introduite.
- Préserver la distinction entre valeur absente et valeur explicitement vide :
  une intégration optionnelle vide reste désactivée, tandis qu’une clé requise
  explicitement vide reste invalide au lieu de retomber silencieusement sur le
  défaut.
- Ne jamais transporter les valeurs issues de `.env` au moyen d’un `source`,
  d’une substitution de commande évaluée ou d’un `eval` non protégé. Le pont
  Python → Bash utilisera un protocole structuré ou délimité par NUL, puis des
  affectations littérales.
- Ne pas modifier, supprimer ou ajouter au commit les fichiers non suivis déjà
  présents dans le worktree.

## 3. Contrat du module `local/config.py`

### 3.1 Schémas et valeurs par défaut

Définir explicitement les clés du monitor, les clés partagées avec le serveur,
les surcharges réservées au processus et les familles dynamiques
`ALERT_SCRIPT_<N>` / `ALERT_SCRIPT_<N>_EVENTS`.

Chaque entrée décrit au minimum :

- sa valeur par défaut ou sa fabrique de valeur dépendant du répertoire local,
  de `HOME` et de `XDG_DATA_HOME` ;
- les sources autorisées ;
- son validateur et, lorsque nécessaire, son normaliseur ;
- son caractère sensible afin qu’aucun diagnostic ne reproduise sa valeur.

Les défauts dynamiques restent compatibles avec le comportement actuel :
`local/pricing.json`, `local/runtime/usage-history.sqlite3`, `~/.codex`, la base
OpenCode sous `XDG_DATA_HOME` et la base Hermes sous le home utilisateur.

### 3.2 Lecture sûre de `.env`

Le lecteur commun doit :

1. considérer un fichier absent comme une configuration vide ;
2. ouvrir le chemin sans suivre de lien symbolique, puis contrôler sur le
   descripteur qu’il s’agit d’un fichier régulier appartenant à l’utilisateur
   courant ;
3. appliquer ou garantir le mode privé `0600` de façon cohérente pour le
   monitor et le serveur ;
4. lire le fichier comme des données UTF-8, ligne par ligne, en tolérant CRLF,
   commentaires et lignes vides ;
5. accepter uniquement `CLE=valeur`, avec une clé majuscule autorisée et le
   retrait compatible d’une paire de guillemets simples ou doubles ;
6. ne réaliser aucune expansion de variable, commande, backslash ou syntaxe
   shell ;
7. avertir pour une ligne mal formée, une clé invalide ou non prise en charge,
   sans en afficher la valeur ;
8. mémoriser la présence d’une clé même si sa valeur est vide, afin que la
   résolution et la validation ne la confondent pas avec une absence.

Les contrôles doivent éviter une fenêtre évidente entre la vérification du
chemin et sa lecture. Les erreurs de fichier, encodage, propriétaire ou type
sont converties en messages `[ERROR]` stables sans traceback.

### 3.3 Résolution des sources

Construire séparément les configurations `monitor` et `serve`, puis fusionner
les sources de la moins prioritaire vers la plus prioritaire : défauts,
`.env`, environnement du processus, options CLI déjà parsées.

Cas particuliers conservés :

- `--loop SECONDS` surcharge `LOOP_INTERVAL` pour le monitor ;
- `CODEX_BIN_OVERRIDE` surcharge process-only `CODEX_BIN` ;
- `DASHBOARD_PRICING_FILE` surcharge process-only le
  `TOKEN_PRICING_FILE` vu par le serveur ;
- `DASHBOARD_ANALYTICS_DATABASE` surcharge le chemin SQLite par défaut du
  serveur ;
- `--bind` et `--port` gagnent sur leurs défauts, sans ajouter de lecture
  `.env` ;
- `DASHBOARD_ACTIVE_INTERVAL_SECONDS` et `TOKEN_PRICING_FILE` utilisent la
  même valeur résolue et le même validateur dans les deux applications.

Les variables héritées non supportées ne doivent pas influencer le résultat.
La résolution doit rester déterministe et testable avec des mappings fournis
en argument, sans dépendre obligatoirement de `os.environ` dans les fonctions
pures.

### 3.4 Validation et normalisation

Déplacer dans Python les validations actuellement dispersées :

- booléens `0`/`1`, entiers et nombres bornés ;
- seuils d’alerte et sélecteurs d’événements ;
- paires Gist et Telegram incomplètes ;
- formats des identifiants, webhook et URL de base ;
- caractères de contrôle dans secrets, identifiants et chemins ;
- sources de tokens et chemins Analytics absolus ;
- catalogue tarifaire lisible, régulier et non symbolique ;
- base Analytics absolue et non symbolique lorsqu’elle existe ;
- scripts d’alerte absolus, réguliers et exécutables, indices de 1 à 99,
  paires chemin/événements complètes et actions dupliquées ;
- cohérence entre timeouts HTTP ;
- port, adresse IP de bind et intervalle d’activité du serveur.

Le module produit aussi les règles de scripts normalisées dans l’ordre actuel,
y compris les seuils sans zéros initiaux et les identifiants d’action SHA-256,
afin que la logique d’alerte Bash ne change pas.

Toutes les erreurs attendues passent par une exception de configuration dédiée
et une frontière CLI qui affiche uniquement un message lisible. Une erreur ne
doit jamais inclure un token, un webhook, le contenu d’une ligne ou un
traceback.

## 4. Intégration avec `monitor.sh`

- Remplacer le parseur, les défauts et les validateurs Bash par un appel au
  module partagé pendant `initialize`.
- Passer la surcharge de `--loop SECONDS` comme source CLI au résolveur avant
  l’initialisation, afin que la priorité soit exercée par le même mécanisme que
  les autres sources.
- Importer les couples clé/valeur de façon littérale et reconstituer les
  tableaux `ALERT_SCRIPT_RULE_*` à partir de données structurées, sans
  interpréter le contenu comme du shell.
- Conserver une petite façade de validation si les tests ou fonctions sourcées
  en ont besoin, mais faire exécuter toute décision de validité par
  `config.py`.
- Conserver les codes de sortie existants : erreur d’usage CLI `2`, erreur de
  configuration ou d’exécution `1`, succès `0`.
- Ne pas charger la configuration pour `--help` et ne pas créer/modifier le
  runtime lors du simple sourcing du script.
- Garder `check_requirements` et les contrôles réellement opérationnels dans
  Bash ; la présence de commandes et l’authentification Codex ne sont pas de la
  configuration statique.

## 5. Intégration avec `serve.sh`

- Conserver le parsing CLI Bash pour garantir les erreurs d’usage avant le
  lancement du serveur.
- Remplacer le lecteur `.env` spécifique et les validations redondantes par le
  profil `serve` de `config.py`.
- Résoudre et transmettre au serveur Python le bind, le port, la base
  Analytics, le catalogue tarifaire et l’intervalle d’activité.
- Faire réutiliser exactement le même lecteur sécurisé et les mêmes
  validateurs pour `.env`, `TOKEN_PRICING_FILE` et
  `DASHBOARD_ACTIVE_INTERVAL_SECONDS` que le monitor.
- Conserver l’allowlist HTTP, les protections du heartbeat et l’absence
  d’authentification/TLS sans modification fonctionnelle.
- Retourner `2` pour une configuration de démarrage invalide, comme le serveur
  le fait aujourd’hui, et `1` pour une dépendance ou erreur d’exécution.

## 6. Tests

### 6.1 Tests unitaires Python

Ajouter `tests/test_config.py` pour couvrir directement :

- parsing de lignes vides, commentaires, CRLF, guillemets et valeurs contenant
  espaces ou métacaractères ;
- absence totale d’expansion de `$VAR`, `$(commande)`, backticks et backslashes ;
- clé inconnue, clé invalide, ligne mal formée et index de script invalide ;
- fichier absent, lien symbolique, fichier non régulier, propriétaire simulé
  incorrect, permissions privées et erreur UTF-8 ;
- priorité défaut < `.env` < environnement < CLI, y compris une valeur vide
  explicite et les trois alias process-only ;
- bornes numériques, booléens, listes, URLs, paires incomplètes et caractères
  de contrôle ;
- chemins absolus, catalogue symbolique/manquant et base Analytics symbolique ;
- normalisation et déduplication des règles de scripts d’alerte ;
- erreurs sans traceback ni fuite de valeur sensible.

### 6.2 Tests d’intégration shell et HTTP

Adapter les tests existants et ajouter des cas croisés qui lancent les vrais
scripts :

- la même configuration partagée valide démarre les deux chemins, et la même
  valeur invalide produit un rejet cohérent ;
- une variable de processus gagne sur `.env` pour le monitor et le serveur ;
- `--loop SECONDS` gagne sur `LOOP_INTERVAL` de l’environnement et de `.env` ;
- `DASHBOARD_PRICING_FILE` gagne sur `TOKEN_PRICING_FILE` du processus et du
  fichier ;
- `--port` et `--bind` conservent leur priorité CLI ;
- une charge `.env` contenant une commande ou un nom de fichier à métacaractères
  reste une chaîne littérale et ne crée aucun fichier ;
- `.env` symbolique ou appartenant à un autre utilisateur simulé est refusé par
  les deux applications ;
- `--help` n’accède toujours ni à `.env` ni au runtime ;
- les tableaux de scripts d’alerte obtenus depuis Python conservent l’ordre et
  le comportement des notifications existantes.

### 6.3 Validation globale

- `python3 -m compileall local tests/test_config.py`
- tests ciblés de configuration, CLI, scripts d’alerte et serveur HTTP ;
- `./tests/run.sh`
- `npm run test:browser`
- ShellCheck via le contrôle existant du dépôt ou directement sur les scripts
  modifiés si nécessaire.

## 7. Documentation et clôture de roadmap

- Mettre à jour `README.md` avec le contrat final de priorité, les clés
  process-only, le comportement des valeurs vides, la sécurité de `.env` et le
  rôle de `local/config.py`.
- Mettre à jour `local/.env.example` uniquement si la description des sources
  ou priorités change ; ne pas y exposer de secret réel.
- Retirer P1.6 de `ROADMAP.md`, de l’ordre recommandé et de la définition des
  travaux restants une fois tous ses critères satisfaits, conformément à la
  convention de la roadmap.
- Garder les messages d’aide CLI synchronisés avec le contrat documenté.

## 8. Critères de succès et non-régressions

- Une seule implémentation Python décide comment une configuration est parsée,
  résolue et validée pour les deux programmes.
- Les valeurs partagées sont interprétées à l’identique par le monitor et le
  serveur.
- La priorité CLI > environnement > `.env` > défaut est démontrée par des tests
  de bout en bout.
- Les variables incomplètes et les valeurs explicitement vides sont testées et
  ne déclenchent pas de repli silencieux.
- Aucun contenu de `.env` n’est exécuté et aucune donnée sensible n’apparaît
  dans un message d’erreur ou un traceback.
- Les commandes, alertes, Analytics, heartbeat et routes HTTP existants restent
  fonctionnels.
- La suite complète, les tests navigateur, la compilation Python et ShellCheck
  passent.

## 9. Livraison

- Branche dédiée : `feature/p1-6-shared-config` depuis `dev` à jour.
- Un commit cohérent contenant plan, module, intégrations, tests,
  documentation et clôture de la roadmap.
- Push sur `origin`, puis pull request vers `dev` avec un résumé des décisions
  de compatibilité et les validations exécutées.
- Après création de la PR, relancer les services monitor/dashboard déjà
  installés sur l’hôte, vérifier leur état et tester les endpoints dashboard et
  Analytics sur l’adresse LAN configurée, sans élargir le bind réseau existant.
