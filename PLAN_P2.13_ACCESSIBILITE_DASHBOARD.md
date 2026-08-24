# Plan d’implémentation — P2.13 Accessibilité du dashboard principal

## 1. Résultat attendu

Le dashboard principal doit rendre le quota courant, l’allure hebdomadaire, la
fraîcheur et l’historique compréhensibles sans dépendre du graphique, de la
couleur ou d’un attribut `title`.

Le graphique Chart.js reste disponible pour l’exploration visuelle, mais il
devient un enrichissement progressif : un échec de chargement ou de rendu du
graphique ne doit supprimer ni le résumé textuel ni les données tabulaires de
l’historique.

## 2. Périmètre et décisions structurantes

- Limiter les changements à l’interface principale, à ses traductions, à ses
  tests et à sa documentation ; le format de `data.json` et de `history.json`,
  la collecte, SQLite et Analytics ne changent pas.
- Réutiliser les points déjà produits par `normalizeHistory` afin que le
  graphique, le résumé et le tableau reposent sur la même validation, le même
  tri chronologique et la même déduplication.
- Conserver l’anglais et le français, ainsi que le fuseau `Europe/Paris`, pour
  tous les nouveaux textes et formats.
- Ne pas rendre le canvas interactif au clavier : toutes les informations du
  graphique seront disponibles dans un contrôle `<details>` natif et son
  tableau navigable. Le clavier servira aux contrôles réels de la page, sans
  créer un faux parcours de points difficile à utiliser.
- Préserver l’isolation actuelle des erreurs : une indisponibilité de
  l’historique ou de Chart.js ne doit pas masquer les quotas courants, et une
  erreur de rafraîchissement ne doit pas effacer la dernière représentation
  valide.
- Ne pas modifier ni supprimer les fichiers non suivis déjà présents dans le
  worktree.

## 3. Structure sémantique du dashboard

- Donner un titre sémantique et un identifiant à chaque carte de quota, puis
  relier chaque région à ce titre.
- Fournir à chaque élément `<progress>` un nom accessible localisé qui décrit
  explicitement la fenêtre et le fait qu’il s’agit du quota restant.
- Mettre à jour un `aria-valuetext` localisé avec la valeur courante ou l’état
  indisponible, tout en conservant le pourcentage visible adjacent.
- Relier le canvas de l’historique à son résumé et à la légende du tableau avec
  `aria-describedby`, et lui donner une sémantique d’image sans l’ajouter au
  parcours clavier.
- Ajouter sous le graphique un résumé textuel annoncé poliment, puis un
  `<details>` dont le `<summary>` permet d’ouvrir un tableau alternatif avec le
  clavier.
- Donner au tableau une légende explicite et les colonnes suivantes : date,
  quota 5 h restant, quota hebdomadaire restant, restant hebdomadaire idéal,
  prévision 24 h et prévision 6 h.

## 4. Rendu accessible des quotas et de l’allure

- Étendre le rendu des jauges pour synchroniser valeur native, texte visible,
  nom accessible et `aria-valuetext`, y compris lorsque la donnée est absente.
- Afficher dans le contenu de la carte hebdomadaire les valeurs « restant
  réel » et « restant idéal » à côté du delta déjà visible.
- Conserver une direction littérale dans le delta (`above`/`below`, ou leurs
  traductions), afin que l’état avance/retard ne repose pas sur les classes de
  couleur `ahead` et `behind`.
- Remplacer la dépendance à `title` pour l’allure par ce contenu visible ; un
  état indisponible doit être exprimé dans le texte, pas uniquement par `--` ou
  une couleur.
- Vérifier que la fraîcheur conserve son badge textuel et son détail d’âge, et
  que les valeurs de quota restent écrites en clair lorsque la page est
  marquée périmée.

## 5. Résumé et tableau alternatifs de l’historique

- Après normalisation, construire un résumé localisé indiquant le nombre
  d’échantillons, la période couverte et les dernières valeurs disponibles des
  séries principales.
- Générer une ligne de tableau par point normalisé, avec un format de date et
  de pourcentage cohérent avec le graphique ; une mesure absente doit produire
  un libellé localisé d’indisponibilité plutôt qu’une cellule ambiguë.
