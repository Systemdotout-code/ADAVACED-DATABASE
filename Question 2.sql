DROP SCHEMA IF EXISTS q2 CASCADE;
CREATE SCHEMA q2;
SET search_path TO q2;

-- (a) Database and seed data
CREATE TABLE students (
  student_id     SERIAL PRIMARY KEY,
  student_number VARCHAR(20)   NOT NULL UNIQUE,
  full_name      VARCHAR(100)  NOT NULL,
  fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
  payment_id SERIAL PRIMARY KEY,
  student_id INTEGER       NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  paid_on    DATE          NOT NULL
);

CREATE TABLE payment_audit (
  audit_id   SERIAL PRIMARY KEY,
  payment_id INTEGER       NOT NULL REFERENCES payments(payment_id),
  student_id INTEGER       NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL,
  logged_at  TIMESTAMP     NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
  collection_date DATE PRIMARY KEY,
  payment_count   INTEGER       NOT NULL,
  total_amount    NUMERIC(12,2) NOT NULL
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
  ('S2026001', 'Chanda Mwila', 5000.00),
  ('S2026002', 'Mutale Banda', 3000.00),
  ('S2026003', 'Tembo Phiri',  2000.00);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
  v_fee  NUMERIC(12,2);
  v_paid NUMERIC(12,2);
BEGIN
  SELECT fee_due INTO v_fee
  FROM students
  WHERE student_id = p_student_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student_id %', p_student_id;
  END IF;

  SELECT COALESCE(SUM(amount), 0) INTO v_paid
  FROM payments
  WHERE student_id = p_student_id;

  RETURN v_fee - v_paid;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INTEGER, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
  v_balance NUMERIC(12,2);
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Payment amount must be positive (got %)', p_amount;
  END IF;
  IF p_paid_on IS NULL THEN
    RAISE EXCEPTION 'Payment date is required';
  END IF;

  PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student_id %', p_student_id;
  END IF;

  v_balance := fn_fee_balance(p_student_id);
  IF p_amount > v_balance THEN
    RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
  END IF;

  INSERT INTO payments (student_id, amount, paid_on)
  VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
  VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payment_audit();

-- (a) continued: six payments loaded through the procedure
CALL pr_receive_payment(1, 1000.00, CURRENT_DATE - 3);
CALL pr_receive_payment(1, 1500.00, CURRENT_DATE - 2);
CALL pr_receive_payment(1,  500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 3);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 1);

-- (b) and (c) tests
SELECT student_id, fn_fee_balance(student_id) AS balance
FROM students
ORDER BY student_id;

DO $$
BEGIN
  BEGIN CALL pr_receive_payment(3, 5000, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END;
  BEGIN CALL pr_receive_payment(3, 0, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END;
  BEGIN CALL pr_receive_payment(3, NULL, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END;
  BEGIN PERFORM fn_fee_balance(999);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END;
END $$;

-- (d) test
SELECT * FROM payment_audit ORDER BY audit_id;

-- (e) View
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(p.paid, 0) AS outstanding_balance
FROM students s
LEFT JOIN (
  SELECT student_id, SUM(amount) AS paid
  FROM payments
  GROUP BY student_id
) p ON p.student_id = s.student_id
WHERE s.fee_due - COALESCE(p.paid, 0) > 0;

SELECT * FROM v_fee_balances;

-- (f) Index
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);

ANALYZE payments;
SET enable_seqscan = off;
EXPLAIN
SELECT *
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN CURRENT_DATE - 5 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_day IS NULL THEN
    RAISE EXCEPTION 'p_day is required';
  END IF;

  INSERT INTO daily_collections (collection_date, payment_count, total_amount)
  SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
  FROM payments
  WHERE paid_on = p_day
  ON CONFLICT (collection_date) DO UPDATE
  SET payment_count = EXCLUDED.payment_count,
      total_amount  = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);
SELECT * FROM daily_collections;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
  'q2_refresh_collections',
  '0 1 * * *',
  $$CALL q2.pr_refresh_collections(CURRENT_DATE - 1)$$
);