-- =========================================================
-- ICT371 ADVANCED DATABASE
-- QUESTION 9: FARMER COOPERATIVE MAIZE DELIVERIES
-- =========================================================


-- =========================
-- (a) CREATE TABLES
-- =========================

CREATE TABLE farmers (
    farmer_id SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id SERIAL PRIMARY KEY,
    farmer_id INT NOT NULL REFERENCES farmers(farmer_id),
    grade CHAR(1) NOT NULL,
    weight_kg NUMERIC(10,2) NOT NULL,
    unit_rate NUMERIC(10,2) NOT NULL DEFAULT 0,
    total_value NUMERIC(12,2) NOT NULL DEFAULT 0,
    delivered_on DATE NOT NULL,
    is_paid BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight NUMERIC(12,2) NOT NULL DEFAULT 0,
    total_value NUMERIC(12,2) NOT NULL DEFAULT 0
);


-- =========================
-- (b) FUNCTION: MAIZE RATE
-- =========================

CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade cannot be NULL';
    END IF;

    CASE UPPER(p_grade)
        WHEN 'A' THEN
            RETURN 5.00;
        WHEN 'B' THEN
            RETURN 4.00;
        WHEN 'C' THEN
            RETURN 3.00;
        ELSE
            RAISE EXCEPTION 'Invalid maize grade: %', p_grade;
    END CASE;
END;
$$;


-- =========================
-- (c) PROCEDURE: RECEIVE DELIVERY
-- =========================

CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INT,
    p_grade CHAR,
    p_weight NUMERIC,
    p_date DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Check farmer exists
    IF NOT EXISTS (
        SELECT 1
        FROM farmers
        WHERE farmer_id = p_farmer_id
    ) THEN
        RAISE EXCEPTION 'Farmer ID % does not exist', p_farmer_id;
    END IF;

    -- Validate grade
    IF p_grade IS NULL OR UPPER(p_grade) NOT IN ('A', 'B', 'C') THEN
        RAISE EXCEPTION 'Invalid maize grade';
    END IF;

    -- Validate weight
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be greater than zero';
    END IF;

    -- Validate delivery date
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date cannot be NULL';
    END IF;

    -- Insert delivery
    -- Trigger will calculate unit_rate and total_value
    INSERT INTO deliveries (
        farmer_id,
        grade,
        weight_kg,
        delivered_on,
        is_paid
    )
    VALUES (
        p_farmer_id,
        UPPER(p_grade),
        p_weight,
        p_date,
        FALSE
    );

    RAISE NOTICE 'Delivery recorded successfully';
END;
$$;


-- =========================
-- (d) TRIGGER: AUTOMATIC PRICING
-- =========================

CREATE OR REPLACE FUNCTION fn_calculate_delivery_value()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Reject invalid weight
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be greater than zero';
    END IF;

    -- Determine price based on grade
    NEW.unit_rate := fn_maize_rate(NEW.grade);

    -- Calculate total delivery value
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_calculate_delivery_value
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION fn_calculate_delivery_value();


-- =========================
-- INSERT SEED DATA
-- =========================

INSERT INTO farmers (farmer_number, full_name)
VALUES
('F001', 'John Banda'),
('F002', 'Mary Phiri'),
('F003', 'Peter Zulu');


-- SIX DELIVERIES
-- Trigger is already installed, so it calculates the prices.

CALL pr_receive_delivery(1, 'A', 100, '2026-01-05');
CALL pr_receive_delivery(1, 'B', 200, '2026-01-06');
CALL pr_receive_delivery(2, 'C', 150, '2026-01-07');
CALL pr_receive_delivery(2, 'A', 300, '2026-01-08');
CALL pr_receive_delivery(3, 'B', 250, '2026-01-09');
CALL pr_receive_delivery(3, 'C', 400, '2026-01-10');


-- UPDATE PAYMENT STATUS
-- Include both paid and unpaid deliveries

UPDATE deliveries
SET is_paid = TRUE
WHERE delivery_id IN (1, 3, 5);


-- CHECK DELIVERIES

SELECT * FROM deliveries;


-- =========================
-- (e) VIEW: FARMER AMOUNT DUE
-- =========================

CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT
    f.farmer_number,
    f.full_name,
    COALESCE(SUM(d.total_value), 0) AS total_unpaid
FROM farmers f
LEFT JOIN deliveries d
    ON f.farmer_id = d.farmer_id
    AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;


-- VIEW FARMER AMOUNTS DUE

SELECT * FROM v_farmer_amount_due;


-- =========================
-- (f) COMPOSITE INDEX
-- =========================

CREATE INDEX idx_deliveries_farmer_date
ON deliveries(farmer_id, delivered_on);


-- QUERY: FARMER DELIVERIES BETWEEN TWO DATES

SELECT
    delivery_id,
    farmer_id,
    grade,
    weight_kg,
    unit_rate,
    total_value,
    delivered_on,
    is_paid
FROM deliveries
WHERE farmer_id = 1
AND delivered_on BETWEEN '2026-01-01' AND '2026-01-31'
ORDER BY delivered_on;


-- EXPLAIN QUERY PLAN

EXPLAIN
SELECT
    delivery_id,
    farmer_id,
    grade,
    weight_kg,
    unit_rate,
    total_value,
    delivered_on,
    is_paid
FROM deliveries
WHERE farmer_id = 1
AND delivered_on BETWEEN '2026-01-01' AND '2026-01-31'
ORDER BY delivered_on;


-- =========================
-- (g) PROCEDURE: REFRESH DAILY PURCHASES
-- =========================

CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_weight NUMERIC(12,2);
    v_total_value NUMERIC(12,2);
BEGIN
    -- Calculate total purchased weight and value for the specified day
    SELECT
        COALESCE(SUM(weight_kg), 0),
        COALESCE(SUM(total_value), 0)
    INTO
        v_total_weight,
        v_total_value
    FROM deliveries
    WHERE delivered_on = p_day;

    -- Insert the daily totals or replace them if the date already exists
    INSERT INTO daily_purchases (
        purchase_date,
        total_weight,
        total_value
    )
    VALUES (
        p_day,
        v_total_weight,
        v_total_value
    )
    ON CONFLICT (purchase_date)
    DO UPDATE SET
        total_weight = EXCLUDED.total_weight,
        total_value = EXCLUDED.total_value;
END;
$$;


-- TEST THE PROCEDURE

CALL pr_refresh_purchases('2026-01-05');

SELECT * FROM daily_purchases;


-- =========================
-- SCHEDULE DAILY JOB AT 01:30
-- FOR THE PREVIOUS DAY
-- =========================

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_daily_maize_purchases',
    '30 1 * * *',
    $$CALL pr_refresh_purchases(CURRENT_DATE - 1);$$
);


-- =========================================================
-- END OF QUESTION 9
-- =========================================================