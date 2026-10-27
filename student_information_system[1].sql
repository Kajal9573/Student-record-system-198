SET SERVEROUTPUT ON SIZE UNLIMITED
BEGIN
  FOR t IN (SELECT table_name FROM user_tables
            WHERE table_name IN ('AUDIT_LOG','MARKS','ENROLLMENTS','COURSES','STUDENTS','DEPARTMENTS')) LOOP
    EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS';
  END LOOP;
  FOR s IN (SELECT sequence_name FROM user_sequences
            WHERE sequence_name IN ('SEQ_DEPT','SEQ_STUDENT','SEQ_COURSE','SEQ_ENROLL','SEQ_AUDIT')) LOOP
    EXECUTE IMMEDIATE 'DROP SEQUENCE ' || s.sequence_name;
  END LOOP;
END;
/
CREATE SEQUENCE seq_dept    START WITH 10   INCREMENT BY 10;
CREATE SEQUENCE seq_student START WITH 1001 INCREMENT BY 1;
CREATE SEQUENCE seq_course  START WITH 501  INCREMENT BY 1;
CREATE SEQUENCE seq_enroll  START WITH 1    INCREMENT BY 1;
CREATE SEQUENCE seq_audit   START WITH 1    INCREMENT BY 1;

CREATE TABLE departments (
  dept_id    NUMBER        PRIMARY KEY,
  dept_name  VARCHAR2(50)  NOT NULL UNIQUE
);

CREATE TABLE students (
  student_id     NUMBER         PRIMARY KEY,
  first_name     VARCHAR2(40)   NOT NULL,
  last_name      VARCHAR2(40)   NOT NULL,
  email          VARCHAR2(100)  NOT NULL UNIQUE,
  dob            DATE           NOT NULL,
  dept_id        NUMBER         NOT NULL REFERENCES departments(dept_id),
  admission_date DATE           DEFAULT SYSDATE,
  status         VARCHAR2(10)   DEFAULT 'ACTIVE'
                 CHECK (status IN ('ACTIVE','INACTIVE','GRADUATED'))
);

CREATE TABLE courses (
  course_id    NUMBER         PRIMARY KEY,
  course_name  VARCHAR2(80)   NOT NULL,
  credits      NUMBER(2)      NOT NULL CHECK (credits BETWEEN 1 AND 6),
  dept_id      NUMBER         NOT NULL REFERENCES departments(dept_id)
);

CREATE TABLE enrollments (
  enroll_id    NUMBER        PRIMARY KEY,
  student_id   NUMBER        NOT NULL REFERENCES students(student_id),
  course_id    NUMBER        NOT NULL REFERENCES courses(course_id),
  semester     NUMBER(1)     NOT NULL CHECK (semester BETWEEN 1 AND 8),
  enrolled_on  DATE          DEFAULT SYSDATE,
  CONSTRAINT uq_enroll UNIQUE (student_id, course_id, semester)
);

CREATE TABLE marks (
  enroll_id       NUMBER PRIMARY KEY REFERENCES enrollments(enroll_id),
  internal_marks  NUMBER(3) NOT NULL CHECK (internal_marks BETWEEN 0 AND 40),
  external_marks  NUMBER(3) NOT NULL CHECK (external_marks BETWEEN 0 AND 60),
  total_marks     NUMBER(3),
  grade           VARCHAR2(2)
);

