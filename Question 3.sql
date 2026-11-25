DROP SCHEMA IF EXISTS q3 CASCADE;
CREATE SCHEMA q3;
SET search_path TO q3;

-- (a) Database and seed data
CREATE TABLE books (
  book_id SERIAL PRIMARY KEY,
  title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
  loan_id       SERIAL PRIMARY KEY,
  book_id       INTEGER       NOT NULL REFERENCES books(book_id),
  borrower_name VARCHAR(100)  NOT NULL,
  borrowed_on   DATE          NOT NULL,
  due_on        DATE          NOT NULL,
  returned_on   DATE,
  fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
  CONSTRAINT ck_due_after_borrowed CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
  audit_id        SERIAL PRIMARY KEY,
  loan_id         INTEGER   NOT NULL REFERENCES loans(loan_id),
  old_returned_on DATE,
  new_returned_on DATE,
  changed_at      TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
  snapshot_date DATE PRIMARY KEY,
  overdue_count INTEGER       NOT NULL,
  total_fine    NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title) VALUES
  ('Database System Concepts'),
  ('Introduction to Algorithms'),
  ('Computer Networks');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
  (1, 'Chanda Mwila', CURRENT_DATE - 20, CURRENT_DATE -  6),
  (1, 'Mutale Banda', CURRENT_DATE - 10, CURRENT_DATE -  3),
  (2, 'Tembo Phiri',  CURRENT_DATE - 30, CURRENT_DATE - 15),
  (2, 'Bwalya Zulu',  CURRENT_DATE -  2, CURRENT_DATE + 12),
  (3, 'Namwali Daka', CURRENT_DATE - 40, CURRENT_DATE - 20),
  (3, 'Kabwe Lungu',  CURRENT_DATE - 14, CURRENT_DATE -  7);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
  v_due      DATE;
  v_returned DATE;
  v_end      DATE;
BEGIN
  IF p_as_of IS NULL THEN
    RAISE EXCEPTION 'p_as_of is required';
  END IF;

  SELECT due_on, returned_on INTO v_due, v_returned
  FROM loans
  WHERE loan_id = p_loan_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown loan_id %', p_loan_id;
  END IF;

  v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));

  RETURN GREATEST(0, v_end - v_due) * 2.00;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
  v_borrowed DATE;
  v_returned DATE;
  v_fine     NUMERIC(10,2);
BEGIN
  IF p_returned_on IS NULL THEN
    RAISE EXCEPTION 'Return date is required';
  END IF;

  SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
  FROM loans
  WHERE loan_id = p_loan_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown loan_id %', p_loan_id;
  END IF;
  IF v_returned IS NOT NULL THEN
    RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
  END IF;
  IF p_returned_on < v_borrowed THEN
    RAISE EXCEPTION 'Return date % is before borrowed date %', p_returned_on, v_borrowed;
  END IF;

  v_fine := fn_loan_fine(p_loan_id, p_returned_on);

  UPDATE loans
  SET returned_on = p_returned_on,
      fine_amount = v_fine
  WHERE loan_id = p_loan_id;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
  VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, now());
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_returned_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();

-- (a) continued: returned loans processed through the procedure
CALL pr_return_loan(2, CURRENT_DATE - 5);
CALL pr_return_loan(3, CURRENT_DATE - 10);
CALL pr_return_loan(6, CURRENT_DATE - 7);

-- (b) and (c) tests
SELECT loan_id, due_on, returned_on, fine_amount,
       fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today
FROM loans
ORDER BY loan_id;

DO $$
BEGIN
  BEGIN CALL pr_return_loan(2, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END;
  BEGIN CALL pr_return_loan(999, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END;
  BEGIN CALL pr_return_loan(1, CURRENT_DATE - 100);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END;
END $$;

-- (d) tests
SELECT * FROM loan_audit ORDER BY audit_id;

UPDATE loans SET borrower_name = borrower_name WHERE loan_id = 2;
SELECT count(*) FROM loan_audit;

-- (e) View
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- (f) Index
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;

ANALYZE loans;
SET enable_seqscan = off;
EXPLAIN
SELECT *
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_as_of IS NULL THEN
    RAISE EXCEPTION 'p_as_of is required';
  END IF;

  INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
  SELECT p_as_of,
         COUNT(*),
         COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
  FROM loans
  WHERE borrowed_on <= p_as_of
    AND (returned_on IS NULL OR returned_on > p_as_of)
    AND due_on < p_as_of
  ON CONFLICT (snapshot_date) DO UPDATE
  SET overdue_count = EXCLUDED.overdue_count,
      total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
  'q3_refresh_overdue',
  '10 0 * * *',
  $$CALL q3.pr_refresh_overdue(CURRENT_DATE)$$
);