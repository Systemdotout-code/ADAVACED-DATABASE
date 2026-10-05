CREATE TABLE lab_sessions (
    session_id SERIAL PRIMARY KEY,
    session_name VARCHAR(50),
    available_workstations INT
);

CREATE TABLE reservations (
    reservation_id SERIAL PRIMARY KEY,
    lecturer VARCHAR(50),
    session_id INT REFERENCES lab_sessions(session_id),
    workstations INT,
    status VARCHAR(20)
);

INSERT INTO lab_sessions(session_name, available_workstations) VALUES
('Database Practical', 10),
('Networking Practical', 8),
('Operating Systems Practical', 5);


DO $$
DECLARE
    v_name VARCHAR(50);
    v_workstations INT;
BEGIN
    FOR v_name, v_workstations IN
        SELECT session_name, available_workstations FROM lab_sessions
    LOOP
        IF v_workstations = 0 THEN
            RAISE NOTICE 'Session "%" is full', v_name;
        ELSIF v_workstations <= 2 THEN
            RAISE NOTICE 'Session "%" is nearly full', v_name;
        ELSE
            RAISE NOTICE 'Session "%" has enough workstations (% available)', v_name, v_workstations;
        END IF;
    END LOOP;
END;
$$;



DO $$
DECLARE
    v_counter INT := 1;
BEGIN
    WHILE v_counter <= 3 LOOP
        RAISE NOTICE 'Session preparation reminder %', v_counter;
        v_counter := v_counter + 1;
    END LOOP;

    FOR i IN 1..3 LOOP
        RAISE NOTICE 'Workstation check %', i;
    END LOOP;
END;
$$;


CREATE OR REPLACE PROCEDURE reserve_workstations(
    p_lecturer VARCHAR,
    p_session_id INT,
    p_qty INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_qty <= 0 THEN
        RAISE EXCEPTION 'Invalid workstation request: %', p_qty;
    END IF;

    IF (SELECT available_workstations FROM lab_sessions WHERE session_id = p_session_id) >= p_qty THEN
        UPDATE lab_sessions
        SET available_workstations = available_workstations - p_qty
        WHERE session_id = p_session_id;

        INSERT INTO reservations(lecturer, session_id, workstations, status)
        VALUES (p_lecturer, p_session_id, p_qty, 'Reserved');

        RAISE NOTICE 'Reservation recorded successfully for lecturer %', p_lecturer;
    ELSE
        RAISE NOTICE 'Not enough workstations available for session %', p_session_id;
    END IF;
END;
$$;



INSERT INTO lab_sessions(session_name, available_workstations) VALUES
('Database Practical', 10),
('Networking Practical', 8),
('Operating Systems Practical', 5);

CALL reserve_workstations('Dr. Banda', 1, 4);
CALL reserve_workstations('Prof. Mwansa', 2, 6);
CALL reserve_workstations('Dr. Zulu', 3, 10);

SELECT * FROM lab_sessions;
SELECT * FROM reservations;




CREATE OR REPLACE PROCEDURE cancel_reservation(
    p_reservation_id INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF (SELECT status FROM reservations WHERE reservation_id = p_reservation_id) = 'Reserved' THEN
        UPDATE reservations
        SET status = 'Cancelled'
        WHERE reservation_id = p_reservation_id;

        UPDATE lab_sessions
        SET available_workstations = available_workstations + (SELECT workstations FROM reservations WHERE reservation_id = p_reservation_id)
        WHERE session_id = (SELECT session_id FROM reservations WHERE reservation_id = p_reservation_id);

        RAISE NOTICE 'Reservation % cancelled successfully', p_reservation_id;
    ELSE
        RAISE NOTICE 'Reservation % already cancelled or invalid', p_reservation_id;
    END IF;
END;
$$;



DO $$
DECLARE
    cur_sessions CURSOR FOR
        SELECT session_name, available_workstations FROM lab_sessions WHERE available_workstations <= 2;
    v_name VARCHAR(50);
    v_workstations INT;
BEGIN
    OPEN cur_sessions;
    LOOP
        FETCH cur_sessions INTO v_name, v_workstations;
        EXIT WHEN NOT FOUND;
        RAISE NOTICE 'Session "%" has % workstations remaining', v_name, v_workstations;
    END LOOP;
    CLOSE cur_sessions;
END;
$$;

DO $$
BEGIN
    BEGIN
        CALL reserve_workstations('Dr. Phiri', 1, 0);
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE 'Error: %', SQLERRM;
    END;
END;
$$;

SELECT * FROM lab_sessions;
SELECT * FROM reservations;


