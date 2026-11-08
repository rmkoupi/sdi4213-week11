# Render Setup Checklist

Use the detailed Word assignment for the authoritative steps.

- [ ] Create a Render account.
- [ ] Create a free PostgreSQL database in the same region you plan to use for the web service.
- [ ] Create a Web Service connected to your GitHub repository.
- [ ] Select Docker as the runtime/language.
- [ ] Choose the Free compute plan.
- [ ] Add environment variables: `DEPLOY_ENV=Cloud`, `APP_VERSION=1.0.0`, and `DATABASE_URL=<Render internal database URL>`.
- [ ] Set the health check path to `/_stcore/health`.
- [ ] Deploy the service.
- [ ] Verify the public HTTPS URL.
- [ ] Create a ticket and confirm persistence after a redeploy.
- [ ] Never expose the database password in screenshots or Git history.
