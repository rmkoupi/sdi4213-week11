import os
import streamlit as st

from db import CATEGORIES, PRIORITIES, STATUSES, create_ticket, database_mode, init_db, list_tickets, update_status

st.set_page_config(page_title="Help Desk Cloud Lab", page_icon="🛠️", layout="wide")

APP_VERSION = os.getenv("APP_VERSION", "1.0.0")
DEPLOY_ENV = os.getenv("DEPLOY_ENV", "Local")

try:
    init_db()
except Exception as exc:
    st.error(f"Database initialization failed: {exc}")
    st.stop()

st.title("Help Desk / Service Request Tracker")
st.caption(f"Version {APP_VERSION} | Environment: {DEPLOY_ENV} | Database: {database_mode()}")

with st.sidebar:
    st.header("Deployment Info")
    st.write(f"**Environment:** {DEPLOY_ENV}")
    st.write(f"**Version:** {APP_VERSION}")
    st.write(f"**Database:** {database_mode()}")
    st.info("Week 11 goal: deploy this containerized application to a public cloud service using managed PostgreSQL.")

left, right = st.columns([1, 1.4])

with left:
    st.subheader("Create Service Request")
    with st.form("new_ticket", clear_on_submit=True):
        title = st.text_input("Title")
        category = st.selectbox("Category", CATEGORIES)
        priority = st.selectbox("Priority", PRIORITIES, index=1)
        description = st.text_area("Description")
        submitted = st.form_submit_button("Submit Request", use_container_width=True)
        if submitted:
            try:
                create_ticket(title, category, priority, description)
                st.success("Service request created.")
            except ValueError as exc:
                st.warning(str(exc))
            except Exception as exc:
                st.error(f"Could not create service request: {exc}")

with right:
    st.subheader("Current Requests")
    try:
        tickets = list_tickets()
    except Exception as exc:
        st.error(f"Could not load tickets: {exc}")
        tickets = []

    if not tickets:
        st.info("No service requests yet. Create one to test persistence.")
    else:
        for ticket in tickets:
            with st.expander(
                f"#{ticket['id']} - {ticket['title']} [{ticket['priority']}]",
                expanded=ticket["status"] != "Closed",
            ):
                st.write(f"**Category:** {ticket['category']}")
                st.write(f"**Status:** {ticket['status']}")
                st.write(f"**Created:** {ticket['created_at']}")
                st.write(ticket["description"])
                new_status = st.selectbox(
                    "Update status",
                    STATUSES,
                    index=STATUSES.index(ticket["status"]),
                    key=f"status_{ticket['id']}",
                )
                if st.button("Save Status", key=f"save_{ticket['id']}"):
                    update_status(ticket["id"], new_status)
                    st.rerun()