CREATE TABLE audit_log (
  log_id      NUMBER        PRIMARY KEY,
  table_name  VARCHAR2(30),
  action      VARCHAR2(10),
  record_id   NUMBER,
  details     VARCHAR2(500),
  changed_by  VARCHAR2(50),
  changed_on  TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE OR REPLACE PACKAGE sis_pkg AS
  PROCEDURE add_student   (p_first   IN VARCHAR2,
                           p_last    IN VARCHAR2,
                           p_email   IN VARCHAR2,
                           p_dob     IN DATE,
                           p_dept_id IN NUMBER,
                           p_new_id  OUT NUMBER);

  PROCEDURE enroll_student(p_student_id IN NUMBER,
                           p_course_id  IN NUMBER,
                           p_semester   IN NUMBER,
                           p_enroll_id  OUT NUMBER);

  PROCEDURE record_marks  (p_enroll_id IN NUMBER,
                           p_internal  IN NUMBER,
                           p_external  IN NUMBER);

  PROCEDURE update_status (p_student_id IN NUMBER, p_status IN VARCHAR2);

  FUNCTION  get_grade      (p_total IN NUMBER) RETURN VARCHAR2;
  FUNCTION  get_grade_point(p_grade IN VARCHAR2) RETURN NUMBER;
  FUNCTION  calc_cgpa      (p_student_id IN NUMBER) RETURN NUMBER;

  PROCEDURE print_report_card(p_student_id IN NUMBER);
  PROCEDURE dept_summary;
  PROCEDURE top_students(p_n IN NUMBER DEFAULT 3);
END sis_pkg;
/

CREATE OR REPLACE PACKAGE BODY sis_pkg AS

  PROCEDURE check_student(p_id NUMBER) IS
    v NUMBER;
  BEGIN
    SELECT 1 INTO v FROM students WHERE student_id = p_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20001, 'Student ' || p_id || ' not found');
  END;
  PROCEDURE add_student(p_first IN VARCHAR2, p_last IN VARCHAR2,
                        p_email IN VARCHAR2, p_dob IN DATE,
                        p_dept_id IN NUMBER, p_new_id OUT NUMBER) IS
  BEGIN
    IF p_dob > ADD_MONTHS(SYSDATE, -12*15) THEN
      RAISE_APPLICATION_ERROR(-20002, 'Student must be at least 15 years old');
    END IF;

    p_new_id := seq_student.NEXTVAL;
    INSERT INTO students(student_id, first_name, last_name, email, dob, dept_id)
    VALUES (p_new_id, p_first, p_last, LOWER(p_email), p_dob, p_dept_id);

    INSERT INTO audit_log(log_id, table_name, action, record_id, details, changed_by)
    VALUES (seq_audit.NEXTVAL, 'STUDENTS', 'INSERT', p_new_id,
            'New student ' || p_first || ' ' || p_last, USER);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      RAISE_APPLICATION_ERROR(-20003, 'Email already registered: ' || p_email);
  END add_student;

  PROCEDURE enroll_student(p_student_id IN NUMBER, p_course_id IN NUMBER,
                           p_semester IN NUMBER, p_enroll_id OUT NUMBER) IS
    v_status students.status%TYPE;
    v_dummy  NUMBER;
  BEGIN
    BEGIN
      SELECT status INTO v_status FROM students WHERE student_id = p_student_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20001, 'Student ' || p_student_id || ' not found');
    END;

    IF v_status <> 'ACTIVE' THEN
      RAISE_APPLICATION_ERROR(-20004, 'Only ACTIVE students can enroll');
    END IF;

    BEGIN
      SELECT 1 INTO v_dummy FROM courses WHERE course_id = p_course_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20005, 'Course ' || p_course_id || ' not found');
    END;

    p_enroll_id := seq_enroll.NEXTVAL;
    INSERT INTO enrollments(enroll_id, student_id, course_id, semester)
    VALUES (p_enroll_id, p_student_id, p_course_id, p_semester);
  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      RAISE_APPLICATION_ERROR(-20006, 'Student already enrolled in this course for the semester');
  END enroll_student;
  PROCEDURE record_marks(p_enroll_id IN NUMBER, p_internal IN NUMBER, p_external IN NUMBER) IS
    v_dummy NUMBER;
  BEGIN
    BEGIN
      SELECT 1 INTO v_dummy FROM enrollments WHERE enroll_id = p_enroll_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20007, 'Enrollment ' || p_enroll_id || ' not found');
    END;

    BEGIN
      INSERT INTO marks(enroll_id, internal_marks, external_marks)
      VALUES (p_enroll_id, p_internal, p_external);
    EXCEPTION
      WHEN DUP_VAL_ON_INDEX THEN
        UPDATE marks
           SET internal_marks = p_internal,
               external_marks = p_external
         WHERE enroll_id = p_enroll_id;
    END;
    -- total_marks and grade are filled by trigger trg_marks_calc
  END record_marks;
  PROCEDURE update_status(p_student_id IN NUMBER, p_status IN VARCHAR2) IS
  BEGIN
    check_student(p_student_id);
    UPDATE students SET status = UPPER(p_status) WHERE student_id = p_student_id;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE = -2290 THEN   -- check constraint violated
        RAISE_APPLICATION_ERROR(-20008, 'Invalid status: ' || p_status);
      ELSE
        RAISE;
      END IF;
  END update_status;
  FUNCTION get_grade(p_total IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE
             WHEN p_total >= 90 THEN 'O'
             WHEN p_total >= 80 THEN 'A+'
             WHEN p_total >= 70 THEN 'A'
             WHEN p_total >= 60 THEN 'B+'
             WHEN p_total >= 50 THEN 'B'
             WHEN p_total >= 40 THEN 'C'
             ELSE 'F'
           END;
  END get_grade;

  FUNCTION get_grade_point(p_grade IN VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN CASE p_grade
             WHEN 'O'  THEN 10
             WHEN 'A+' THEN 9
             WHEN 'A'  THEN 8
             WHEN 'B+' THEN 7
             WHEN 'B'  THEN 6
             WHEN 'C'  THEN 5
             ELSE 0
           END;
  END get_grade_point;

  FUNCTION calc_cgpa(p_student_id IN NUMBER) RETURN NUMBER IS
    v_points  NUMBER := 0;
    v_credits NUMBER := 0;
  BEGIN
    FOR r IN (SELECT m.grade, c.credits
                FROM enrollments e
                JOIN marks   m ON m.enroll_id = e.enroll_id
                JOIN courses c ON c.course_id = e.course_id
               WHERE e.student_id = p_student_id) LOOP
      v_points  := v_points  + get_grade_point(r.grade) * r.credits;
      v_credits := v_credits + r.credits;
    END LOOP;

    IF v_credits = 0 THEN
      RETURN NULL;
    END IF;
    RETURN ROUND(v_points / v_credits, 2);
  END calc_cgpa;
  PROCEDURE print_report_card(p_student_id IN NUMBER) IS
    v_name  VARCHAR2(100);
    v_dept  departments.dept_name%TYPE;
    v_cgpa  NUMBER;
    v_count PLS_INTEGER := 0;
  BEGIN
    BEGIN
      SELECT s.first_name || ' ' || s.last_name, d.dept_name
        INTO v_name, v_dept
        FROM students s JOIN departments d ON d.dept_id = s.dept_id
       WHERE s.student_id = p_student_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20001, 'Student ' || p_student_id || ' not found');
    END;

    DBMS_OUTPUT.PUT_LINE(RPAD('=', 64, '='));
    DBMS_OUTPUT.PUT_LINE('REPORT CARD');
    DBMS_OUTPUT.PUT_LINE('Student    : ' || v_name || '  (ID ' || p_student_id || ')');
    DBMS_OUTPUT.PUT_LINE('Department : ' || v_dept);
    DBMS_OUTPUT.PUT_LINE(RPAD('-', 64, '-'));
    DBMS_OUTPUT.PUT_LINE(RPAD('Sem', 5) || RPAD('Course', 30) ||
                         RPAD('Cr', 4) || RPAD('Marks', 7) || 'Grade');
    DBMS_OUTPUT.PUT_LINE(RPAD('-', 64, '-'));

    FOR r IN (SELECT e.semester, c.course_name, c.credits, m.total_marks, m.grade
                FROM enrollments e
                JOIN courses c    ON c.course_id = e.course_id
                LEFT JOIN marks m ON m.enroll_id = e.enroll_id
               WHERE e.student_id = p_student_id
               ORDER BY e.semester, c.course_name) LOOP
      v_count := v_count + 1;
      DBMS_OUTPUT.PUT_LINE(RPAD(r.semester, 5) || RPAD(r.course_name, 30) ||
                           RPAD(r.credits, 4) ||
                           RPAD(NVL(TO_CHAR(r.total_marks), '-'), 7) ||
                           NVL(r.grade, 'N/A'));
    END LOOP;

    IF v_count = 0 THEN
      DBMS_OUTPUT.PUT_LINE('No enrollments found.');
    END IF;

    v_cgpa := calc_cgpa(p_student_id);
    DBMS_OUTPUT.PUT_LINE(RPAD('-', 64, '-'));
    DBMS_OUTPUT.PUT_LINE('CGPA : ' || NVL(TO_CHAR(v_cgpa, 'FM90.00'), 'Not available'));
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 64, '='));
  END print_report_card;

  -- ---------- department summary (explicit cursor) ----------
  PROCEDURE dept_summary IS
    CURSOR c_dept IS
      SELECT d.dept_name,
             COUNT(s.student_id) AS total_students,
             SUM(CASE WHEN s.status = 'ACTIVE' THEN 1 ELSE 0 END) AS active_students
        FROM departments d
        LEFT JOIN students s ON s.dept_id = d.dept_id
       GROUP BY d.dept_name
       ORDER BY d.dept_name;
    v_row c_dept%ROWTYPE;
  BEGIN
    DBMS_OUTPUT.PUT_LINE(RPAD('Department', 30) || RPAD('Total', 8) || 'Active');
    DBMS_OUTPUT.PUT_LINE(RPAD('-', 46, '-'));
    OPEN c_dept;
    LOOP
      FETCH c_dept INTO v_row;
      EXIT WHEN c_dept%NOTFOUND;
      DBMS_OUTPUT.PUT_LINE(RPAD(v_row.dept_name, 30) ||
                           RPAD(v_row.total_students, 8) || v_row.active_students);
    END LOOP;
    CLOSE c_dept;
  END dept_summary;

  -- ---------- top N students by CGPA ----------
  PROCEDURE top_students(p_n IN NUMBER DEFAULT 3) IS
    TYPE t_rec IS RECORD (id NUMBER, name VARCHAR2(100), cgpa NUMBER);
    TYPE t_tab IS TABLE OF t_rec INDEX BY PLS_INTEGER;
    v_tab t_tab;
    v_tmp t_rec;
    v_i   PLS_INTEGER := 0;
  BEGIN
    FOR s IN (SELECT student_id, first_name || ' ' || last_name AS nm FROM students) LOOP
      v_tmp.cgpa := calc_cgpa(s.student_id);
      IF v_tmp.cgpa IS NOT NULL THEN
        v_i := v_i + 1;
        v_tmp.id   := s.student_id;
        v_tmp.name := s.nm;
        v_tab(v_i) := v_tmp;
      END IF;
    END LOOP;

    -- simple bubble sort, descending by CGPA
    FOR i IN 1 .. v_tab.COUNT - 1 LOOP
      FOR j IN 1 .. v_tab.COUNT - i LOOP
        IF v_tab(j).cgpa < v_tab(j+1).cgpa THEN
          v_tmp      := v_tab(j);
          v_tab(j)   := v_tab(j+1);
          v_tab(j+1) := v_tmp;
        END IF;
      END LOOP;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('TOP ' || p_n || ' STUDENTS BY CGPA');
    DBMS_OUTPUT.PUT_LINE(RPAD('-', 46, '-'));
    FOR k IN 1 .. LEAST(p_n, v_tab.COUNT) LOOP
      DBMS_OUTPUT.PUT_LINE(k || '. ' || RPAD(v_tab(k).name, 28) ||
                           '(ID ' || v_tab(k).id || ')  CGPA ' ||
                           TO_CHAR(v_tab(k).cgpa, 'FM90.00'));
    END LOOP;
  END top_students;

