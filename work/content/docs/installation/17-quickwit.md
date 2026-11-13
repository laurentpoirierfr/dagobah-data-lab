---
title: "17 — Quickwit (recherche logs / traces sur S3) — mode distribué, tests"
weight: 18
---

> [!NOTE]
> Statut : ✅ installé (tests) · Date : 2026-11-11

## Objectif

[Quickwit](https://quickwit.io/) : moteur de recherche et d'analyse écrit en Rust
(basé sur tantivy), conçu pour les **logs et les traces**. Les index sont stockés
directement sur un **stockage objet S3**, et les nœuds de recherche n'ont pas
d'état. Il fournit une API REST, une **API compatible Elasticsearch** (`_bulk`,
`_search`, agrégations), l'ingestion **OpenTelemetry (OTLP)** et Jaeger, ainsi
qu'une interface web.

Option retenue : **A — distribué**, pour des tests. Les données vont dans Garage
et le metastore dans pg-main. La collecte des logs du cluster (OTel Collector +
plugin Grafana) n'est pas installée.

| Rôle Quickwit | Notre système |
|---|---|
| Stockage des index (*splits*) | Garage S3, `s3://quickwit/indexes` |
| Metastore (catalogue des index et des splits) | PostgreSQL `pg-main`, base `quickwit`, rôle `quickwit` |

## Prérequis

- [07](07-postgresql-cloudnativepg.md) (pg-main), [09](09-s3-garage.md) (Garage), [16](16-supervision.md) (ServiceMonitor)

## Installation

```bash
make sync SELECTOR=name=garage       # hook postsync : bucket quickwit + secret quickwit/s3-quickwit
make apply SELECTOR=name=pg-main     # rôle + base quickwit (secret quickwit/pg-quickwit)
make apply SELECTOR=name=quickwit
make qw-status
```

| Release | Namespace | Chart | Image |
|---|---|---|---|
| `quickwit` | `quickwit` | `quickwit/quickwit` 0.8.17 | `quickwit/quickwit:v0.9.3` (forcée : le chart déploie v0.8.2 par défaut) |

Secrets :

| Secret | Créé par | Usage |
|---|---|---|
| `quickwit/s3-quickwit` | `garage-init.sh` (postsync garage) | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` |
| `databases/pg-main-role-quickwit` → copie `quickwit/pg-quickwit` | `pg-role-secret.sh` (prepare pg-main) | mot de passe du metastore (`QW_PG_PASSWORD`) |
| `quickwit/quickwit-basic-auth` | `ensure-secret.sh` (prepare quickwit) | basic auth nginx de l'UI et de l'API |

## Configuration (`values/quickwit.yaml.gotmpl`)

```yaml
config:
  metastore_uri: postgres://quickwit:${QW_PG_PASSWORD}@pg-main-rw.databases.svc:5432/quickwit
  default_index_root_uri: s3://quickwit/indexes
  storage:
    s3:
      flavor: garage
      endpoint: http://garage.garage.svc:3900
      region: garage
      force_path_style_access: true
      checksum_algorithm: disabled      # indispensable avec Garage (voir pièges)
```

`${QW_PG_PASSWORD}` est interpolé par Quickwit au démarrage. Ce n'est pas
helmfile qui le remplace.

| Composant | Réplicas | Ressources (requests / limite mémoire) | Rôle |
|---|---|---|---|
| searcher | 1 | 100m / 1Gi | recherche, UI |
| indexer | 1 | 200m / 2Gi, PVC `local-data` 5Gi (WAL + cache) | ingestion, construction des splits |
| metastore | 1 | 50m / 512Mi | API du metastore (PostgreSQL) |
| control-plane | 1 | 20m / 256Mi | planification de l'indexation |
| janitor | 1 | 20m / 256Mi | rétention, nettoyage des splits orphelins |

Supervision : `serviceMonitor.enabled` → job Prometheus `quickwit` (5 cibles).

## Accès

| Accès | URL / commande |
|---|---|
| UI + API | https://quickwit.k8s.test (`admin` / `make ui-credentials`) |
| Recherche (interne) | `http://quickwit-searcher.quickwit.svc:7280` |
| Ingestion (interne) | `http://quickwit-indexer.quickwit.svc:7280` |
| API Elasticsearch | `https://quickwit.k8s.test/api/v1/_elastic/…` |

