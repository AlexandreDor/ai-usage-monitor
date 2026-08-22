# Plan d’implémentation — P2.18 Valeur implicite de la limite hebdomadaire

## 1. Résultat attendu

Analytics doit exposer, expliquer et visualiser en dollars la valeur API
implicite de la limite hebdomadaire Codex :

```text
valeur implicite = coût API équivalent Codex observé / fraction de quota hebdomadaire consommée
```

Le calcul courant porte sur une fenêtre glissante d’environ une heure. La
table des resets doit également afficher le coût Codex observé pendant chaque
cycle hebdomadaire terminé et, lorsque le cycle s’est terminé avec du quota
restant, son extrapolation à 100 %.

Le résultat ne doit jamais présenter une valeur précise lorsque les deux
grandeurs ne sont pas comparables ou que leur qualité est insuffisante.

## 2. Périmètre et décisions structurantes

- Réutiliser l’archive SQLite v4 et calculer les métriques à la lecture dans
  `local/analytics.py` ; aucune migration ni nouvelle donnée persistée n’est
  nécessaire.
- Valoriser uniquement les événements `token_usage_events.source = 'codex'`.
  OpenCode et Hermes ne consomment pas la limite hebdomadaire Codex et ne
  doivent donc pas gonfler son estimation.
- Ne pas faire dépendre l’estimation des filtres d’affichage source/modèle :
  elle représente la limite Codex globale, tandis que les graphiques de tokens
  existants conservent leur comportement filtrable.
- Conserver l’USD comme devise contractuelle du payload et du tableau demandé.
  La préférence d’affichage EUR peut convertir le graphique comme les autres
  coûts, mais les libellés contractuels du tableau restent explicitement en
  dollars et ses valeurs utilisent l’USD.
- Ne pas extrapoler les lignes de reset 5 h : les deux nouvelles cellules y
  affichent une indisponibilité expliquée, car P2.18 concerne la limite
  hebdomadaire.
- Ne pas lisser silencieusement les données. Exposer la valeur brute calculée,
  utiliser une médiane glissante courte de trois points valides pour la courbe,
  et signaler une dispersion forte ou un dénominateur faible dans la qualité.

## 3. Contrat de calcul de la série glissante

### 3.1 Construction d’une fenêtre comparable

Pour chaque relevé hebdomadaire de fin `t1` dans la période demandée :

1. rechercher le relevé valide le plus proche de `t1 - 3600 s` ;
2. accepter une durée réelle comprise entre 45 et 75 minutes afin de tolérer
   l’intervalle de collecte, et exposer cette durée réelle ;
3. exiger deux pourcentages finis compris entre 0 et 100, le même `limit_id`
   non vide et le même `weekly_reset_at` valide ;
4. rejeter la fenêtre si un reset hebdomadaire se trouve entre les deux
   observations, si la limite change, si le quota augmente, si les données sont
   périmées ou si l’identification du cycle est ambiguë ;
5. calculer la baisse du quota restant :
   `consumed_fraction = (weekly_pct_start - weekly_pct_end) / 100` ;
6. sommer sur exactement `[t0, t1)` le coût API équivalent de tous les
   événements Codex, au niveau fournisseur/modèle avant agrégation ;
7. refuser le point si un modèle n’a pas de prix, si les compteurs/prix ne sont
   pas finis et positifs, si aucun coût n’est observé, ou si la fraction est
   nulle ;
8. appliquer la formule `raw_value_usd = observed_cost_usd /
   consumed_fraction` (ainsi 2 % devient bien `0.02`).

### 3.2 Seuil, bruit et qualité

- Une baisse inférieure à 0,5 point de pourcentage est un signal insuffisant :
  le point est indisponible avec la cause `insufficient_quota_delta` afin
  d’éviter une division numériquement valide mais trompeuse.
- Entre 0,5 et 1 point, ou en présence d’événements de qualité
  `polled_delta`, la valeur reste calculable mais porte la qualité
  `low_confidence`.
- À partir de 1 point, avec une fenêtre proche d’une heure, des prix complets et
  des événements exacts, la qualité est `good`.
- La valeur tracée est la médiane de la valeur brute et des deux précédents
  points valides du même `limit_id`. Le payload conserve les deux valeurs.
- Une dispersion relative supérieure à 50 % dans ce voisinage dégrade la
  qualité en `volatile`; l’interface l’annonce et ne la présente pas comme une
  estimation fiable.

Le payload ajoute un bloc autonome, par exemple :

```json
{
  "weekly_limit_value": {
    "currency": "USD",
    "window_seconds": 3600,
    "minimum_quota_delta_pct_points": 0.5,
    "series": [
      {
        "at": "…",
        "window_start": "…",
        "window_seconds": 3600,
        "limit_id": "…",
        "quota_consumed_pct_points": 2.0,
        "consumed_fraction": 0.02,
        "observed_cost_usd": 1.5,
        "raw_value_usd": 75.0,
        "value_usd": 75.0,
        "quality": "good",
        "reason": null
      }
    ],
    "unavailable_reasons": {"missing_price": 2}
  }
}
```

Les noms finaux peuvent être ajustés pour rester cohérents avec le payload
Analytics existant, mais la devise, la durée réelle, la valeur brute, la valeur
tracée, la qualité et la cause d’indisponibilité doivent rester explicites.

## 4. Coût et extrapolation des cycles terminés

Pour chaque reset hebdomadaire affiché :

1. identifier sans ambiguïté le `limit_id` grâce aux relevés cohérents juste
   avant et après le reset ;
