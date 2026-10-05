CREATE TABLE employees (
    employee_id SERIAL PRIMARY KEY,
    employee_name VARCHAR(50),
    department VARCHAR(50)
);

CREATE TABLE leave_requests (
    request_id SERIAL PRIMARY KEY,
    employee_id INT REFERENCES employees(employee_id),
    leave_type VARCHAR(20),
    days_requested INT,
    status VARCHAR(20)
);

INSERT INTO employees(employee_name, department) VALUES
('John Banda', 'IT'),
('Mary Zulu', 'HR'),
('Peter Mwansa', 'Finance');

DO $$
DECLARE
    v_name VARCHAR(50);
    v_days INT;
BEGIN
    FOR v_name, v_days IN
        SELECT e.employee_name, l.days_requested
        FROM employees e
        JOIN leave_requests l ON e.employee_id = l.employee_id
    LOOP
        IF v_days <= 5 THEN
            RAISE NOTICE 'Employee "%" requested % days → Short Leave', v_name, v_days;
        ELSIF v_days <= 10 THEN
            RAISE NOTICE 'Employee "%" requested % days → Medium Leave', v_name, v_days;
        ELSE
            RAISE NOTICE 'Employee "%" requested % days → Long Leave', v_name, v_days;
        END IF;
    END LOOP;
END;
$$;


DO $$
DECLARE
    v_counter INT := 1;
BEGIN
    WHILE v_counter <= 3 LOOP
        RAISE NOTICE 'Leave submission reminder %', v_counter;
        v_counter := v_counter + 1;
    END LOOP;

    FOR i IN 1..3 LOOP
        RAISE NOTICE 'Leave check %', i;
    END LOOP;
END;
$$;


CREATE OR REPLACE PROCEDURE submit_leave(
    p_employee_id INT,
    p_leave_type VARCHAR,
    p_days_requested INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_days_requested <= 0 THEN
        RAISE EXCEPTION 'Invalid number of days: %', p_days_requested;
    END IF;

    INSERT INTO leave_requests(employee_id, leave_type, days_requested, status)
    VALUES (p_employee_id, p_leave_type, p_days_requested, 'Pending');

    RAISE NOTICE 'Leave request submitted successfully for employee %', p_employee_id;
END;
$$;



CALL submit_leave(1, 'Annual', 4);
CALL submit_leave(2, 'Sick', 9);
CALL submit_leave(3, 'Maternity', 15);

SELECT * FROM employees;
SELECT * FROM leave_requests;

CREATE OR REPLACE PROCEDURE approve_leave(
    p_request_id INT,
    p_new_status VARCHAR
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_new_status NOT IN ('Approved', 'Rejected') THEN
        RAISE EXCEPTION 'Invalid status: %', p_new_status;
    END IF;

    UPDATE leave_requests
    SET status = p_new_status
    WHERE request_id = p_request_id;

    RAISE NOTICE 'Leave request % updated to %', p_request_id, p_new_status;
END;
$$;

DO $$
DECLARE
    cur_approved CURSOR FOR
        SELECT e.employee_name, l.leave_type, l.days_requested
        FROM employees e
        JOIN leave_requests l ON e.employee_id = l.employee_id
        WHERE l.status = 'Approved';
    v_name VARCHAR(50);
    v_type VARCHAR(20);
    v_days INT;
BEGIN
    OPEN cur_approved;
    LOOP
        FETCH cur_approved INTO v_name, v_type, v_days;
        EXIT WHEN NOT FOUND;
        RAISE NOTICE 'Employee "%" approved for % leave (% days)', v_name, v_type, v_days;
    END LOOP;
    CLOSE cur_approved;
END;
$$;

DO $$
BEGIN
    BEGIN
        CALL submit_leave(2, 'Annual', -3);
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE 'Error: %', SQLERRM;
    END;
END;
$$;

SELECT * FROM employees;
SELECT * FROM leave_requests;


