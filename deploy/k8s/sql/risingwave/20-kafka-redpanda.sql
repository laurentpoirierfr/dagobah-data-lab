-- Redpanda (Kafka) -> RisingWave -> Redpanda. Idempotent : make rw-kafka-setup
-- Prérequis : topics (make rp-topics), table CDC app_customers (10-cdc-pg-main.sql).

-- Source Kafka : événements JSON du topic shop-events (lecture depuis le début).
CREATE SOURCE IF NOT EXISTS shop_events (
  event_id    VARCHAR,
  customer_id INT,
  event_type  VARCHAR,       -- view | cart | purchase
  amount      NUMERIC,
  event_time  TIMESTAMPTZ
) WITH (
  connector                   = 'kafka',
  topic                       = 'shop-events',
  properties.bootstrap.server = 'redpanda.redpanda.svc.cluster.local:9093',
  scan.startup.mode           = 'earliest'
) FORMAT PLAIN ENCODE JSON;

-- Fenêtres de 1 minute par type d'événement.
CREATE MATERIALIZED VIEW IF NOT EXISTS shop_events_per_minute AS
SELECT window_start, event_type, count(*) AS events, sum(amount) AS amount
FROM TUMBLE(shop_events, event_time, INTERVAL '1 minute')
GROUP BY window_start, event_type;

-- Jointure flux Kafka x table CDC PostgreSQL : activité par ville.
CREATE MATERIALIZED VIEW IF NOT EXISTS shop_activity_by_city AS
SELECT c.city,
       count(*) FILTER (WHERE e.event_type = 'view')     AS views,
       count(*) FILTER (WHERE e.event_type = 'cart')     AS carts,
       count(*) FILTER (WHERE e.event_type = 'purchase') AS purchases,
       coalesce(sum(e.amount) FILTER (WHERE e.event_type = 'purchase'), 0) AS revenue
FROM shop_events e
JOIN app_customers c ON e.customer_id = c.id
GROUP BY c.city;

-- Sink Kafka : chaque mise à jour de la vue est publiée (upsert, clé = city).
CREATE SINK IF NOT EXISTS shop_activity_by_city_sink FROM shop_activity_by_city
WITH (
  connector                   = 'kafka',
  topic                       = 'shop-activity-by-city',
  properties.bootstrap.server = 'redpanda.redpanda.svc.cluster.local:9093',
  primary_key                 = 'city'
) FORMAT UPSERT ENCODE JSON;
