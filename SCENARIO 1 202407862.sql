
CREATE TABLE books (
  book_id SERIAL PRIMARY KEY,
  title VARCHAR(100),
  available_copies INT
);

CREATE TABLE book_loans (
  loan_id SERIAL PRIMARY KEY,
  student_no VARCHAR(20),
  book_id INT REFERENCES books(book_id),
  quantity INT,
  status VARCHAR(20)
);

CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title VARCHAR(100),
    available_copies INT
);

CREATE TABLE book_loans (
    loan_id SERIAL PRIMARY KEY,
    student_no VARCHAR(20),
    book_id INT REFERENCES books(book_id),
    quantity INT,
    status VARCHAR(20)
);

INSERT INTO books(title, available_copies) VALUES
('Database Systems', 3),
('Operating Systems', 2),
('Computer Networks', 1);

DO $$
DECLARE
    v_title VARCHAR(100);
    v_copies INT;
BEGIN
    FOR v_title, v_copies IN
        SELECT title, available_copies FROM books
    LOOP
        IF v_copies = 0 THEN
            RAISE NOTICE 'Book "%" is unavailable', v_title;
        ELSIF v_copies = 1 THEN
            RAISE NOTICE 'Book "%" is low on copies', v_title;
        ELSE
            RAISE NOTICE 'Book "%" is sufficiently stocked (% copies)', v_title, v_copies;
        END IF;
    END LOOP;
END;
$$;


DO $$
DECLARE
    v_counter INT := 1;
BEGIN
    -- WHILE loop for overdue reminders
    WHILE v_counter <= 3 LOOP
        RAISE NOTICE 'Overdue reminder %', v_counter;
        v_counter := v_counter + 1;
    END LOOP;

    -- Numeric FOR loop for shelf numbers
    FOR i IN 1..3 LOOP
        RAISE NOTICE 'Library shelf number %', i;
    END LOOP;
END;
$$;

CREATE OR REPLACE PROCEDURE borrow_book(
    p_student_no VARCHAR,
    p_book_id INT,
    p_quantity INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;

    IF (SELECT available_copies FROM books WHERE book_id = p_book_id) >= p_quantity THEN
        UPDATE books
        SET available_copies = available_copies - p_quantity
        WHERE book_id = p_book_id;

        INSERT INTO book_loans(student_no, book_id, quantity, status)
        VALUES (p_student_no, p_book_id, p_quantity, 'Borrowed');

        RAISE NOTICE 'Loan recorded successfully for student %', p_student_no;
    ELSE
        RAISE NOTICE 'Not enough copies available for book_id %', p_book_id;
    END IF;
END;
$$;


INSERT INTO books(title, available_copies) VALUES
('Database Systems', 3),
('Operating Systems', 2),
('Computer Networks', 1);

CALL borrow_book('STU001', 1, 1);
CALL borrow_book('STU002', 2, 2);
CALL borrow_book('STU003', 3, 5);

SELECT * FROM books;
SELECT * FROM book_loans;


CREATE OR REPLACE PROCEDURE return_book(
    p_loan_id INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF (SELECT status FROM book_loans WHERE loan_id = p_loan_id) = 'Borrowed' THEN
        UPDATE book_loans
        SET status = 'Returned'
        WHERE loan_id = p_loan_id;

        UPDATE books
        SET available_copies = available_copies + (SELECT quantity FROM book_loans WHERE loan_id = p_loan_id)
        WHERE book_id = (SELECT book_id FROM book_loans WHERE loan_id = p_loan_id);

        RAISE NOTICE 'Loan % returned successfully', p_loan_id;
    ELSE
        RAISE NOTICE 'Loan % already returned or invalid', p_loan_id;
    END IF;
END;
$$;

DO $$
DECLARE
    cur_books CURSOR FOR
        SELECT title, available_copies FROM books WHERE available_copies <= 1;
    v_title VARCHAR(100);
    v_copies INT;
BEGIN
    OPEN cur_books;
    LOOP
        FETCH cur_books INTO v_title, v_copies;
        EXIT WHEN NOT FOUND;
        RAISE NOTICE 'Book "%" has % copies remaining', v_title, v_copies;
    END LOOP;
    CLOSE cur_books;
END;
$$;

DO $$
BEGIN
    BEGIN
        CALL borrow_book('STU004', 1, 0);
    EXCEPTION
        WHEN OTHERS THEN
            RAISE NOTICE 'Error: %', SQLERRM;
    END;
END;
$$;

SELECT * FROM books;
SELECT * FROM book_loans;