2. retrouver le précédent reset hebdomadaire du même `limit_id`, qui marque le
   début observable du cycle ; sans borne de début complète, rendre le coût du
   cycle indisponible plutôt que sommer un cycle partiel ;
3. sommer les événements Codex tarifables du début du cycle au reset courant ;
4. exposer `estimated_cycle_cost_usd` si tous les prix et relevés requis sont
   valides ;
5. calculer `consumed_fraction = (100 - before_pct) / 100` ;
6. si `0 < consumed_fraction <= 1` et que du quota restait au reset,
   calculer `extrapolated_100_value_usd = estimated_cycle_cost_usd /
   consumed_fraction` ;
7. pour un cycle entièrement consommé, conserver le coût observé et présenter
   l’extrapolation comme non applicable ; pour un dénominateur nul, des prix
   incomplets, une transition de limite ou une borne ambiguë, exposer `null`
   avec une cause lisible.

Le calcul du coût de cycle n’est pas limité par la plage temporelle sélectionnée
dans l’UI : la plage filtre les resets affichés, pas les événements nécessaires
à un cycle complet.

## 5. Backend Analytics

- Isoler des helpers purs pour la validation des nombres, la tarification d’un
  intervalle Codex, la résolution des fenêtres et la qualification des points.
- Borner les requêtes et éviter une requête par point : charger les relevés et
  les événements utiles en ordre chronologique, puis utiliser des pointeurs ou
  des préfixes cumulés par modèle/prix.
- Ajouter `weekly_limit_value` au payload de `build_payload` et enrichir chaque
  item de `resets.items` avec les deux montants USD, un statut et une cause.
- Réutiliser le catalogue actuel mais considérer un prix absent comme une
  invalidation, et non comme un coût nul, pour ces nouvelles estimations.
- Préserver la compatibilité du schéma de réponse existant et les limites de
  pagination/volume.

## 6. Interface Analytics et accessibilité

- Ajouter une carte large dédiée avec titre, description « fenêtre glissante
  de 1 h », devise, légende de qualité, graphique de tendance et état vide.
- Fournir un résumé `aria-live` et un tableau alternatif contenant date, coût
  observé, quota consommé, valeur brute/lissée, qualité et explication.
- Afficher les points `good`, `low_confidence` et `volatile` sans dépendre
  uniquement de la couleur (libellé/forme de point et texte du tableau).
- Ajouter à « Previous limit resets » les colonnes littérales
  « Estimated cycle cost ($) » et « Extrapolated 100% value ($) » ; une valeur
  indisponible doit afficher `N/A` avec une explication visible ou accessible.
- Ajouter les traductions anglaises et françaises dans
  `local/assets/preferences.js`, les styles ciblés et le rendu dans
  `local/assets/analytics.js`.
- Réagir au changement de préférence monétaire sans perdre l’unité USD imposée
  dans les deux en-têtes de table.

## 7. Tests et critères de succès

### Backend

- Vérifier un exemple connu : coût `1.50 USD`, baisse `2 %`, valeur `75 USD`.
- Vérifier la conversion pourcentage/fraction, l’alignement exact de la fenêtre
  et l’usage exclusif des événements Codex.
- Couvrir : baisse nulle, baisse sous le seuil, hausse, données non finies,
  fenêtre trop courte/longue, données périmées, prix absent, événement absent,
  reset dans la fenêtre, changement/absence de `limit_id`, changement de
  deadline et qualité `polled_delta`.
- Vérifier la médiane à trois points et la détection de volatilité.
- Vérifier les cycles complets avec quota restant, quota entièrement consommé,
  cycle partiel, reset 5 h, prix manquant et transition de limite.

### Frontend et navigateur

- Étendre les tests JavaScript de rendu : série valide, état vide, qualité et
  causes, deux nouvelles colonnes de reset, formatage USD/EUR.
- Étendre Playwright/axe-core : présence du résumé et du tableau alternatif,
  graphique absent, données périmées, navigation clavier et absence de
  violation d’accessibilité.

### Validation globale

- `python3 -m compileall local`
- tests backend/Analytics ciblés ;
- suite `./tests/run.sh` ;
- tests navigateur via les scripts npm disponibles ;
- ShellCheck/contrôles documentaires existants si inclus par la suite.

## 8. Documentation et clôture de roadmap

- Documenter dans `README.md` la formule, le périmètre Codex, la fenêtre, les
  seuils, le lissage, les statuts de qualité, les causes de `N/A` et les deux
  colonnes de cycle.
- Une fois tous les critères satisfaits, retirer P2.18 de `ROADMAP.md`, de
  l’ordre d’exécution et de la définition des travaux restants, conformément à
  la convention de cette roadmap qui ne conserve pas les fonctions livrées.
- Ne modifier ni supprimer les fichiers non suivis déjà présents dans le
  worktree.

## 9. Livraison

- Branche dédiée : `feature/p2-18-weekly-limit-value` depuis `dev`.
- Un commit cohérent incluant code, tests, documentation et mise à jour de la
  roadmap.
- Push sur `origin`, PR vers `dev`, puis vérification des contrôles GitHub.
- Après création de la PR, relancer les services monitor/dashboard réellement
  installés sur l’hôte, vérifier leur état et l’endpoint Analytics, puis fournir
  le lien de PR et l’URL LAN détectée. Aucun bind réseau ne sera élargi sans
  utiliser la configuration déjà autorisée sur l’hôte.
