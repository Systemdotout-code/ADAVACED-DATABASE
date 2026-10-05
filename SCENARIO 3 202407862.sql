CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_name VARCHAR(50)
);

CREATE TABLE grades (
    grade_id SERIAL PRIMARY KEY,
    student_id INT REFERENCES students(student_id),
    course VARCHAR(50),
    score INT,
    status VARCHAR(20)
);

INSERT INTO students(student_name) VALUES
('Alice'),
('Brian'),
('Chipo');


DO $$
DECLARE
    v_name VARCHAR(50);
    v_score INT;
BEGIN
    FOR v_name, v_score IN
        SELECT student_name, score FROM students s
        JOIN grades g ON s.student_id = g.student_id
    LOOP
        IF v_score < 50 THEN
            RAISE NOTICE 'Student "%" scored % → Fail', v_name, v_score;
        ELSIF v_score < 75 THEN
            RAISE NOTICE 'Student "%" scored % → Pass', v_name, v_score;
        ELSE
            RAISE NOTICE 'Student "%" scored % → Distinction', v_name, v_score;
        END IF;
    END LOOP;
END;
$$;

DO $$
DECLARE
    v_counter INT := 1;
BEGIN
    WHILE v_counter <= 3 LOOP
        RAISE NOTICE 'Grade submission reminder %', v_counter;
        v_counter := v_counter + 1;
    END LOOP;

    FOR i IN 1..3 LOOP
        RAISE NOTICE 'Score check %', i;
    END LOOP;
END;
$$;

CREATE OR REPLACE PROCEDURE record_grade(
    p_student_id INT,
    p_course VARCHAR,
    p_score INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_score < 0 OR p_score > 100 THEN
        RAISE EXCEPTION 'Invalid score: %', p_score;
    END IF;

    INSERT INTO grades(student_id, course, score, status)
    VALUES (p_student_id, p_course, p_score,
        CASE
            WHEN p_score < 50 THEN 'Fail'
            WHEN p_score < 75 THEN 'Pass'
            ELSE 'Distinction'
        END);
    
    RAISE NOTICE 'Grade recorded successfully for student %', p_student_id;
END;
$$;

CALL record_grade(1, 'Database Systems', 45);
CALL record_grade(2, 'Networking', 68);
CALL record_grade(3, 'Operating Systems', 82);

SELECT * FROM students;
SELECT * FROM grades;

CREATE OR REPLACE PROCEDURE update_grade(
    p_grade_id INT,
    p_new_score INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_new_score < 0 OR p_new_score > 100 THEN
        RAISE EXCEPTION 'Invalid score: %', p_new_score;
    END IF;

    UPDATE grades
    SET score = p_new_score,
        status = CASE
                    WHEN p_new_score < 50 THEN 'Fail'
                    WHEN p_new_score < 75 THEN 'Pass'
                    ELSE 'Distinction'
                 END
    WHERE grade_id = p_grade_id;

    RAISE NOTICE 'Grade % updated successfully', p_grade_id;
END;
$$;


DO $$
DECLARE
    cur_distinction CURSOR FOR
        SELECT student_name, course, score FROM students s
        JOIN grades g ON s.student_id = g.student_id
        WHERE g.status = 'Distinction';
    v_name VARCHAR(50);
    v_course VARCHAR(50);
    v_score INT;
BEGIN
    OPEN cur_distinction;
    LOOP
        FETCH cur_distinction INTO v_name, v_course, v_score;
        EXIT WHEN NOT FOUND;
        RAISE NOTICE 'Student "%" achieved Distinction in % with score %', v_name, v_course, v_score;
    END LOOP;
    CLOSE cur_distinction;
END;
$$;


DO $$
BEGIN
    BEGIN
        CALL record_grade(1, 'Software Engineering', 120);
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE 'Error: %', SQLERRM;
    END;
END;
$$;

SELECT * FROM students;
SELECT * FROM grades;
