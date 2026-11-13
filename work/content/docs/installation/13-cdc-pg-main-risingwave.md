---
title: "13 — CDC pg-main → RisingWave"
weight: 14
---

> [!NOTE]
> Statut : ✅ installé · Date : 2026-11-11

## Objectif

Répliquer en continu (Change Data Capture) les tables de la base `app` de
`pg-main` vers RisingWave, et y maintenir des vues matérialisées à jour en
temps réel. Les vues incluent des jointures entre tables PostgreSQL.

```
pg-main (app)  ── réplication logique (pgoutput, slot risingwave_app) ──▶  RisingWave
  customers                publication rw_cdc (FOR ALL TABLES)               app_customers ─┐
  orders                                                                     app_orders ────┴▶ app_revenue_by_city (MV)
```

## Prérequis

- [07 — PostgreSQL (CloudNativePG)](07-postgresql-cloudnativepg.md), [12 — RisingWave (base de données de streaming)](12-risingwave.md)
- `wal_level = logical` sur pg-main : **déjà le cas** par défaut avec CNPG 1.30
  (`SHOW wal_level` → `logical`), donc aucun redémarrage n'est nécessaire.

## Installation

```bash
make apply SELECTOR=name=pg-main            # rôle rw_cdc (+ secret copié dans risingwave)
make apply SELECTOR=name=pg-main-objects    # publication rw_cdc
make cdc-seed                               # tables de démo dans app (customers, orders)
make rw-cdc-setup                           # secret, source CDC, tables, vue dans RisingWave
make cdc-status                             # slot de réplication + vue
```

### Côté PostgreSQL (déclaratif, helmfile)

| Objet | Où | Détail |
|---|---|---|
| Rôle `rw_cdc` | `values/pg-main.yaml.gotmpl` → `cluster.roles` | `login`, `replication: true`, membre de `pg_read_all_data` (lecture seule de toutes les tables, pour le snapshot initial) |
| Mot de passe | hook `prepare` `scripts/pg-role-secret.sh … rw_cdc risingwave pg-rw-cdc` | `databases/pg-main-role-rw-cdc` (lu par CNPG) → copie `risingwave/pg-rw-cdc` |
| Publication `rw_cdc` | release `pg-main-objects` (chart local `charts/pg-objects`), `values/pg-main-objects.yaml` | ressource CNPG `Publication`, `FOR ALL TABLES` sur `app`, tables futures incluses |
| Slot `risingwave_app` | créé par RisingWave | `pgoutput`, un seul slot pour toutes les tables de la source |

### Côté RisingWave (SQL, `deploy/k8s/sql/risingwave/10-cdc-pg-main.sql`)

```sql
CREATE SECRET IF NOT EXISTS pg_main_cdc_password WITH (backend = 'meta') AS :'cdc_password';

CREATE SOURCE IF NOT EXISTS pg_main_app WITH (
  connector = 'postgres-cdc', hostname = 'pg-main-rw.databases.svc', port = '5432',
  username = 'rw_cdc', password = SECRET pg_main_cdc_password,
  database.name = 'app', schema.name = 'public', ssl.mode = 'required',
  publication.name = 'rw_cdc', publication.create.enable = 'false',
  slot.name = 'risingwave_app');

CREATE TABLE IF NOT EXISTS app_customers (id INT PRIMARY KEY, name VARCHAR, city VARCHAR)
  FROM pg_main_app TABLE 'public.customers';
CREATE TABLE IF NOT EXISTS app_orders (id INT PRIMARY KEY, customer_id INT, amount NUMERIC, created_at TIMESTAMPTZ)
  FROM pg_main_app TABLE 'public.orders';

CREATE MATERIALIZED VIEW IF NOT EXISTS app_revenue_by_city AS
  SELECT c.city, count(o.id) AS orders, sum(o.amount) AS revenue
  FROM app_orders o JOIN app_customers c ON o.customer_id = c.id GROUP BY c.city;
```

`make rw-cdc-setup` passe le mot de passe (secret `pg-rw-cdc`) en variable psql.
Il est stocké **chiffré** dans le secret store de RisingWave, et non en clair dans
le catalogue. Le script est idempotent.

Données de démo : `deploy/k8s/sql/app/10-cdc-demo.sql` (exécuté en tant que `app`).

