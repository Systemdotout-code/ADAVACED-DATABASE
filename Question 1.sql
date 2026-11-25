DROP SCHEMA IF EXISTS q1 CASCADE;
CREATE SCHEMA q1;
SET search_path TO q1;

-- (a) Database and seed data
CREATE TABLE medicines (
  medicine_id   SERIAL PRIMARY KEY,
  medicine_name VARCHAR(100)  NOT NULL UNIQUE,
  unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  stock_qty     INTEGER       NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
  sale_id     SERIAL PRIMARY KEY,
  medicine_id INTEGER       NOT NULL REFERENCES medicines(medicine_id),
  quantity    INTEGER       NOT NULL CHECK (quantity > 0),
  unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  sold_on     DATE          NOT NULL
);

CREATE TABLE stock_audit (
  audit_id    SERIAL PRIMARY KEY,
  medicine_id INTEGER   NOT NULL REFERENCES medicines(medicine_id),
  old_qty     INTEGER   NOT NULL,
  new_qty     INTEGER   NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
  sales_date   DATE PRIMARY KEY,
  total_qty    INTEGER       NOT NULL DEFAULT 0,
  total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
  ('Paracetamol 500mg', 2.50, 100),
  ('Amoxicillin 250mg', 8.00,  30),
  ('Ibuprofen 200mg',   4.00,  12);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
  v_price NUMERIC(10,2);
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be a positive number (got %)', p_quantity;
  END IF;

  SELECT unit_price INTO v_price
  FROM medicines
  WHERE medicine_id = p_medicine_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine_id %', p_medicine_id;
  END IF;

  RETURN v_price * p_quantity;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INTEGER, p_quantity INTEGER, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
  v_price NUMERIC(10,2);
  v_stock INTEGER;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be a positive number (got %)', p_quantity;
  END IF;
  IF p_sold_on IS NULL THEN
    RAISE EXCEPTION 'Sale date is required';
  END IF;

  SELECT unit_price, stock_qty INTO v_price, v_stock
  FROM medicines
  WHERE medicine_id = p_medicine_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine_id %', p_medicine_id;
  END IF;
  IF v_stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock: requested %, available %', p_quantity, v_stock;
  END IF;

  INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
  VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

  UPDATE medicines
  SET stock_qty = stock_qty - p_quantity
  WHERE medicine_id = p_medicine_id;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
  VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, now());
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_fn_stock_audit();

-- (a) continued: six valid sales loaded through the procedure
CALL pr_record_sale(1, 20, CURRENT_DATE - 1);
CALL pr_record_sale(1, 30, CURRENT_DATE);
CALL pr_record_sale(2, 10, CURRENT_DATE - 1);
CALL pr_record_sale(2,  5, CURRENT_DATE);
CALL pr_record_sale(3,  3, CURRENT_DATE - 1);
CALL pr_record_sale(3,  2, CURRENT_DATE);

-- (b) and (c) tests
SELECT fn_sale_value(1, 4);

DO $$
BEGIN
  CALL pr_record_sale(3, 999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Rejected: %', SQLERRM;
END $$;

SELECT * FROM medicines ORDER BY medicine_id;

-- (d) tests
SELECT * FROM stock_audit ORDER BY audit_id;

UPDATE medicines SET unit_price = unit_price WHERE medicine_id = 1;
SELECT count(*) FROM stock_audit;

-- (e) View
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

SELECT * FROM v_low_stock;

-- (f) Index
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);

ANALYZE sales;
SET enable_seqscan = off;
EXPLAIN
SELECT *
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_day IS NULL THEN
    RAISE EXCEPTION 'p_day is required';
  END IF;

  INSERT INTO daily_sales (sales_date, total_qty, total_amount)
  SELECT p_day,
         COALESCE(SUM(quantity), 0),
         COALESCE(SUM(quantity * unit_price), 0)
  FROM sales
  WHERE sold_on = p_day
  ON CONFLICT (sales_date) DO UPDATE
  SET total_qty    = EXCLUDED.total_qty,
      total_amount = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_sales(CURRENT_DATE);
CALL pr_refresh_sales(CURRENT_DATE);
SELECT * FROM daily_sales;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
  'q1_refresh_sales',
  '15 0 * * *',
  $$CALL q1.pr_refresh_sales(CURRENT_DATE - 1)$$
);