- Mettre à jour le résumé et le tableau avant de créer ou mettre à jour
  Chart.js. Ils restent donc utilisables si le script du graphique est absent
  ou si le constructeur échoue.
- Distinguer explicitement trois états :
  1. historique valide et graphique disponible ;
  2. historique valide mais graphique indisponible, avec résumé/tableau
     conservés et erreur du graphique annoncée ;
  3. historique vide ou invalide, avec graphique détruit, tableau vidé et
     résumé d’indisponibilité explicite.
- Conserver l’historique valide en mémoire lorsque seul Chart.js échoue afin
  qu’un changement de langue retraduise le résumé et le tableau sans nouvelle
  requête.
- Lors d’un changement de langue, retraduire titres, résumé, en-têtes statiques,
  cellules indisponibles, labels des jauges et détails d’allure.

## 6. Présentation et usage sans couleur

- Ajouter des styles compacts pour le résumé, le contrôle `<details>`, la zone
  défilable et le tableau, avec une mise en page utilisable sur mobile.
- Fournir un indicateur de focus visible au `<summary>` et conserver ceux des
  liens et boutons existants.
- Garder les informations littérales (pourcentages, fraîcheur, direction de
  l’allure, erreurs) visibles même lorsque les couleurs, dégradés ou bordures ne
  sont pas perçus.
- Masquer seulement le canvas en cas d’échec graphique ; ne pas masquer la
  représentation alternative valide.

## 7. Tests automatisés

### Tests JavaScript isolés

- Étendre le faux DOM de `tests/test_dashboard.js` pour couvrir les attributs
  ARIA, la création et le remplacement des lignes du tableau.
- Vérifier les labels et `aria-valuetext` des deux jauges pour une valeur valide
  et pour une valeur indisponible.
- Vérifier les valeurs réelle/idéale visibles, le delta directionnel et leur
  traduction.
- Vérifier le contenu du résumé, l’ordre et les cellules du tableau après
  normalisation/déduplication.
- Vérifier qu’un historique vide nettoie résumé et lignes, et qu’un échec de
  Chart.js préserve le résumé et le tableau valides.
- Vérifier la retraduction de toute la représentation accessible sans refetch.

### Tests Playwright et axe-core

- Sur le scénario nominal, vérifier les relations ARIA, les labels complets des
  jauges, les valeurs d’allure visibles, le résumé et le tableau alternatif.
- Parcourir les contrôles au clavier et ouvrir/fermer le tableau avec
  `Enter`/`Space`, sans piège de focus.
- Vérifier que les textes de direction et d’état suffisent sans inspecter les
  couleurs.
- Couvrir explicitement avec axe-core le scénario nominal, les données
  périmées, l’historique vide et Chart.js indisponible.
- Dans le scénario Chart.js indisponible, vérifier que les quotas, le résumé et
  le tableau restent présents ; dans le scénario vide, vérifier le message
  explicite et l’absence de lignes obsolètes.

### Validation globale

- `node tests/test_dashboard.js`
- `npm run test:browser -- --grep` sur les scénarios du dashboard principal
- `./tests/run.sh`
- `npm run test:browser`
- `python3 -m compileall local`
- vérifier l’absence de régression documentaire et HTTP via la suite globale.

## 8. Documentation et clôture de roadmap

- Documenter dans `README.md` les noms accessibles des jauges, les valeurs
  réelle/idéale visibles, le résumé et le tableau alternatifs, ainsi que leur
  disponibilité lorsque Chart.js échoue.
- Retirer P2.13 de `ROADMAP.md` et de l’ordre d’exécution après satisfaction de
  tous les critères, puisque cette roadmap ne conserve que les travaux restant
  à réaliser.
- Conserver le présent plan comme trace des décisions et critères de recette.

## 9. Livraison

- Branche dédiée : `feat/p2-13-dashboard-accessibility`, créée depuis `dev` à
  jour.
- Un commit cohérent regroupant interface, traductions, styles, tests,
  documentation, plan et clôture de roadmap.
- Push sur `origin`, puis pull request vers `dev` avec synthèse des changements
  et preuves de validation.
- Relancer les services monitor et dashboard réellement installés sur l’hôte,
  contrôler leur état et vérifier l’URL du dashboard sur l’adresse LAN déjà
  configurée. Aucun bind réseau ou pare-feu ne sera élargi implicitement.
