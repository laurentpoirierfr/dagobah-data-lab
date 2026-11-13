---
title: "12 — RisingWave (base de données de streaming)"
weight: 13
---

> [!NOTE]
> Statut : ✅ installé · Date : 2026-11-11

## Objectif

[RisingWave](https://risingwave.com/) : base SQL de streaming (compatible avec le
protocole PostgreSQL). Elle maintient des **vues matérialisées incrémentales** sur
des flux (Kafka, CDC PostgreSQL…) ou des tables.

Elle est installée avec **l'opérateur RisingWave**, dans un namespace dédié, et
s'appuie sur l'infrastructure existante :

| Rôle RisingWave | Notre système |
|---|---|
| **Meta store** (catalogue, métadonnées) | PostgreSQL `pg-main` (CNPG), base `risingwave`, rôle `risingwave` |
| **State store** (Hummock : état et données) | Garage S3, bucket `risingwave` |

## Prérequis

- [07 — PostgreSQL (CloudNativePG)](07-postgresql-cloudnativepg.md)
- [09 — Stockage objet S3 (Garage)](09-s3-garage.md)
- cert-manager (installé avec le cluster, utilisé par le webhook de l'opérateur)

## Installation

```bash
make sync SELECTOR=name=garage             # hook postsync : bucket + clé + secret s3-risingwave
make apply SELECTOR=name=pg-main           # rôle + base risingwave
make apply SELECTOR=name=risingwave-operator
make apply SELECTOR=name=risingwave
```

(ou simplement `make sync`, l'ordre est géré par `needs`).

| Release | Namespace | Chart | Rôle |
|---|---|---|---|
| `risingwave-operator` | `risingwave-operator-system` | `risingwavelabs/risingwave-operator` 0.1.40 (opérateur v0.18) | CRD + contrôleur |
| `risingwave` | `risingwave` | `./charts/risingwave` (chart local) | ressource `RisingWave` + Ingress du dashboard |

Secrets créés automatiquement :

| Secret | Créé par | Contenu |
|---|---|---|
| `databases/pg-main-role-risingwave` | hook `prepare` de pg-main (`scripts/pg-role-secret.sh`) | basic-auth du rôle, lu par CNPG |
| `risingwave/pg-risingwave` | même hook (copie) | `username` / `password` pour le meta store |
| `risingwave/s3-risingwave` | hook `postsync` de garage (`garage-init.sh`) | clé S3 du bucket `risingwave` |
| `risingwave/risingwave-secret-store` | hook `prepare` (`ensure-secret.sh … privateKey=hex16`) | clé 128 bits du secret store (`CREATE SECRET`) |

## Configuration

`deploy/k8s/charts/risingwave/` (template) et `deploy/k8s/values/risingwave.yaml.gotmpl` :

| Paramètre | Valeur |
|---|---|
| Image | `risingwavelabs/risingwave:v3.1.1` (~2,4 Go) |
| Mode | distribué : meta, frontend, compute, compactor (1 réplica chacun) |
| Meta store | `pg-main-rw.databases.svc:5432`, base `risingwave` |
| State store | `http://garage.garage.svc:3900`, région `garage`, bucket `risingwave`, préfixe `hummock`, `forcePathStyle: true` |
| Ressources (limites CPU / mémoire) | meta 0,5/1Gi · frontend 0,5/1Gi · compute 2/4Gi · compactor 1/2Gi (≤ 4 cœurs : licence gratuite, voir pièges) |

Côté `pg-main` (`values/pg-main.yaml.gotmpl`) : `cluster.roles` (rôle `risingwave`,
mot de passe depuis le secret) et `databases` (ressource CNPG `Database`
`risingwave`, propriétaire `risingwave`, `databaseReclaimPolicy: retain`).

## Licence : édition Community (open source) et fonctions Premium

> Sources : [RisingWave Premium Edition](https://docs.risingwave.com/get-started/rw-premium-edition-intro),
> [Premium features](https://docs.risingwave.com/get-started/premium-features)
> (consultées le 2026-11-11, RisingWave v3.1.1). À revérifier à chaque montée de version.

### Deux éditions, un seul binaire

| | **Community** | **Premium** |
|---|---|---|
| Licence | **Apache 2.0**, gratuite | commerciale (clé de licence) |
| Contenu | le moteur et la plupart des fonctions | fonctions « entreprise » listées ci-dessous |
| Binaire / image | `risingwavelabs/risingwave` | **le même** : les fonctions Premium sont activées par une clé |
| Clé | — | JWT (niveau, `rwu_limit`, expiration), obtenue auprès de `sales@risingwave-labs.com` |
| Support | communauté (Slack, GitHub) | non inclus dans la clé (offres Pro / Mission-Critical en plus) |

### Licence d'essai intégrée (notre cas)

Une nouvelle installation embarque une clé par défaut. Elle débloque **toutes**
les fonctions Premium, mais uniquement sur un **petit** cluster :

| Élément | Valeur (vérifiée sur notre instance) |
|---|---|
| Clé | `rw-default-all-4-core`, `tier: all`, paramètre système `license_key = <default>` |
| Limite | **4 RWU** = **4 cœurs CPU et 16 Gio de mémoire** au total (1 RWU = 1 cœur + 4 Gio) |
| Expiration | `exp: 10000627200` (an 2286) : pas d'expiration en pratique |
| Ce qui est compté | les ressources de **tous** les nœuds (meta, frontend, compute, compactor), lues depuis les **limites cgroup** des pods. Sans limite, c'est le CPU de l'hôte (16 × 4 = 64) |
| Notre consommation | 3 cœurs / 8 Gio (`make rw-license`) |

**Si la limite est dépassée** : les fonctions Premium sont désactivées, pour les
jobs **existants comme pour les nouveaux**, jusqu'à l'installation d'une clé
payante. Le moteur Community continue de fonctionner.

> ⚠️ Conséquence pour ce projet : notre source CDC utilise `CREATE SECRET`
> (Premium, voir [13](13-cdc-pg-main-risingwave.md)). Si on augmente les
> `replicas` ou les limites CPU/mémoire au-delà de 4 cœurs ou 16 Gio, le secret
> n'est plus utilisable. → Contrôler `make rw-license` après tout redimensionnement,
> ou basculer la source CDC vers un mot de passe en clair (voir plus bas).

### Fonctions soumises à licence (Premium)

Liste officielle (`SELECT * FROM rw_features;`, 22 fonctions en v3.1.1) :

| Catégorie | Fonctions Premium | Nom dans `rw_features` |
|---|---|---|
| Sécurité / SQL | **Gestion des secrets** (`CREATE SECRET`) | `SecretManagement` |
| | Requêtes *time travel* (données passées) | `TimeTravel` |
| | Isolation des pannes entre bases | `DatabaseFailureIsolation` |
| | Groupes de ressources (isolation des charges) | `ResourceGroup` |
| Performance | Cache disque élastique | `ElasticDiskCache` |
| | Préchargement mémoire des tables d'état | `StateTableMemoryPreload` |
| | *Locality backfill* | `LocalityBackfill` |
| Schéma | Propagation automatique des DDL en CDC (PostgreSQL, MySQL) | `CdcAutoSchemaChange` |
| | Changement de schéma automatique des sinks (Elasticsearch, Snowflake, Redshift) | `SinkAutoSchemaChange` |
| | Registre de schémas AWS Glue (Kafka) | `GlueSchemaRegistry` |
| Connecteurs | Source CDC **SQL Server** | `SqlServerCdcSource` |
| | Sinks Snowflake, DynamoDB, OpenSearch, BigQuery, SQL Server, Redis Streams | `SnowflakeSink`, `DynamoDbSink`, `OpenSearchSink`, `BigQuerySink`, `SqlServerSink`, `RedisSinkStream` |
| | ClickHouse Cloud (SharedMergeTree) | `ClickHouseSharedEngine` |
| | Iceberg avec catalogue Glue, compaction Iceberg automatique | `IcebergSinkWithGlue`, `IcebergCompaction` |
| | Sink à partir d'un horodatage passé | `SinkSinceTimestamp` |
| | Ingestion WebSocket | `WebSocketIngest` |
| Outillage | RisingWave Console (interface de gestion) | — |

### Ce qui reste libre (Community, Apache 2.0)

Le moteur de streaming et ce que nous utilisons hors secrets :

- tables, **vues matérialisées incrémentales**, jointures, agrégations, fenêtres ;
- protocole PostgreSQL (psql, pgAdmin, pilotes JDBC, etc.) ;
- state store S3 (Garage) et meta store PostgreSQL ;
- **source CDC PostgreSQL** (`postgres-cdc`) et MySQL. Seule la *propagation
  automatique des changements de schéma* (`CdcAutoSchemaChange`) est Premium :
  sans elle, un `ALTER TABLE` côté pg-main doit être reporté à la main côté
  RisingWave ;
- les autres connecteurs courants (Kafka, sinks PostgreSQL, S3, Iceberg avec
  catalogues non-Glue…) : aucun n'apparaît dans `rw_features`.

### Rester 100 % Community (sans fonction Premium)

Si le cluster doit dépasser 4 cœurs / 16 Gio sans clé payante :

1. Remplacer le secret par le mot de passe dans la source CDC
   (`password = '…'` au lieu de `password = SECRET pg_main_cdc_password`). Le mot de
   passe est alors visible par `SHOW CREATE SOURCE` et stocké en clair dans le
   catalogue (base `risingwave` de pg-main). C'est acceptable en labo, avec le
   rôle `rw_cdc` en lecture seule.
2. Reporter manuellement les changements de schéma des tables CDC.
3. Vérifier avec `SELECT name FROM rw_features WHERE available;` qu'aucun job ne
   dépend d'une fonction Premium.

### Installer une clé payante (si besoin)

- **Opérateur** : clé dans un Secret Kubernetes, référencée par la ressource
  `RisingWave` (les mises à jour du Secret sont propagées automatiquement) ;
- ou variable `RW_LICENSE_KEY` / fichier `RW_LICENSE_KEY_PATH` sur le nœud meta ;
- ou `ALTER SYSTEM SET license_key TO '…';` (à renouveler soi-même avant expiration).
- Revenir à la clé d'essai : `ALTER SYSTEM SET license_key TO DEFAULT;`

### Vérifier

```bash
make rw-license
```

```sql
SELECT rw_license();                          -- tier, rwu_limit, exp
SELECT rw_test_feature('SecretManagement');   -- t / f
SELECT * FROM rw_features;                    -- toutes les fonctions Premium et leur disponibilité
SELECT sum(system_total_cpu_cores), sum(system_total_memory_bytes) FROM rw_worker_nodes;
```

## Accès

| Accès | Commande / URL |
|---|---|
| SQL dans le cluster | `make rw-psql` (psql, base `dev`, utilisateur `root`) |
| SQL depuis l'hôte | `make rw-forward`, puis `psql -h localhost -p 4567 -U root -d dev` |
| Dashboard | https://risingwave.k8s.test |
| Service interne | `risingwave-frontend.risingwave.svc:4567` |
| État | `make rw-status` |
| Licence | `make rw-license` |

## Vérification (testée le 2026-11-11)

```sql
CREATE TABLE orders (id INT PRIMARY KEY, customer VARCHAR, amount NUMERIC, ts TIMESTAMPTZ DEFAULT now());
CREATE MATERIALIZED VIEW revenue_by_customer AS
  SELECT customer, count(*) AS n, sum(amount) AS total FROM orders GROUP BY customer;
INSERT INTO orders (id, customer, amount) VALUES (1,'alice',10),(2,'bob',5),(3,'alice',7.5);
FLUSH;
SELECT * FROM revenue_by_customer;      -- alice 17.5 / bob 5
INSERT INTO orders (id, customer, amount) VALUES (4,'bob',20);
FLUSH;
SELECT * FROM revenue_by_customer;      -- bob passe à 25 (mise à jour incrémentale)
```

Résultats :

- `RisingWave … RUNNING True`, 4 pods `1/1` ✅
- Vue matérialisée mise à jour de façon incrémentale ✅
- Garage : bucket `risingwave` → 23 objets (Hummock) ✅
- PostgreSQL : base `risingwave` → 50 tables de métadonnées, propriétaire `risingwave` ✅
- Suppression des 4 pods → redémarrage, données intactes (`alice=17.5`, `bob=25`) ✅
- `https://risingwave.k8s.test` → 200 ✅

## Pièges rencontrés

- **Licence gratuite limitée à 4 cœurs** : sans limite CPU, chaque composant voit
  les 16 cœurs de l'hôte (64 au total). Les fonctions sous licence, comme
  `CREATE SECRET`, sont alors refusées. → Limites CPU dont la somme reste ≤ 4
  (`SELECT type, system_total_cpu_cores FROM rw_worker_nodes`). Voir la section
  [Licence](#licence--édition-community-open-source-et-fonctions-premium) et
  [13](13-cdc-pg-main-risingwave.md).

- **Port du frontend : 4567**, et non 4566 (valeur de la doc RisingWave) :
  l'opérateur v0.18 publie `4567` (SQL), `4560` (HTTP) et `8080` (métriques).
- **`role "risingwave" does not exist`** sur la ressource `Database` au premier
  apply : la base a été créée avant le rôle. CNPG réessaie tout seul et l'erreur
  disparaît en quelques secondes.
- La CRD `RisingWave` n'existe qu'après l'installation de l'opérateur :
  `disableValidationOnInstall: true` + `needs` sur la release.
- Garage impose le **path-style** et la région `garage` : `forcePathStyle: true` et
  `region: garage` dans `stateStore.s3`.
- `make recreate` : le meta store vit dans `pg-main` et le state store dans Garage.
  Après une recréation, il faut restaurer `pg-main` ([10](10-sauvegardes-postgresql.md))
  pour que le catalogue RisingWave corresponde au contenu du bucket.

## Pour aller plus loin

- **CDC depuis pg-main** : ✅ mis en place, voir [13 — CDC pg-main → RisingWave](13-cdc-pg-main-risingwave.md).
- **Source et sink Kafka (Redpanda)** : ✅ mis en place, voir [15 — RisingWave ⇄ Redpanda (source et sink Kafka)](15-risingwave-redpanda.md).
- **Sink** vers PostgreSQL, Iceberg ou S3 (bucket `projet`).
- Montée en charge : `replicas` par composant dans `values/risingwave.yaml.gotmpl`.

## Désinstallation

```bash
helmfile -f deploy/k8s/helmfile.yaml.gotmpl -l name=risingwave destroy
helmfile -f deploy/k8s/helmfile.yaml.gotmpl -l name=risingwave-operator destroy
# données : bucket risingwave (garage-webui ou garage bucket delete) et base risingwave (DROP DATABASE)
```
