DROP SCHEMA IF EXISTS q5 CASCADE;
CREATE SCHEMA q5;
SET search_path TO q5;

-- (a) Database and seed data
CREATE TABLE students (
  student_id     SERIAL PRIMARY KEY,
  student_number VARCHAR(20)  NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
  room_id     SERIAL PRIMARY KEY,
  room_number VARCHAR(10) NOT NULL UNIQUE,
  capacity    INTEGER     NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
  allocation_id SERIAL PRIMARY KEY,
  student_id    INTEGER     NOT NULL REFERENCES students(student_id),
  room_id       INTEGER     NOT NULL REFERENCES rooms(room_id),
  allocated_on  DATE        NOT NULL,
  released_on   DATE,
  status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
  CONSTRAINT ck_status_release CHECK (
    (status = 'ACTIVE' AND released_on IS NULL)
    OR
    (status = 'ENDED' AND released_on IS NOT NULL AND released_on >= allocated_on)
  )
);

CREATE TABLE occupancy_snapshot (
  snapshot_date DATE    NOT NULL,
  room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
  occupied_beds INTEGER NOT NULL,
  free_beds     INTEGER NOT NULL,
  PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
  ('S2026001', 'Chanda Mwila'),
  ('S2026002', 'Mutale Banda'),
  ('S2026003', 'Tembo Phiri'),
  ('S2026004', 'Bwalya Zulu'),
  ('S2026005', 'Namwali Daka'),
  ('S2026006', 'Kabwe Lungu');

INSERT INTO rooms (room_number, capacity) VALUES
  ('R101', 2),
  ('R102', 3),
  ('R103', 2);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
  v_capacity INTEGER;
  v_active   INTEGER;
BEGIN
  SELECT capacity INTO v_capacity
  FROM rooms
  WHERE room_id = p_room_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown room_id %', p_room_id;
  END IF;

  SELECT COUNT(*)::INTEGER INTO v_active
  FROM allocations
  WHERE room_id = p_room_id
    AND status = 'ACTIVE';

  RETURN v_capacity - v_active;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INTEGER, p_room_id INTEGER, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_allocated_on IS NULL THEN
    RAISE EXCEPTION 'Allocation date is required';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
    RAISE EXCEPTION 'Unknown student_id %', p_student_id;
  END IF;

  PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown room_id %', p_room_id;
  END IF;

  IF EXISTS (
    SELECT 1 FROM allocations
    WHERE student_id = p_student_id AND status = 'ACTIVE'
  ) THEN
    RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
  END IF;

  IF fn_free_beds(p_room_id) <= 0 THEN
    RAISE EXCEPTION 'Room % is full', p_room_id;
  END IF;

  INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
  VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_allocation_rules()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
  v_capacity INTEGER;
  v_others   INTEGER;
BEGIN
  IF NEW.status = 'ACTIVE' THEN
    SELECT capacity INTO v_capacity
    FROM rooms
    WHERE room_id = NEW.room_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Unknown room_id %', NEW.room_id;
    END IF;

    IF EXISTS (
      SELECT 1 FROM allocations
      WHERE student_id = NEW.student_id
        AND status = 'ACTIVE'
        AND allocation_id IS DISTINCT FROM NEW.allocation_id
    ) THEN
      RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;

    SELECT COUNT(*) INTO v_others
    FROM allocations
    WHERE room_id = NEW.room_id
      AND status = 'ACTIVE'
      AND allocation_id IS DISTINCT FROM NEW.allocation_id;

    IF v_others >= v_capacity THEN
      RAISE EXCEPTION 'Room % is at capacity (%)', NEW.room_id, v_capacity;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocation_rules();

-- (a) continued: full, partly occupied and empty rooms
CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 25);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 20);

INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
  (4, 2, CURRENT_DATE - 90,  CURRENT_DATE - 40, 'ENDED'),
  (5, 1, CURRENT_DATE - 120, CURRENT_DATE - 60, 'ENDED');

-- (b) and (c) tests
SELECT fn_free_beds(1) AS r101, fn_free_beds(2) AS r102, fn_free_beds(3) AS r103;

DO $$
BEGIN
  BEGIN CALL pr_allocate_room(6, 1, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END;
  BEGIN CALL pr_allocate_room(1, 3, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END;
  BEGIN CALL pr_allocate_room(99, 3, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END;
  BEGIN CALL pr_allocate_room(6, 99, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END;
END $$;

-- (d) tests
DO $$
BEGIN
  BEGIN
    INSERT INTO allocations (student_id, room_id, allocated_on, status)
    VALUES (6, 1, CURRENT_DATE, 'ACTIVE');
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected direct insert: %', SQLERRM; END;

  BEGIN
    UPDATE allocations SET status = 'ACTIVE', released_on = NULL WHERE student_id = 5;
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected direct update: %', SQLERRM; END;
END $$;

UPDATE allocations SET allocated_on = allocated_on WHERE student_id = 1;

-- (e) View
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)::INTEGER                AS occupied_beds,
       (r.capacity - COUNT(a.allocation_id))::INTEGER AS free_beds
FROM rooms r
LEFT JOIN allocations a
  ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_id;

-- (f) Index
CREATE INDEX idx_allocations_active_room
ON allocations (room_id)
WHERE status = 'ACTIVE';

ANALYZE allocations;
SET enable_seqscan = off;
EXPLAIN
SELECT *
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';
RESET enable_seqscan;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
  SELECT CURRENT_DATE,
         r.room_id,
         COUNT(a.allocation_id)::INTEGER,
         (r.capacity - COUNT(a.allocation_id))::INTEGER
  FROM rooms r
  LEFT JOIN allocations a
    ON a.room_id = r.room_id AND a.status = 'ACTIVE'
  GROUP BY r.room_id, r.capacity
  ON CONFLICT (snapshot_date, room_id) DO UPDATE
  SET occupied_beds = EXCLUDED.occupied_beds,
      free_beds     = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot ORDER BY room_id;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
  'q5_refresh_occupancy',
  '55 23 * * *',
  $$CALL q5.pr_refresh_occupancy()$$
);