DROP SCHEMA IF EXISTS q6 CASCADE;
CREATE SCHEMA q6;
SET search_path TO q6;

-- (a) Database and seed data
CREATE TABLE employees (
  employee_id  SERIAL PRIMARY KEY,
  full_name    VARCHAR(100)  NOT NULL,
  basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
  allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
  deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
  active       BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
  payroll_id  SERIAL PRIMARY KEY,
  employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
  pay_month   DATE          NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),
  gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
  net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
  CONSTRAINT uq_payroll_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
  audit_id    SERIAL PRIMARY KEY,
  employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
  old_salary  NUMERIC(12,2) NOT NULL,
  new_salary  NUMERIC(12,2) NOT NULL,
  changed_at  TIMESTAMP     NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
  ('Chanda Mwila', 8000.00, 1500.00, 1200.00, TRUE),
  ('Mutale Banda', 6500.00, 1000.00,  900.00, TRUE),
  ('Tembo Phiri',  7200.00,  800.00, 1000.00, TRUE),
  ('Bwalya Zulu',  5000.00,  500.00,  600.00, TRUE);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
  v_basic NUMERIC(12,2);
  v_allow NUMERIC(12,2);
  v_ded   NUMERIC(12,2);
  v_net   NUMERIC(12,2);
BEGIN
  SELECT basic_salary, allowance, deduction INTO v_basic, v_allow, v_ded
  FROM employees
  WHERE employee_id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown employee_id %', p_employee_id;
  END IF;

  v_net := (v_basic + v_allow) - v_ded;

  IF v_net < 0 THEN
    RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
  END IF;

  RETURN v_net;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
  rec   RECORD;
  v_net NUMERIC(12,2);
BEGIN
  IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
    RAISE EXCEPTION 'p_month must be the first date of a month (got %)', p_month;
  END IF;

  FOR rec IN
    SELECT employee_id, basic_salary, allowance
    FROM employees
    WHERE active
    ORDER BY employee_id
  LOOP
    v_net := fn_net_pay(rec.employee_id);

    INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
    VALUES (rec.employee_id, p_month, rec.basic_salary + rec.allowance, v_net)
    ON CONFLICT (employee_id, pay_month) DO NOTHING;
  END LOOP;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
  VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, now());
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- (a) continued: two payroll months, then one employee becomes inactive
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');
UPDATE employees SET active = FALSE WHERE employee_id = 4;

-- (b) tests
SELECT employee_id, fn_net_pay(employee_id) AS net_pay
FROM employees
ORDER BY employee_id;

-- (d) tests
UPDATE employees SET basic_salary = 8500.00 WHERE employee_id = 1;
UPDATE employees SET basic_salary = 6500.00 WHERE employee_id = 2;
SELECT * FROM salary_audit ORDER BY audit_id;

-- (c) tests
CALL pr_process_payroll(DATE '2026-11-01');
CALL pr_process_payroll(DATE '2026-10-01');

SELECT employee_id, pay_month, gross_pay, net_pay
FROM payroll
ORDER BY pay_month, employee_id;

DO $$
DECLARE
  v_id INTEGER;
BEGIN
  BEGIN CALL pr_process_payroll(DATE '2026-12-15');
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END;

  BEGIN PERFORM fn_net_pay(999);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END;

  INSERT INTO employees (full_name, basic_salary, allowance, deduction)
  VALUES ('Bad Data', 100, 0, 500)
  RETURNING employee_id INTO v_id;

  BEGIN CALL pr_process_payroll(DATE '2026-12-01');
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Whole call failed: %', SQLERRM; END;

  RAISE NOTICE 'December rows saved: %',
    (SELECT COUNT(*) FROM payroll WHERE pay_month = DATE '2026-12-01');

  DELETE FROM employees WHERE employee_id = v_id;
END $$;

-- (e) View
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- (f) Index
CREATE INDEX idx_payroll_pay_month
ON payroll (pay_month) INCLUDE (employee_id, gross_pay, net_pay);

ANALYZE payroll;
SET enable_seqscan = off;
EXPLAIN
SELECT employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- (g) Scheduled job
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
  'q6_process_payroll',
  '0 2 1 * *',
  $$CALL q6.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE)$$
);

SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'q6_process_payroll';

SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'q6_process_payroll')
ORDER BY start_time DESC;