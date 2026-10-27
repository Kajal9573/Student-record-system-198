"""
Flask backend for the Student Information System.
Serves index.html and exposes a small JSON API over the Oracle table
STUDENT_RECORD (created by student_record.sql).

Setup:
    pip install -r requirements.txt

    # Windows (PowerShell)
    $env:ORACLE_USER="your_user"
    $env:ORACLE_PASSWORD="your_password"
    $env:ORACLE_DSN="localhost:1521/XEPDB1"

    # Linux / macOS
    export ORACLE_USER=your_user ORACLE_PASSWORD=your_password ORACLE_DSN=localhost:1521/XEPDB1

Run:
    python app.py        ->  open http://127.0.0.1:5000
"""
import os

import oracledb
from flask import Flask, jsonify, request, send_file

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
app = Flask(__name__, static_folder=None)   # only index.html is served, not the whole folder


def get_conn():
    return oracledb.connect(
        user=os.environ["ORACLE_USER"],
        password=os.environ["ORACLE_PASSWORD"],
        dsn=os.environ["ORACLE_DSN"],
    )


def clean_student(data):
    """Validate the JSON body and return a clean dict, or raise ValueError."""
    try:
        s = {
            "name": str(data.get("name", "")).strip(),
            "email": str(data.get("email", "")).strip().lower(),
            "phone": str(data.get("phone", "")).strip() or None,
            "course": str(data.get("course", "")).strip(),
            "year": int(data.get("year")),
            "marks": float(data.get("marks")),
        }
    except (TypeError, ValueError):
        raise ValueError("Year and marks must be numbers")

    if not s["name"] or not s["email"] or not s["course"]:
        raise ValueError("Name, email and course are required")
    if not 1 <= s["year"] <= 4:
        raise ValueError("Year must be between 1 and 4")
    if not 0 <= s["marks"] <= 100:
        raise ValueError("Marks must be between 0 and 100")
    return s


@app.route("/")
def home():
    return send_file(os.path.join(BASE_DIR, "index.html"))


@app.get("/api/students")
def list_students():
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT roll_no, name, email, phone, course, year_of_study, marks, grade "
            "FROM student_record ORDER BY roll_no"
        )
        rows = [
            {"roll": r[0], "name": r[1], "email": r[2], "phone": r[3],
             "course": r[4], "year": r[5], "marks": r[6], "grade": r[7]}
            for r in cur.fetchall()
        ]
    return jsonify(rows)


@app.post("/api/students")
def add_student():
    try:
        s = clean_student(request.get_json(silent=True) or {})
    except ValueError as e:
        return jsonify(error=str(e)), 400

    try:
        with get_conn() as conn:
            cur = conn.cursor()
            roll = cur.var(int)
            cur.execute(
                "INSERT INTO student_record (roll_no, name, email, phone, course, year_of_study, marks) "
                "VALUES (seq_roll_no.NEXTVAL, :n, :e, :p, :c, :y, :m) RETURNING roll_no INTO :r",
                n=s["name"], e=s["email"], p=s["phone"], c=s["course"],
                y=s["year"], m=s["marks"], r=roll,
            )
            conn.commit()
            return jsonify(roll=roll.getvalue()[0]), 201
    except oracledb.IntegrityError:
        return jsonify(error="A student with this email already exists"), 409
    except oracledb.DatabaseError as e:
        return jsonify(error="Database error: " + str(e).split("\n")[0]), 400


@app.put("/api/students/<int:roll>")
def update_student(roll):
    try:
        s = clean_student(request.get_json(silent=True) or {})
    except ValueError as e:
        return jsonify(error=str(e)), 400

    try:
        with get_conn() as conn:
            cur = conn.cursor()
            cur.execute(
                "UPDATE student_record SET name = :n, phone = :p, course = :c, "
                "year_of_study = :y, marks = :m WHERE roll_no = :r",
                n=s["name"], p=s["phone"], c=s["course"], y=s["year"], m=s["marks"], r=roll,
            )
            if cur.rowcount == 0:
                return jsonify(error="Student not found"), 404
            conn.commit()
            return jsonify(ok=True)
    except oracledb.DatabaseError as e:
        return jsonify(error="Database error: " + str(e).split("\n")[0]), 400


@app.delete("/api/students/<int:roll>")
def delete_student(roll):
    try:
        with get_conn() as conn:
            cur = conn.cursor()
            cur.execute("DELETE FROM student_record WHERE roll_no = :r", r=roll)
            if cur.rowcount == 0:
                return jsonify(error="Student not found"), 404
            conn.commit()
            return jsonify(ok=True)
    except oracledb.DatabaseError as e:
        return jsonify(error="Database error: " + str(e).split("\n")[0]), 400


if __name__ == "__main__":
    app.run(debug=True)
