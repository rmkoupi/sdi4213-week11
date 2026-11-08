"""The PostgreSQL path, against a real server.

test_db.py covers SQLite only, and the PostgreSQL path differs where it
matters: placeholders (%s), the row type psycopg returns, and SERIAL ids. The
cloud deployment runs this path, so CI runs it too, against the postgres
service container in .github/workflows/ci.yml.

Skipped unless TEST_DATABASE_URL is set; it is a disposable database.
"""

import os

import pytest

URL = os.environ.get("TEST_DATABASE_URL", "")
pytestmark = pytest.mark.skipif(not URL, reason="TEST_DATABASE_URL not set")


@pytest.fixture
def pg(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", URL)
    import db

    db.init_db()
    with db.connection() as conn:
        conn.execute("TRUNCATE tickets RESTART IDENTITY")
    return db


def test_mode_is_postgresql(pg):
    assert pg.database_mode() == "PostgreSQL"


def test_create_list_update(pg):
    pg.create_ticket("VPN down", "Network", "High", "Cannot reach the VPN.")
    tickets = pg.list_tickets()
    assert [t["title"] for t in tickets] == ["VPN down"]
    pg.update_status(tickets[0]["id"], "In Progress")
    assert pg.list_tickets()[0]["status"] == "In Progress"
