import os
import tempfile

import db


def setup_module():
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    os.environ.pop("DATABASE_URL", None)
    os.environ["SQLITE_PATH"] = path
    setup_module.path = path
    db.init_db()


def teardown_module():
    try:
        os.remove(setup_module.path)
    except FileNotFoundError:
        pass


def test_database_mode_is_sqlite_without_database_url():
    assert db.database_mode() == "SQLite"


def test_create_and_list_ticket():
    db.create_ticket("Projector issue", "Hardware", "High", "Projector will not power on.")
    tickets = db.list_tickets()
    assert any(t["title"] == "Projector issue" for t in tickets)


def test_update_status():
    tickets = db.list_tickets()
    ticket_id = tickets[0]["id"]
    db.update_status(ticket_id, "Closed")
    updated = {t["id"]: t for t in db.list_tickets()}
    assert updated[ticket_id]["status"] == "Closed"


def test_rejects_blank_title():
    try:
        db.create_ticket("", "Hardware", "Low", "Description")
    except ValueError as exc:
        assert "Title" in str(exc)
    else:
        raise AssertionError("Expected ValueError")