END sis_pkg;
/

-- ------------------------------------------------------------
-- 5. TRIGGERS
-- ------------------------------------------------------------
-- 5a. Auto-calculate total and grade whenever marks change
CREATE OR REPLACE TRIGGER trg_marks_calc
BEFORE INSERT OR UPDATE ON marks
FOR EACH ROW
BEGIN
  :NEW.total_marks := :NEW.internal_marks + :NEW.external_marks;
  :NEW.grade       := sis_pkg.get_grade(:NEW.total_marks);
END;
/

-- 5b. Audit updates and deletes on students
CREATE OR REPLACE TRIGGER trg_students_audit
AFTER UPDATE OR DELETE ON students
FOR EACH ROW
BEGIN
  IF UPDATING THEN
    INSERT INTO audit_log(log_id, table_name, action, record_id, details, changed_by)
    VALUES (seq_audit.NEXTVAL, 'STUDENTS', 'UPDATE', :OLD.student_id,
            'status: ' || :OLD.status || ' -> ' || :NEW.status ||
            '; dept: ' || :OLD.dept_id || ' -> ' || :NEW.dept_id ||
            '; email: ' || :OLD.email || ' -> ' || :NEW.email,
            USER);
  ELSIF DELETING THEN
    INSERT INTO audit_log(log_id, table_name, action, record_id, details, changed_by)
    VALUES (seq_audit.NEXTVAL, 'STUDENTS', 'DELETE', :OLD.student_id,
            'Deleted ' || :OLD.first_name || ' ' || :OLD.last_name, USER);
  END IF;
