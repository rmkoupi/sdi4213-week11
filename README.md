# SDI 4213 Week 11 - Cloud Deployment Starter

This repository contains the Help Desk / Service Request Tracker used for the Week 11 individual exercise.

## Week 11 Goal
Deploy the containerized application to a real cloud web service and connect it to a managed PostgreSQL database. The application should be publicly reachable through HTTPS and retain ticket data across application redeployments.

## Local Run

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python -m streamlit run app.py
```

macOS/Linux activation:

```bash
source .venv/bin/activate
```

The local version uses SQLite unless `DATABASE_URL` is configured.

## Tests

```bash
python -m pytest -v
```

## Docker

```bash
docker build -t helpdesk-cloud:week11 .
docker run --rm -p 8501:8501 -e DEPLOY_ENV=Local-Docker helpdesk-cloud:week11
```

Open `http://localhost:8501`.

## Cloud Deployment

**Public URL:** https://oupi-demo.rmk.lol/helpdesk/

The application runs on a private cloud (the OUPI platform, Kubernetes) rather
than a public PaaS. The pieces map one-to-one onto the Render workflow in the
exercise:

| Exercise (Render) | This deployment |
|---|---|
| Managed PostgreSQL | CloudNativePG cluster `helpdesk-cloud-db`, with daily base backups and continuous WAL archiving |
| Internal Database URL | Kubernetes Secret created by the database operator; the app reads it as `DATABASE_URL` by reference |
| Web Service (Docker) | Argo CD application `helpdesk-cloud`, running the image built from this repository's `Dockerfile` |
| Environment variables | `DEPLOY_ENV=Cloud`, `APP_VERSION`, `DATABASE_URL` (secret reference); `PORT` is not set by hand |
| Health check path | `/helpdesk/_stcore/health` (the app is served under `/helpdesk`) |
| Auto-deploy from `main` | The platform mirrors this repository every 10 minutes; each new `main` commit is built, deployed and verified |

### How a change reaches production

1. Issue → branch → commit → push → pull request.
2. GitHub Actions (`.github/workflows/ci.yml`) runs the tests, including the
   PostgreSQL-path tests against a PostgreSQL service container, and builds the
   Docker image.
3. Merge to `main`.
4. The platform's copy of the repository syncs, and its pipeline
   (`.gitea/workflows/ci.yml`) runs the tests, builds the image in the cluster,
   records the new image tag in the deployment configuration, and verifies the
   result: the new version is rolled out, the page renders against PostgreSQL,
   and the public URL answers.

Ticket data lives in PostgreSQL, not in the container, so the web service can
be redeployed or restarted without losing tickets.

`make status`, `make logs`, `make restart` and `make env` are operator
shortcuts (see `Makefile`); `make env` lists variable names and shows the
database URL only as a secret reference.

No credentials are stored in this repository.

## Security
- Do not commit `.env`.
- Do not place database passwords in source code.
- In the cloud dashboard, environment-variable names may be visible in screenshots, but secret values must be hidden.
