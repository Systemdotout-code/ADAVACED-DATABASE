-- =========================================================
-- ICT371 ADVANCED DATABASE
-- QUESTION 10: SCHOLARSHIP APPLICATION ASSESSMENT
-- =========================================================


-- =========================
-- (a) CREATE TABLES
-- =========================

CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    age_at_application INT NOT NULL CHECK (age_at_application > 0),
    monthly_income NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on DATE NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id SERIAL PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status VARCHAR(20),
    new_status VARCHAR(20),
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- =========================
-- INSERT SEED DATA
-- =========================

INSERT INTO students (student_number, full_name)
VALUES
('ST001', 'John Banda'),
('ST002', 'Mary Phiri'),
('ST003', 'Peter Zulu');


-- SIX PENDING APPLICATIONS
-- Including qualifying, non-qualifying and boundary cases

INSERT INTO applications
(student_id, age_at_application, monthly_income,
 average_mark, submitted_on, status)
VALUES
-- Qualifying applications
(1, 20, 2000, 85, '2026-01-05', 'PENDING'),
(1, 22, 2500, 75, '2026-01-06', 'PENDING'),

-- Non-qualifying applications
(2, 26, 2000, 80, '2026-01-07', 'PENDING'),
(2, 21, 3500, 90, '2026-01-08', 'PENDING'),
(3, 23, 2000, 60, '2026-01-09', 'PENDING'),

-- Boundary case: age 18, income 3000, mark 70
(3, 18, 3000, 70, '2026-01-10', 'PENDING');


-- =========================
-- (b) SCHOLARSHIP ELIGIBILITY FUNCTION
-- =========================

CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age INT,
    p_income NUMERIC,
    p_mark NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN

    -- Reject NULL values
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Inputs cannot be NULL';
    END IF;

    -- Validate age
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive';
    END IF;

    -- Validate income
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative';
    END IF;

    -- Validate marks
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Marks must be between 0 and 100';
    END IF;

    -- Check scholarship eligibility
    RETURN (
        p_age BETWEEN 18 AND 25
        AND p_income <= 3000
        AND p_mark >= 70
    );

END;
$$;


-- TEST FUNCTION

SELECT fn_scholarship_eligible(20, 2000, 85);
SELECT fn_scholarship_eligible(26, 2000, 80);
SELECT fn_scholarship_eligible(18, 3000, 70);


-- =========================
-- (c) ASSESS APPLICATION PROCEDURE
-- =========================

CREATE OR REPLACE PROCEDURE pr_assess_application(
    p_application_id INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age INT;
    v_income NUMERIC(10,2);
    v_mark NUMERIC(5,2);
    v_eligible BOOLEAN;
    v_status VARCHAR(20);

BEGIN

    -- Find application
    SELECT age_at_application,
           monthly_income,
           average_mark,
           status
    INTO v_age, v_income, v_mark, v_status
    FROM applications
    WHERE application_id = p_application_id;

    -- Check application exists
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application ID % does not exist',
        p_application_id;
    END IF;

    -- Check application is still pending
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed',
        p_application_id;
    END IF;

    -- Call eligibility function
    v_eligible := fn_scholarship_eligible(
        v_age,
        v_income,
        v_mark
    );

    -- Update application status
    IF v_eligible THEN

        UPDATE applications
        SET status = 'APPROVED'
        WHERE application_id = p_application_id;

    ELSE

        UPDATE applications
        SET status = 'REJECTED'
        WHERE application_id = p_application_id;

    END IF;

    RAISE NOTICE 'Application % assessed successfully',
    p_application_id;

END;
$$;


-- ASSESS SIX APPLICATIONS

CALL pr_assess_application(1);
CALL pr_assess_application(2);
CALL pr_assess_application(3);
CALL pr_assess_application(4);
CALL pr_assess_application(5);
CALL pr_assess_application(6);


-- CHECK APPLICATION RESULTS

SELECT * FROM applications;


-- =========================
-- (d) AFTER UPDATE AUDIT TRIGGER
-- =========================

CREATE OR REPLACE FUNCTION fn_application_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    -- Record only actual status changes
    IF OLD.status IS DISTINCT FROM NEW.status THEN

        INSERT INTO decision_audit (
            application_id,
            old_status,
            new_status,
            changed_at
        )
        VALUES (
            NEW.application_id,
            OLD.status,
            NEW.status,
            CURRENT_TIMESTAMP
        );

    END IF;

    RETURN NEW;

END;
$$;


CREATE TRIGGER trg_application_audit
AFTER UPDATE ON applications
FOR EACH ROW
EXECUTE FUNCTION fn_application_audit();


-- CHECK AUDIT RECORDS

SELECT * FROM decision_audit;


-- =========================
-- (e) APPROVED APPLICANTS VIEW
-- =========================

CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM students s
JOIN applications a
    ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';


-- VIEW APPROVED APPLICANTS

SELECT * FROM v_approved_applicants;


-- =========================
-- (f) CREATE COMPOSITE INDEX
-- =========================

CREATE INDEX idx_applications_status_date
ON applications(status, submitted_on);


-- QUERY: SEARCH APPLICATIONS BY STATUS AND DATE RANGE

SELECT
    application_id,
    student_id,
    age_at_application,
    average_mark,
    submitted_on,
    status
FROM applications
WHERE status = 'PENDING'
AND submitted_on BETWEEN '2026-01-01' AND '2026-01-31'
ORDER BY submitted_on;


-- EXPLAIN QUERY PLAN

EXPLAIN
SELECT
    application_id,
    student_id,
    age_at_application,
    average_mark,
    submitted_on,
    status
FROM applications
WHERE status = 'PENDING'
AND submitted_on BETWEEN '2026-01-01' AND '2026-01-31'
ORDER BY submitted_on;


-- =========================
-- (g) ASSESS ALL PENDING APPLICATIONS
-- =========================

CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    v_application RECORD;

BEGIN

    -- Loop through pending applications only
    FOR v_application IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
    LOOP

        -- Assess each pending application
        CALL pr_assess_application(
            v_application.application_id
        );

    END LOOP;

    RAISE NOTICE 'All pending applications have been assessed';

END;
$$;


-- TEST THE PROCEDURE

CALL pr_assess_pending();


-- CHECK FINAL APPLICATION STATUSES

SELECT * FROM applications;


-- CHECK AUDIT HISTORY

SELECT * FROM decision_audit;


-- =========================
-- SCHEDULE JOB EVERY MONDAY AT 08:00
-- =========================

CREATE EXTENSION IF NOT EXISTS pg_cron;


SELECT cron.schedule(
    'assess_pending_scholarships',
    '0 8 * * 1',
    'CALL pr_assess_pending();'
);


-- =========================================================
-- END OF QUESTION 10
-- =========================================================