## Ajouter une table au CDC

1. Créer la table dans `app` (avec une **clé primaire**). La publication
   `FOR ALL TABLES` l'inclut automatiquement.
2. Ajouter dans `10-cdc-pg-main.sql` :
   `CREATE TABLE IF NOT EXISTS app_xxx (…) FROM pg_main_app TABLE 'public.xxx';`
3. `make rw-cdc-setup`

## Vérification (testée le 2026-11-11)

```bash
make cdc-status
```

| Étape | Vue `app_revenue_by_city` |
|---|---|
| Snapshot initial | Lyon 1 / 35.50 · Nantes 1 / 60.00 · Paris 3 / 215.25 |
| `INSERT` commande Lyon +100 | Lyon 2 / 135.50 |
| `UPDATE customers SET city='Lyon' WHERE id=3` | Lyon 3 / 215.50 · Paris 2 / 135.25 (jointure recalculée) |
| `DELETE FROM orders WHERE id=5` | Nantes disparaît |

Chaque modification apparaît dans RisingWave en **moins de 2 s**. Slot
`risingwave_app` actif, retard ~200 kB.

## Pièges rencontrés

- **`feature SecretManagement is not available due to license error … CPU core in
  the cluster (64) exceeds the maximum allowed by the license key (4)`** :
  RisingWave 3.x réserve `CREATE SECRET` à sa licence. La licence gratuite
  intégrée va jusqu'à **4 cœurs**. Sans limite CPU, chaque composant voyait les
  16 cœurs de l'hôte. → Limites CPU dans `values/risingwave.yaml.gotmpl`
  (compute 2, compactor 1, meta et frontend 0,5) : 3 cœurs comptés
  (`SELECT type, system_total_cpu_cores FROM rw_worker_nodes`). Détails et
  alternative 100 % Community (mot de passe en clair) :
  [12 — Licence](12-risingwave.md#licence--édition-community-open-source-et-fonctions-premium).
- **Changements de schéma** : la propagation automatique des `ALTER TABLE` de
  pg-main (`CdcAutoSchemaChange`) est une fonction Premium. Sans elle, reporter
  le changement à la main dans `10-cdc-pg-main.sql`.
- **Nom de secret avec `_`** : `pg-main-role-rw_cdc` est refusé par Kubernetes
  (RFC 1123). Le script convertit `_` en `-` (`pg-main-role-rw-cdc`). Le rôle
  PostgreSQL garde le nom `rw_cdc`.
- `publication.create.enable = 'false'` : `rw_cdc` n'est propriétaire d'aucune
  table et ne peut pas créer la publication. Elle est donc gérée par CNPG
  (ressource `Publication`, exécutée en superutilisateur).
- **Slot et bascule** : le slot logique existe **sur le primaire uniquement**. En
  cas de bascule CNPG, le nouveau primaire n'a pas le slot et le CDC s'arrête
  (il faut recréer la source). CNPG 1.27+ / PG17 peut synchroniser les slots
  (`cluster.replicationSlots.highAvailability.synchronizeLogicalDecoding`, avec
  `hot_standby_feedback` et `sync_replication_slots`), mais le slot doit être créé
  avec `failover = true` par le client. Ce n'est pas encore configuré ici.
- **Rétention de WAL** : si RisingWave est arrêté, le slot retient les WAL sur
  pg-main (2 Gi de stockage). Surveiller la colonne `retard` de `make cdc-status`,
  et supprimer la source (`DROP SOURCE pg_main_app CASCADE`, puis
  `SELECT pg_drop_replication_slot('risingwave_app')`) si RisingWave est arrêté
  durablement.

## Désinstallation

```sql
-- RisingWave
DROP MATERIALIZED VIEW app_revenue_by_city;
DROP TABLE app_orders; DROP TABLE app_customers;
DROP SOURCE pg_main_app;
DROP SECRET pg_main_cdc_password;
```

```bash
# PostgreSQL (si le slot n'a pas été supprimé avec la source)
kubectl -n databases exec <primaire> -c postgres -- psql -U postgres -d app \
  -c "SELECT pg_drop_replication_slot('risingwave_app');"
# retirer la publication de values/pg-main-objects.yaml et le rôle rw_cdc, puis make apply
```
