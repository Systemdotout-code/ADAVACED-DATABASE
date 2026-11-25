-- =========================================================
-- ICT371 ADVANCED DATABASE
-- QUESTION 8: TRANSPORT FLEET MAINTENANCE
-- =========================================================


-- =========================
-- (a) CREATE TABLES
-- =========================

CREATE TABLE vehicles (
    vehicle_id SERIAL PRIMARY KEY,
    registration VARCHAR(20) UNIQUE NOT NULL,
    current_odometer NUMERIC(10,2) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(10,2) NOT NULL CHECK (last_service_odometer >= 0),
    CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id SERIAL PRIMARY KEY,
    vehicle_id INT NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on DATE NOT NULL,
    start_odometer NUMERIC(10,2) NOT NULL CHECK (start_odometer >= 0),
    end_odometer NUMERIC(10,2) NOT NULL CHECK (end_odometer >= 0),
    CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(10,2) NOT NULL CHECK (km_since_service >= 0),
    flagged_on DATE NOT NULL
);


-- =========================
-- INSERT SEED DATA
-- =========================

INSERT INTO vehicles (registration, current_odometer, last_service_odometer)
VALUES
('ABC-123', 15000, 10000),
('DEF-456', 28000, 25000),
('GHI-789', 50000, 42000);


-- =========================
-- (b) FUNCTION: SERVICE DUE
-- =========================

CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_current NUMERIC(10,2);
    v_last_service NUMERIC(10,2);
BEGIN
    SELECT current_odometer, last_service_odometer
    INTO v_current, v_last_service
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle ID % does not exist', p_vehicle_id;
    END IF;

    RETURN (v_current - v_last_service) >= 5000;
END;
$$;


-- TEST THE FUNCTION

SELECT fn_service_due(1);
SELECT fn_service_due(2);
SELECT fn_service_due(3);


-- =========================
-- (c) PROCEDURE: RECORD TRIP
-- =========================

CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INT,
    p_trip_on DATE,
    p_start NUMERIC,
    p_end NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Check if vehicle exists
    IF NOT EXISTS (
        SELECT 1
        FROM vehicles
        WHERE vehicle_id = p_vehicle_id
    ) THEN
        RAISE EXCEPTION 'Vehicle ID % does not exist', p_vehicle_id;
    END IF;

    -- Validate trip mileage
    IF p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Odometer values cannot be NULL';
    END IF;

    IF p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer must be greater than start odometer';
    END IF;

    -- Insert trip
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);

    RAISE NOTICE 'Trip recorded successfully';
END;
$$;


-- =========================
-- (d) TRIGGER: VALIDATE AND UPDATE ODOMETER
-- =========================

CREATE OR REPLACE FUNCTION fn_trip_odometer_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current NUMERIC(10,2);
BEGIN
    -- Get the vehicle's current odometer
    SELECT current_odometer
    INTO v_current
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle ID % does not exist', NEW.vehicle_id;
    END IF;

    -- Start must match current odometer
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION
        'Trip start (%) must match vehicle current odometer (%)',
        NEW.start_odometer, v_current;
    END IF;

    -- Validate mileage
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'End odometer must be greater than start odometer';
    END IF;

    -- Update vehicle odometer to trip end
    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION fn_trip_odometer_trigger();


-- =========================
-- INSERT SIX TRIPS USING PROCEDURE
-- =========================

CALL pr_record_trip(1, '2026-01-10', 15000, 16000);
CALL pr_record_trip(1, '2026-01-11', 16000, 17000);

CALL pr_record_trip(2, '2026-01-10', 28000, 29000);
CALL pr_record_trip(2, '2026-01-11', 29000, 31000);

CALL pr_record_trip(3, '2026-01-10', 50000, 52000);
CALL pr_record_trip(3, '2026-01-11', 52000, 55000);


-- =========================
-- (e) VIEW: SERVICE DUE VEHICLES
-- =========================

CREATE OR REPLACE VIEW v_service_due AS
SELECT
    registration,
    (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE (current_odometer - last_service_odometer) >= 5000;


-- VIEW SERVICE-DUE VEHICLES

SELECT * FROM v_service_due;


-- =========================
-- (f) INDEX: VEHICLE TRIPS BY DATE
-- =========================

CREATE INDEX idx_trips_vehicle_trip_on
ON trips(vehicle_id, trip_on);


-- QUERY: FIND TRIPS FOR ONE VEHICLE WITHIN A DATE RANGE

SELECT
    trip_id,
    vehicle_id,
    trip_on,
    start_odometer,
    end_odometer
FROM trips
WHERE vehicle_id = 1
AND trip_on BETWEEN '2026-01-01' AND '2026-01-31'
ORDER BY trip_on;


-- EXPLAIN QUERY PLAN

EXPLAIN
SELECT
    trip_id,
    vehicle_id,
    trip_on,
    start_odometer,
    end_odometer
FROM trips
WHERE vehicle_id = 1
AND trip_on BETWEEN '2026-01-01' AND '2026-01-31'
ORDER BY trip_on;


-- =========================
-- (g) PROCEDURE: REFRESH SERVICE ALERTS
-- =========================

CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    -- Insert or update alerts for vehicles that are due
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT
        vehicle_id,
        (current_odometer - last_service_odometer),
        CURRENT_DATE
    FROM vehicles
    WHERE (current_odometer - last_service_odometer) >= 5000

    ON CONFLICT (vehicle_id)
    DO UPDATE SET
        km_since_service = EXCLUDED.km_since_service,
        flagged_on = EXCLUDED.flagged_on;

    -- Remove alerts for vehicles no longer due
    DELETE FROM service_alerts
    WHERE vehicle_id IN (
        SELECT vehicle_id
        FROM vehicles
        WHERE (current_odometer - last_service_odometer) < 5000
    );
END;
$$;


-- TEST THE PROCEDURE MANUALLY

CALL pr_refresh_service_alerts();

SELECT * FROM service_alerts;


-- =========================
-- SCHEDULE JOB EVERY MONDAY AT 06:00
-- =========================

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_service_alerts_weekly',
    '0 6 * * 1',
    'CALL pr_refresh_service_alerts();'
);


-- =========================================================
-- END OF QUESTION 8
-- =========================================================