---
title: "15 — RisingWave ⇄ Redpanda (source et sink Kafka)"
weight: 16
---

> [!NOTE]
> Statut : ✅ installé · Date : 2026-11-11

## Objectif

Brancher RisingWave sur Redpanda :

- **Source Kafka** : RisingWave lit en continu les événements JSON du topic
  `shop-events` ;
- **Vues matérialisées** : agrégats par fenêtre de temps, et **jointure du flux
  Kafka avec les tables CDC de pg-main** ([13](13-cdc-pg-main-risingwave.md)) ;
- **Sink Kafka** : chaque mise à jour d'une vue est republiée dans Redpanda
  (topic `shop-activity-by-city`), consommable par d'autres applications.

```
                 Redpanda                          RisingWave                                Redpanda
 producteurs ─▶  shop-events  ──(source kafka)──▶  shop_events ─┬▶ shop_events_per_minute (TUMBLE 1 min)
                                                                └▶ shop_activity_by_city ──(sink upsert)──▶ shop-activity-by-city
 pg-main/app ─(CDC, étape 13)─▶ app_customers ──────────────────────┘ (jointure par customer_id)
```

Tous les connecteurs utilisés (source Kafka, sink Kafka, `FORMAT PLAIN/UPSERT
ENCODE JSON`) font partie de l'édition **Community** de RisingWave (aucun
n'apparaît dans `rw_features`, voir [12 — Licence](12-risingwave.md#licence--édition-community-open-source-et-fonctions-premium)).

## Prérequis

- [12 — RisingWave (base de données de streaming)](12-risingwave.md), [13 — CDC pg-main → RisingWave](13-cdc-pg-main-risingwave.md) (table `app_customers`)
- [14 — Redpanda (streaming compatible Kafka) + Redpanda Console](14-redpanda.md)

## Installation

```bash
make rp-topics           # topics shop-events et shop-activity-by-city (3 partitions, réplication 3)
make rw-kafka-setup      # source, vues, sink dans RisingWave (idempotent)
make rp-demo-events N=60 # événements de démo
make rw-kafka-status     # vues + derniers messages du sink
```

| Fichier | Rôle |
|---|---|
| `deploy/k8s/sql/risingwave/20-kafka-redpanda.sql` | `CREATE SOURCE`, `CREATE MATERIALIZED VIEW` ×2, `CREATE SINK` |
| `deploy/k8s/scripts/rp-demo-events.sh` | producteur de démo (via `rpk topic produce` dans `redpanda-0`) |

### Format des événements (`shop-events`)

```json
{"event_id":"…uuid…","customer_id":2,"event_type":"purchase","amount":120,"event_time":"2026-11-11T20:59:12Z"}
```

`customer_id` (1 à 4) correspond aux clients de `pg-main/app.customers`.
`event_type` vaut `view`, `cart` ou `purchase`.

### Objets RisingWave

```sql
CREATE SOURCE shop_events (event_id VARCHAR, customer_id INT, event_type VARCHAR,
                           amount NUMERIC, event_time TIMESTAMPTZ)
WITH (connector = 'kafka', topic = 'shop-events',
      properties.bootstrap.server = 'redpanda.redpanda.svc.cluster.local:9093',
      scan.startup.mode = 'earliest')
FORMAT PLAIN ENCODE JSON;

CREATE MATERIALIZED VIEW shop_events_per_minute AS
  SELECT window_start, event_type, count(*) AS events, sum(amount) AS amount
  FROM TUMBLE(shop_events, event_time, INTERVAL '1 minute')
  GROUP BY window_start, event_type;

CREATE MATERIALIZED VIEW shop_activity_by_city AS
  SELECT c.city, count(*) FILTER (WHERE e.event_type = 'view') AS views, …
  FROM shop_events e JOIN app_customers c ON e.customer_id = c.id
  GROUP BY c.city;

CREATE SINK shop_activity_by_city_sink FROM shop_activity_by_city
WITH (connector = 'kafka', topic = 'shop-activity-by-city',
      properties.bootstrap.server = 'redpanda.redpanda.svc.cluster.local:9093',
      primary_key = 'city')
FORMAT UPSERT ENCODE JSON;
```

- **Source partagée** (*shared source*) : un seul consommateur Kafka alimente
  toutes les vues construites sur `shop_events`. D'où le message
  `snapshot backfill disabled due to using shared source`, qui est normal.
- La source **ne stocke pas** les événements dans RisingWave : seules les vues
  matérialisent un état. Pour interroger les événements bruts, utiliser
  `CREATE TABLE … WITH (connector='kafka', …)` à la place de `CREATE SOURCE`.
- **Sink upsert** : message avec clé `{"city": …}` et valeur = ligne complète.
  Quand une ligne disparaît de la vue, le sink publie un *tombstone* (valeur
  nulle) pour cette clé.

## Vérification (testée le 2026-11-11)

| Étape | `shop_activity_by_city` (vues+paniers+achats par ville) |
|---|---|
| 60 événements produits | Lyon 32 · Nantes 13 · Paris 15 (total 60 ✅) |
| +40 événements | Lyon 56 · Nantes 21 · Paris 23 (total 100 ✅) |
| **CDC** : `UPDATE customers SET city='Bordeaux' WHERE id=4` dans pg-main | **Bordeaux 21** · Lyon 56 · Paris 23 : les événements passés de David sont réaffectés |

- `shop_events_per_minute` : fenêtre `20:59` → view 34, cart 18, purchase 8
  (980 €) pour les 60 premiers événements ✅
- Topic `shop-activity-by-city` : une valeur par ville, mise à jour en temps réel,
  y compris `Bordeaux` après la modification CDC ✅
- Visible aussi dans la console Redpanda (https://redpanda.k8s.test) : topics
  `shop-events` et `shop-activity-by-city`, et le groupe de consommateurs de
  RisingWave ✅

## Ajouter un flux

1. `make rp-topics RP_TOPICS="mon-topic"` (ou laisser la création automatique)
2. Ajouter `CREATE SOURCE … topic = 'mon-topic' …` et les vues dans un nouveau
   fichier `deploy/k8s/sql/risingwave/30-….sql` (avec `IF NOT EXISTS`)
3. L'appliquer avec la même commande que `make rw-kafka-setup`, en changeant le
   fichier.

Autres formats : `ENCODE AVRO` / `ENCODE PROTOBUF` avec le Schema Registry de
Redpanda (`schema.registry = 'http://redpanda.redpanda.svc.cluster.local:8081'`).

## Pièges rencontrés

- `rpk topic consume -n 4` **attend indéfiniment** s'il y a moins de 4 messages.
  Pour lire jusqu'à la fin puis s'arrêter : `-o :end` (utilisé par
  `make rw-kafka-status`).
- Connexion en PLAINTEXT sans SASL (configuration de labo de Redpanda, voir
  [14](14-redpanda.md)). Si on active SASL/TLS, ajouter
  `properties.security.protocol`, `properties.sasl.mechanism`,
  `properties.sasl.username` / `password` dans la source et le sink.
- **Rétention** : `shop-events` garde les messages selon la rétention par défaut
  de Redpanda, sur des PVC de 10 Gi. Avec `scan.startup.mode = 'earliest'`, une
  source recréée relit tout ce qui reste dans le topic.

## Désinstallation

```sql
DROP SINK shop_activity_by_city_sink;
DROP MATERIALIZED VIEW shop_activity_by_city;
DROP MATERIALIZED VIEW shop_events_per_minute;
DROP SOURCE shop_events;
```

```bash
make rpk ARGS="topic delete shop-events shop-activity-by-city"
```
