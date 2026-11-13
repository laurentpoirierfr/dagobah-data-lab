-- Tables de démo dans la base 'app' de pg-main (propriétaire : app).
-- Répliquées vers RisingWave par CDC (publication rw_cdc, FOR ALL TABLES).
-- Idempotent : make cdc-seed

CREATE TABLE IF NOT EXISTS customers (
  id    INT PRIMARY KEY,
  name  TEXT NOT NULL,
  city  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS orders (
  id          INT PRIMARY KEY,
  customer_id INT NOT NULL REFERENCES customers(id),
  amount      NUMERIC(10,2) NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO customers (id, name, city) VALUES
  (1, 'Alice', 'Paris'), (2, 'Bob', 'Lyon'), (3, 'Chloé', 'Paris'), (4, 'David', 'Nantes')
ON CONFLICT (id) DO NOTHING;

INSERT INTO orders (id, customer_id, amount) VALUES
  (1, 1, 120.00), (2, 2, 35.50), (3, 3, 80.00), (4, 1, 15.25), (5, 4, 60.00)
ON CONFLICT (id) DO NOTHING;
