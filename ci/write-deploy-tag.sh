#!/usr/bin/env bash
# write-deploy-tag.sh -- CI's last act: tell helpdesk-deploy which image to
# run, and stop. Identical shape to ufr/ci/write-deploy-tag.sh; see that file's
# header for the full argument (no cluster credential in CI, "what is deployed"
# answered by reading a file, rollback is git revert).
#
#   ./ci/write-deploy-tag.sh <sha>       # defaults to HEAD
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

SHA="${1:-$(git rev-parse HEAD)}"
GITEA="${GITEA:-http://gitea-http.gitea.svc.cluster.local:3000}"
ORG="${ORG:-demo}"
DEPLOY_REPO="${DEPLOY_REPO:-helpdesk-deploy}"
ENV_FILE="${ENV_FILE:-envs/cloud.yaml}"
GITEA_USERNAME="${GITEA_USERNAME:-oupiadmin}"
BRANCH="deploy/$(basename "$ENV_FILE" .yaml)-${SHA:0:12}"
WORK="${WORK:-/tmp/helpdesk-cloud-deploy-repo}"

: "${DEPLOY_TOKEN:?DEPLOY_TOKEN is required -- a write-scoped token for ${ORG}/${DEPLOY_REPO}}"

fails=0
ok()   { printf '   \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '   \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails+1)); }
note() { printf '   \033[33mNOTE\033[0m  %s\n' "$*"; }

api() {
  local method="$1" path="$2"; shift 2
  curl -sS -m 30 -X "$method" \
    -H "Authorization: token ${DEPLOY_TOKEN}" \
    -H 'Content-Type: application/json' \
    "${GITEA}/api/v1${path}" "$@"
}

echo "=== writing the deploy tag ==="
echo "  image:  ${SHA}"
echo "  target: ${ORG}/${DEPLOY_REPO}:${ENV_FILE}"

CRED_FILE="${CRED_FILE:-/tmp/helpdesk-cloud-deploy-credentials}"
(umask 077; : > "$CRED_FILE")
host="${GITEA#*://}"
scheme="${GITEA%%://*}"
printf '%s://%s:%s@%s\n' "$scheme" "$GITEA_USERNAME" "$DEPLOY_TOKEN" "$host" >> "$CRED_FILE"
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper
export GIT_CONFIG_VALUE_0="store --file=${CRED_FILE}"

rm -rf "$WORK"
if git clone -q --depth 1 "${GITEA}/${ORG}/${DEPLOY_REPO}.git" "$WORK"; then
  ok "cloned ${ORG}/${DEPLOY_REPO}"
else
  bad "could not clone ${ORG}/${DEPLOY_REPO}"
  rm -f "$CRED_FILE"; exit 1
fi

cd "$WORK" || exit 1
[ -f "$ENV_FILE" ] || { bad "${ENV_FILE} does not exist in ${DEPLOY_REPO}"; exit 1; }

current="$(sed -n 's/^[[:space:]]*tag:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "$ENV_FILE" | head -1)"
if [ "$current" = "$SHA" ]; then
  ok "${ENV_FILE} already names ${SHA} -- nothing to do"
  rm -f "$CRED_FILE"
  exit 0
fi
note "current: ${current:-<none>}"

sed -i "s|^\([[:space:]]*\)tag:[[:space:]].*$|\1tag: \"${SHA}\"|" "$ENV_FILE"

written="$(sed -n 's/^[[:space:]]*tag:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' "$ENV_FILE" | head -1)"
if [ "$written" != "$SHA" ]; then
  bad "the edit did not take: ${ENV_FILE} still says '${written}'"
  rm -f "$CRED_FILE"; exit 1
fi
ok "${ENV_FILE} now names ${SHA}"

git checkout -q -b "$BRANCH"
git -c user.name="ci" -c user.email="ci@oupi.local" \
    commit -q -am "deploy: ${SHA:0:12}"
if git push -q origin "$BRANCH" --force; then
  ok "pushed ${BRANCH}"
else
  bad "could not push ${BRANCH} -- is DEPLOY_TOKEN write-scoped on this repository?"
  rm -f "$CRED_FILE"; exit 1
fi

ENV_NAME="$(basename "$ENV_FILE" .yaml)"
DEFAULT_BODY="Built from \`demo/helpdesk-cloud@${SHA}\`.

Opened by CI, which cannot deploy and does not try to: it writes the image tag here and ArgoCD reconciles on its own schedule. Reverting this merge commit rolls ${ENV_NAME} back to the previous image."
PR="$(api POST "/repos/${ORG}/${DEPLOY_REPO}/pulls" \
      -d "$(jq -n --arg h "$BRANCH" --arg t "deploy ${ENV_NAME} ${SHA:0:12}" --arg b "${PR_BODY:-$DEFAULT_BODY}" \
        '{head:$h,base:"main",title:$t,body:$b}')" \
      | jq -r '.number // empty')"
[ -n "$PR" ] || { bad "could not open a pull request"; rm -f "$CRED_FILE"; exit 1; }
ok "opened PR #${PR}"

# AUTO_MERGE=0 stops here: the PR is the request, and a person merging it
# is the approval (promote.sh uses this for production).
if [ "${AUTO_MERGE:-1}" = "0" ]; then
  rm -f "$CRED_FILE"
  echo
  printf '\033[32m=== PR #%s opened, NOT merged: %s/%s/%s/pulls/%s ===\033[0m\n' \
    "$PR" "${PR_URL_BASE:-$GITEA}" "$ORG" "$DEPLOY_REPO" "$PR"
  exit 0
fi

MERGE="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
          -H "Authorization: token ${DEPLOY_TOKEN}" -H 'Content-Type: application/json' \
          -d '{"Do":"merge","delete_branch_after_merge":true}' \
          "${GITEA}/api/v1/repos/${ORG}/${DEPLOY_REPO}/pulls/${PR}/merge")"
case "$MERGE" in
  2*) ok "merged PR #${PR} (HTTP ${MERGE})" ;;
  *)  bad "merge refused with HTTP ${MERGE} -- the deploy is NOT on main" ;;
esac

rm -f "$CRED_FILE"

echo
echo "-- reading main back"
landed="$(api GET "/repos/${ORG}/${DEPLOY_REPO}/raw/main/${ENV_FILE}" \
          | sed -n 's/^[[:space:]]*tag:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' | head -1)"
if [ "$landed" = "$SHA" ]; then
  ok "main names ${SHA} -- ArgoCD will reconcile to it"
else
  bad "main names '${landed}', not ${SHA}"
fi

echo
if [ "$fails" -eq 0 ]; then
  printf '\033[32m=== deploy tag written: %s ===\033[0m\n' "$SHA"
  exit 0
fi
printf '\033[31m=== %d check(s) failed ===\033[0m\n' "$fails"
exit 1