END;
/

-- ------------------------------------------------------------
-- 6. SAMPLE DATA
-- ------------------------------------------------------------
INSERT INTO departments VALUES (seq_dept.NEXTVAL, 'Computer Science');
INSERT INTO departments VALUES (seq_dept.NEXTVAL, 'Electronics');
INSERT INTO departments VALUES (seq_dept.NEXTVAL, 'Mechanical');

INSERT INTO courses VALUES (seq_course.NEXTVAL, 'Database Management Systems', 4, 10);
INSERT INTO courses VALUES (seq_course.NEXTVAL, 'Data Structures',             4, 10);
INSERT INTO courses VALUES (seq_course.NEXTVAL, 'Operating Systems',           3, 10);
INSERT INTO courses VALUES (seq_course.NEXTVAL, 'Digital Electronics',         3, 20);
INSERT INTO courses VALUES (seq_course.NEXTVAL, 'Thermodynamics',              4, 30);
COMMIT;

-- ------------------------------------------------------------
-- 7. DEMO : use the package
-- ------------------------------------------------------------
DECLARE
  v_s1 NUMBER; v_s2 NUMBER; v_s3 NUMBER; v_s4 NUMBER;
  v_e  NUMBER;
BEGIN
  -- add students
  sis_pkg.add_student('Aarav',  'Sharma', 'aarav@college.edu', DATE '2005-03-14', 10, v_s1);
  sis_pkg.add_student('Priya',  'Verma',  'priya@college.edu', DATE '2004-11-02', 10, v_s2);
  sis_pkg.add_student('Rohan',  'Mehta',  'rohan@college.edu', DATE '2005-07-21', 20, v_s3);
  sis_pkg.add_student('Sneha',  'Gupta',  'sneha@college.edu', DATE '2004-01-30', 30, v_s4);

  -- Aarav : CS, semester 1
  sis_pkg.enroll_student(v_s1, 501, 1, v_e);  sis_pkg.record_marks(v_e, 36, 55);  -- 91 -> O
  sis_pkg.enroll_student(v_s1, 502, 1, v_e);  sis_pkg.record_marks(v_e, 30, 48);  -- 78 -> A
  sis_pkg.enroll_student(v_s1, 503, 1, v_e);  sis_pkg.record_marks(v_e, 28, 40);  -- 68 -> B+

  -- Priya : CS, semester 1
  sis_pkg.enroll_student(v_s2, 501, 1, v_e);  sis_pkg.record_marks(v_e, 38, 56);  -- 94 -> O
  sis_pkg.enroll_student(v_s2, 502, 1, v_e);  sis_pkg.record_marks(v_e, 35, 50);  -- 85 -> A+

  -- Rohan : Electronics
  sis_pkg.enroll_student(v_s3, 504, 1, v_e);  sis_pkg.record_marks(v_e, 20, 30);  -- 50 -> B

  -- Sneha : Mechanical (fails one)
  sis_pkg.enroll_student(v_s4, 505, 1, v_e);  sis_pkg.record_marks(v_e, 12, 20);  -- 32 -> F

  COMMIT;

  -- reports
  sis_pkg.print_report_card(v_s1);
  DBMS_OUTPUT.PUT_LINE(' ');
  sis_pkg.print_report_card(v_s2);
  DBMS_OUTPUT.PUT_LINE(' ');
  sis_pkg.dept_summary;
  DBMS_OUTPUT.PUT_LINE(' ');
  sis_pkg.top_students(3);

  -- update status (fires audit trigger)
  sis_pkg.update_status(v_s3, 'inactive');
  COMMIT;

  -- error handling demos
  BEGIN
    sis_pkg.enroll_student(v_s3, 504, 2, v_e);   -- inactive student
  EXCEPTION
    WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('Expected error: ' || SQLERRM);
  END;

  BEGIN
    sis_pkg.add_student('Dup', 'Email', 'aarav@college.edu', DATE '2004-01-01', 10, v_e);
  EXCEPTION
    WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('Expected error: ' || SQLERRM);
  END;
END;
/

-- ------------------------------------------------------------
-- 8. USEFUL QUERIES
-- ------------------------------------------------------------
-- All students with CGPA
SELECT s.student_id,
       s.first_name || ' ' || s.last_name AS student,
       d.dept_name,
       s.status,
       sis_pkg.calc_cgpa(s.student_id) AS cgpa
  FROM students s JOIN departments d ON d.dept_id = s.dept_id
 ORDER BY cgpa DESC NULLS LAST;

-- Course-wise average marks
SELECT c.course_name, COUNT(*) AS students, ROUND(AVG(m.total_marks),1) AS avg_marks
  FROM marks m
  JOIN enrollments e ON e.enroll_id = m.enroll_id
  JOIN courses c     ON c.course_id = e.course_id
 GROUP BY c.course_name;

-- Audit trail
SELECT log_id, table_name, action, record_id, details, changed_by
  FROM audit_log ORDER BY log_id;
