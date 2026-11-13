-- CDC pg-main (base 'app') -> RisingWave. Idempotent : make rw-cdc-setup
-- Variable psql : cdc_password (secret risingwave/pg-rw-cdc).

-- Mot de passe stocké chiffré dans le secret store RisingWave (clé risingwave-secret-store).
CREATE SECRET IF NOT EXISTS pg_main_cdc_password WITH (backend = 'meta') AS :'cdc_password';

-- Source CDC partagée : un seul slot de réplication logique pour toutes les tables.
CREATE SOURCE IF NOT EXISTS pg_main_app WITH (
  connector                 = 'postgres-cdc',
  hostname                  = 'pg-main-rw.databases.svc',
  port                      = '5432',
  username                  = 'rw_cdc',
  password                  = SECRET pg_main_cdc_password,
  database.name             = 'app',
  schema.name               = 'public',
  ssl.mode                  = 'required',
  publication.name          = 'rw_cdc',      -- créée par CNPG (release pg-main-objects)
  publication.create.enable = 'false',
  slot.name                 = 'risingwave_app'
);

-- Tables répliquées (snapshot initial puis flux continu des INSERT/UPDATE/DELETE).
CREATE TABLE IF NOT EXISTS app_customers (
  id   INT PRIMARY KEY,
  name VARCHAR,
  city VARCHAR
) FROM pg_main_app TABLE 'public.customers';

CREATE TABLE IF NOT EXISTS app_orders (
  id          INT PRIMARY KEY,
  customer_id INT,
  amount      NUMERIC,
  created_at  TIMESTAMPTZ
) FROM pg_main_app TABLE 'public.orders';

-- Vue matérialisée incrémentale : chiffre d'affaires par ville (jointure en streaming).
CREATE MATERIALIZED VIEW IF NOT EXISTS app_revenue_by_city AS
SELECT c.city,
       count(o.id)   AS orders,
       sum(o.amount) AS revenue
FROM app_orders o
JOIN app_customers c ON o.customer_id = c.id
GROUP BY c.city;
