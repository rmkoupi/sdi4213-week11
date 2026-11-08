import os
import sqlite3
from contextlib import contextmanager

STATUSES = ("Open", "In Progress", "Closed")
PRIORITIES = ("Low", "Medium", "High", "Critical")
CATEGORIES = ("Hardware", "Software", "Network", "Access", "Other")


def database_mode() -> str:
    url = os.getenv("DATABASE_URL", "").strip()
    return "PostgreSQL" if url.startswith(("postgres://", "postgresql://")) else "SQLite"


@contextmanager
def connection():
    url = os.getenv("DATABASE_URL", "").strip()
    if url.startswith(("postgres://", "postgresql://")):
        import psycopg
        conn = psycopg.connect(url)
    else:
        path = os.getenv("SQLITE_PATH", "helpdesk.db")
        conn = sqlite3.connect(path)
        conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db() -> None:
    if database_mode() == "PostgreSQL":
        sql = """
        CREATE TABLE IF NOT EXISTS tickets (
            id SERIAL PRIMARY KEY,
            title TEXT NOT NULL,
            category TEXT NOT NULL,
            priority TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'Open',
            description TEXT NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """
    else:
        sql = """
        CREATE TABLE IF NOT EXISTS tickets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            category TEXT NOT NULL,
            priority TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'Open',
            description TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
        """
    with connection() as conn:
        conn.execute(sql)


def create_ticket(title: str, category: str, priority: str, description: str) -> None:
    title = title.strip()
    description = description.strip()
    if not title:
        raise ValueError("Title is required.")
    if category not in CATEGORIES:
        raise ValueError("Invalid category.")
    if priority not in PRIORITIES:
        raise ValueError("Invalid priority.")
    if not description:
        raise ValueError("Description is required.")

    if database_mode() == "PostgreSQL":
        sql = "INSERT INTO tickets (title, category, priority, description) VALUES (%s, %s, %s, %s)"
    else:
        sql = "INSERT INTO tickets (title, category, priority, description) VALUES (?, ?, ?, ?)"
    with connection() as conn:
        conn.execute(sql, (title, category, priority, description))


def list_tickets():
    with connection() as conn:
        cur = conn.execute(
            "SELECT id, title, category, priority, status, description, created_at FROM tickets ORDER BY id DESC"
        )
        rows = cur.fetchall()
    return [dict(row) if not isinstance(row, dict) else row for row in rows]


def update_status(ticket_id: int, status: str) -> None:
    if status not in STATUSES:
        raise ValueError("Invalid status.")
    if database_mode() == "PostgreSQL":
        sql = "UPDATE tickets SET status = %s WHERE id = %s"
    else:
        sql = "UPDATE tickets SET status = ? WHERE id = ?"
    with connection() as conn:
        conn.execute(sql, (status, ticket_id))
