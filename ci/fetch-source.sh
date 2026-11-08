#!/bin/sh
# fetch-source.sh -- runs as the build Job's init container, cloning THIS
# repository at the exact commit being built into the kaniko context.
#
# ONE REPOSITORY, unlike inventory-tracker's fetch-source.sh (which clones a
# second, backend-base, from Platform's forge). ufr vendors everything it
# needs at commit time instead of depending on a sibling clone at build time
# -- see the top-level README's "Provenance" section for why that vendoring
# happened in the first place. So this script is the one-repository case
# inventory-tracker's own comments describe as simpler, not a trimmed-down
# copy of a shape this app doesn't need.
#
# Cloned fresh rather than reusing whatever the CI runner's actions/checkout
# already has on disk, because this Job is independent of that pod and may
# run on a different one later (a human re-running the bootstrap build from a
# workstation has no checkout on the cluster at all).
set -eu

: "${GIT_SHA:?GIT_SHA is required}"
: "${APP_REPO_URL:?APP_REPO_URL is required}"
: "${GITEA_USERNAME:?GITEA_USERNAME is required (from demo-build-tokens)}"
: "${GITEA_TOKEN:?GITEA_TOKEN is required (from demo-build-tokens)}"

# THE TOKEN GOES IN THE URL FOR THIS ONE CLONE AND NOWHERE ELSE -- never
# printed, never written to a config file that outlives this container.
AUTH_URL=$(printf '%s' "$APP_REPO_URL" | sed "s#://#://${GITEA_USERNAME}:${GITEA_TOKEN}@#")

echo "cloning ${APP_REPO_URL} at ${GIT_SHA}"
git clone -q "$AUTH_URL" /workspace
cd /workspace
git checkout -q "$GIT_SHA"
echo "checked out $(git rev-parse HEAD)"
