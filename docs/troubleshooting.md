# Week 11 Troubleshooting

## Service deploys but the page does not load
Confirm the application listens on `0.0.0.0` and uses the cloud provider's `PORT` value. The provided Dockerfile already handles this.

## Database connection fails
Check `DATABASE_URL`, confirm the database and web service are in compatible regions, and make sure you used the provider's internal PostgreSQL connection string when available.

## App works locally but not in cloud
Review deploy logs. Common causes include a missing environment variable, missing dependency, incorrect Docker build context, or a database URL copied incorrectly.

## First request is slow
Free cloud services may spin down after inactivity and need to spin back up when a new request arrives.

## Data disappears
The app should store cloud data in managed PostgreSQL, not in the container filesystem. Local container files are not a reliable persistence strategy in cloud deployment.

## Never screenshot secrets
Screenshots may show environment-variable names, but passwords, tokens, and connection strings must be hidden.