L'Ingress envoie `…/ingest` et `_bulk` vers l'indexer, `/api/v1/indexes` vers le
metastore, et tout le reste vers le searcher.

```bash
make qw-status                                   # version, nœuds, index
make qw-index-create INDEX=demo-logs             # depuis deploy/k8s/quickwit/indexes/demo-logs.yaml
make qw-demo-logs N=2000                         # logs JSON de démo (scripts/qw-demo-logs.py)
make qw-search Q='level:ERROR AND message:timeout'
make qw-search Q='message:"connection refused" AND service:payment'
```

Index de test `demo-logs` : `timestamp` (datetime, fast), `level` et `service`
(raw, fast), `message` (texte, positions pour les phrases), `latency_ms` (u64,
fast), mode dynamique pour les autres champs, rétention de 7 jours.

## Vérification (testée le 2026-11-11)

| Test | Résultat |
|---|---|
| Cluster | v0.9.3, 5 nœuds `ready` (searcher, indexer, metastore, control-plane, janitor) ✅ |
| Metastore | base `quickwit` : 9 tables, propriétaire `quickwit`, migrations appliquées ✅ |
| Ingestion | 2 000 documents, `num_rejected_docs: 0`, ~13 s avec `commit=wait_for` ✅ |
| Recherche | `level:ERROR AND message:timeout` → 269 résultats en 102 ms ✅ |
| Phrase | `message:"connection refused" AND service:payment` → 58 résultats en 135 ms ✅ |
| Agrégations (API ES) | `terms` par service + `percentiles` p95 de la latence, `terms` par niveau (INFO 5652 / WARN 1579 / ERROR 772) ✅ |
| Stockage | 8 003 documents dans 2 splits publiés, 552 Ko dans le bucket Garage `quickwit` ; splits référencés dans PostgreSQL (`Published`) ✅ |
| Supervision | `up{namespace="quickwit"}` = 5 ✅ |
| `make diff` | aucun écart ✅ |

## Licence

