from flask import Flask, render_template, request, redirect, url_for
import sqlite3

app = Flask(__name__)

DATABASE = "notes.db"


def init_db():
    conn = sqlite3.connect(DATABASE)
    cursor = conn.cursor()

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS notes(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        content TEXT NOT NULL
    )
    """)

    conn.commit()
    conn.close()

import logging

@app.route("/")
def index():
    try:
        conn = sqlite3.connect(DATABASE)
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM notes")
        notes = cursor.fetchall()
        conn.close()
        return render_template("index.html", notes=notes)
    except Exception as e:
        return "Error retrieving notes", 500


@app.route("/add", methods=["POST"])
def add_note():

    title = request.form["title"]
    content = request.form["content"]

    conn = sqlite3.connect(DATABASE)
    cursor = conn.cursor()

    cursor.execute(
        "INSERT INTO notes(title, content) VALUES(?, ?)",
        (title, content)
    )

    conn.commit()
    conn.close()

    return redirect(url_for("index"))


@app.route("/delete/<int:id>")
def delete_note(id):

    conn = sqlite3.connect(DATABASE)
    cursor = conn.cursor()

    cursor.execute(
        "DELETE FROM notes WHERE id=?",
        (id,)
    )

    conn.commit()
    conn.close()

    return redirect(url_for("index"))


@app.route("/edit/<int:id>")
def edit_note(id):

    conn = sqlite3.connect(DATABASE)
    cursor = conn.cursor()

    cursor.execute(
        "SELECT * FROM notes WHERE id=?",
        (id,)
    )

    note = cursor.fetchone()

    conn.close()

    return render_template(
        "edit.html",
        note=note
    )


@app.route("/update/<int:id>", methods=["POST"])
def update_note(id):

    title = request.form["title"]
    content = request.form["content"]

    conn = sqlite3.connect(DATABASE)
    cursor = conn.cursor()

    cursor.execute(
        """
        UPDATE notes
        SET title=?, content=?
        WHERE id=?
        """,
        (title, content, id)
    )

    conn.commit()
    conn.close()

    return redirect("/")



if __name__ == "__main__":
    init_db()
    app.run(debug=True)