> Sources : dépôt [quickwit-oss/quickwit](https://github.com/quickwit-oss/quickwit)
> (fichiers `LICENSE.md` de v0.8.2 et `LICENSE` de v0.9.3, commit « Relicense to
> Apache 2.0 (#5645) » du 23/01/2025), billet
> [Quickwit joins Datadog](https://quickwit.io/blog/quickwit-joins-datadog)
> (consultés le 2026-11-11).

### Historique

| Versions | Licence |
|---|---|
| ≤ 0.8.x (jusqu'à janvier 2025) | **AGPL-3.0** + licence **commerciale** (double licence, contact `hello@quickwit.io`) |
| **≥ 0.9** (relicence du 23/01/2025, après le rachat par **Datadog**) | **Apache 2.0** (tantivy a aussi été relicencié) |

Nous utilisons **v0.9.3, sous Apache 2.0**.

### Ce que cela implique

- **Aucune fonction réservée** : contrairement à RisingWave ([12](12-risingwave.md#licence--édition-community-open-source-et-fonctions-premium))
  et Redpanda ([14](14-redpanda.md#licence--community-bsl-et-fonctions-enterprise)),
  il n'existe ni édition Enterprise, ni clé de licence, ni limite de CPU, de
  mémoire ou de durée. Tout le code du dépôt est utilisable tel quel.
- **Licence permissive** : usage commercial, modification, redistribution et offre
  en SaaS autorisés, sans obligation de publier ses modifications (contrairement
  à l'AGPL). Il faut seulement conserver les mentions de licence et de copyright
  (et le fichier NOTICE s'il existe).
- **⚠️ Ne pas utiliser d'image 0.8.x** : elle reste sous **AGPL-3.0**. Exposer une
  version modifiée sur le réseau obligerait alors à publier ses sources. C'est
  une raison de plus pour forcer `image.tag: v0.9.3` (le chart déploie v0.8.2
  par défaut).

### Composants annexes

| Composant | Licence | Remarque |
|---|---|---|
| Chart Helm `quickwit-oss/helm-charts` | **MIT** | — |
| Plugin Grafana `quickwit-oss/quickwit-datasource` | **AGPL-3.0** | non installé. À prendre en compte pour l'option C (logs dans Grafana) : il reste sous AGPL, contrairement au moteur |

### Pérennité (risque à suivre)

- Depuis le rachat, l'équipe travaille surtout sur l'intégration chez Datadog.
  Le billet officiel présente la relicence Apache 2.0 comme un moyen de laisser
  le projet à la communauté, sans feuille de route à long terme.
- Le projet reste actif : v0.9.0 (07/2026) → v0.9.3 (22/10/2026), commits
  quotidiens au 11/11/2026. Mais il n'y a **ni support commercial, ni offre
  cloud Quickwit** : le support passe par Datadog, pour ses propres produits.
- Le chart Helm officiel est en retard sur le moteur (appVersion v0.8.2).
- En cas d'arrêt, la licence Apache 2.0 permet de *forker* sans contrainte.

## Pièges rencontrés

- **`Invalid payload signature` (400) de Garage sur chaque upload de split** : par
  défaut, Quickwit 0.9 demande au SDK AWS un checksum **CRC32C** envoyé en
  *trailer* (`aws-chunked`), ce que Garage refuse.
  - Les variables `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` sont
    **ignorées** : Quickwit force sa propre configuration du SDK.
  - `checksum_algorithm: md5` ne **suffit pas** : le SDK ajoute toujours son CRC32.
  - ✅ `checksum_algorithm: disabled` repasse le SDK en `WhenRequired`.
    L'intégrité reste couverte par la signature SigV4 (SHA-256 du corps).
  - `flavor: garage` ne règle que la région et le path-style, pas les checksums.
- **`504 Gateway Time-out` sur l'ingestion** : avec `commit=wait_for`, nginx coupe
  après 60 s si l'indexation échoue en boucle. C'était un symptôme de l'erreur
  précédente. Les documents restent dans le WAL de l'indexer et sont publiés une
  fois le problème corrigé : rien n'est perdu.
- **Splits `Staged`** dans le metastore après des uploads ratés (55 ici) : le
  janitor les supprime automatiquement après un délai de grâce.
- **Metastore : 3 redémarrages au premier déploiement** : la base `quickwit`
  n'existait pas encore (CNPG crée la base après le rôle). Le problème se résout
  tout seul.
- **Index `otel-logs-v0_9` et `otel-traces-v0_9`** créés automatiquement : ce
  sont les index par défaut de l'ingestion OpenTelemetry, prêts pour l'option C.
- `make qw-search` avec des guillemets dans la requête : la cible passe `Q` par
  variable d'environnement (`export Q`) pour ne pas casser le shell.

## Pour aller plus loin

- **Option C** : OpenTelemetry Collector (DaemonSet, `filelog` → OTLP vers
  l'indexer) pour les logs de tous les pods, et plugin Grafana Quickwit (AGPL-3.0,
  voir Licence).
- **Source Kafka** : Quickwit peut indexer directement un topic Redpanda
  (`source_type: kafka`), par exemple `shop-events` ([15](15-risingwave-redpanda.md)).
- Montée en charge : `searcher.replicaCount`, `indexer.replicaCount`.

## Désinstallation

```bash
helmfile -f deploy/k8s/helmfile.yaml.gotmpl -l name=quickwit destroy
kubectl -n quickwit delete pvc --all
# données : bucket quickwit (garage-webui) et base quickwit (DROP DATABASE), rôle quickwit dans values/pg-main
```
