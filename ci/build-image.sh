#!/usr/bin/env bash
# build-image.sh -- build this commit's image in the cluster and push it to
# the registry. Same shape as ufr/ci/build-image.sh (one repository, no
# sibling clone -- see ci/fetch-source.sh).
#
#   ./ci/build-image.sh                 # builds HEAD
#   ./ci/build-image.sh <sha>           # builds a specific commit
#   FORCE=1 ./ci/build-image.sh <sha>   # rebuild a tag that is already there
#
# Idempotent: an image already in the registry under this tag is reported and
# nothing is rebuilt, because the tag is a git SHA and the same SHA cannot
# honestly produce different bytes.
#
# THE SAME SCRIPT FROM CI AND FROM A WORKSTATION. KUBECTL is the whole of the
# difference:
#
#   in CI      KUBECTL="kubectl"   -- the runner pod's ServiceAccount
#   bootstrap  KUBECTL="ssh -p 22 oupi-node0 sudo /opt/oupi-ops/scripts/metal/lib/k.sh"
#
# One code path, so the break-glass route cannot rot.
#
# NO `docker build` HERE: the node has no container runtime, deliberately --
# see oupi-ops/cluster/metal/image-build-job.yaml.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

SHA="${1:-$(git rev-parse HEAD)}"
# The release the page shows (APP_VERSION). From the nearest tag when the
# checkout has tags (CI fetches them), else the short SHA, so a running pod
# can always say which build it is.
VERSION="${VERSION:-$(git describe --tags --always "$SHA" 2>/dev/null || echo "${SHA:0:12}")}"
VERSION="${VERSION#v}"
NAMESPACE="${NAMESPACE:-image-builds}"
REGISTRY="${REGISTRY:-cr.oupi.local:5000}"
IMAGE="${IMAGE:-demo/helpdesk-cloud}"
NODE_IP="${NODE_IP:-10.99.0.1}"
KANIKO="${KANIKO:-gcr.io/kaniko-project/executor:v1.23.2}"
FETCH_IMAGE="${FETCH_IMAGE:-cr.oupi.local:5000/oupi/ci-runner:0.2.0}"
BUILD_MEM="${BUILD_MEM:-3Gi}"
TIMEOUT="${TIMEOUT:-900}"
KUBECTL="${KUBECTL:-kubectl}"
GITEA_INTERNAL="${GITEA_INTERNAL:-http://gitea-http.gitea.svc.cluster.local:3000}"
APP_REPO_URL="${APP_REPO_URL:-${GITEA_INTERNAL}/demo/helpdesk-cloud.git}"

CURL="${CURL:-curl}"
REGISTRY_PROBE_HOST="${REGISTRY_PROBE_HOST:-${NODE_IP}:5000}"

DEST="${REGISTRY}/${IMAGE}:${SHA}"
NAME="build-helpdesk-cloud-${SHA:0:12}"
REGISTRY_API="http://${REGISTRY_PROBE_HOST}/v2/${IMAGE}"

fails=0
ok()   { printf '   \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '   \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails+1)); }
note() { printf '   \033[33mNOTE\033[0m  %s\n' "$*"; }

echo "=== in-cluster image build ==="
echo "  commit: ${SHA}"
echo "  dest:   ${DEST}"
echo "  version: ${VERSION}"
echo "  job:    ${NAMESPACE}/${NAME}"

# ── 0. Already there? ─────────────────────────────────────────────────────
tag_present() {
  $CURL -sS -m 10 "${REGISTRY_API}/tags/list" 2>/dev/null \
    | tr ',' '\n' | grep -q "\"${SHA}\""
}

echo
echo "-- registry"
if [ "${FORCE:-0}" != "1" ] && tag_present; then
  ok "${DEST} is already in the registry -- nothing to build (FORCE=1 to rebuild)"
  exit 0
fi
note "tag not present yet -- building"

# ── 1. The context script ─────────────────────────────────────────────────
echo
echo "-- context script"
if ! err="$($KUBECTL create configmap "${NAME}-script" \
              --namespace "$NAMESPACE" \
              --from-file=fetch-source.sh=ci/fetch-source.sh \
              --dry-run=client -o yaml 2>&1 | $KUBECTL apply -f - 2>&1)"; then
  bad "could not apply the context ConfigMap:"
  printf '%s\n' "$err" | sed 's/^/         /'
  exit 1
fi
ok "${NAME}-script applied"

# ── 2. The Job ────────────────────────────────────────────────────────────
echo
echo "-- build job"
$KUBECTL -n "$NAMESPACE" delete job "$NAME" \
  --ignore-not-found --cascade=foreground --wait=true >/dev/null 2>&1 || true

sed -e "s|__NAME__|${NAME}|g" \
    -e "s|__NAMESPACE__|${NAMESPACE}|g" \
    -e "s|__SHA__|${SHA}|g" \
    -e "s|__DEST__|${DEST}|g" \
    -e "s|__NODEIP__|${NODE_IP}|g" \
    -e "s|__KANIKO__|${KANIKO}|g" \
    -e "s|__FETCH_IMAGE__|${FETCH_IMAGE}|g" \
    -e "s|__BUILDMEM__|${BUILD_MEM}|g" \
    -e "s|__VERSION__|${VERSION}|g" \
    -e "s|__APP_REPO_URL__|${APP_REPO_URL}|g" \
    ci/build-job.yaml | $KUBECTL apply -f - >/dev/null \
  && ok "job applied" \
  || { bad "could not apply the build job"; exit 1; }

# ── 3. Wait ───────────────────────────────────────────────────────────────
echo
echo "-- building (up to ${TIMEOUT}s)"
state=""
deadline=$(( SECONDS + TIMEOUT ))
while [ "$SECONDS" -lt "$deadline" ]; do
  cond="$($KUBECTL -n "$NAMESPACE" get job "$NAME" -o json 2>/dev/null \
          | jq -r '[.status.conditions[]? | select(.status=="True") | .type] | join(",")' 2>/dev/null || true)"
  case "$cond" in
    *Complete*) state=complete; break ;;
    *Failed*)   state=failed;   break ;;
  esac
  sleep 10
done

POD="$($KUBECTL -n "$NAMESPACE" get pods \
        --selector="batch.kubernetes.io/job-name=${NAME}" \
        -o json 2>/dev/null | jq -r '.items[0].metadata.name // empty' 2>/dev/null || true)"

if [ -n "$POD" ]; then
  $KUBECTL -n "$NAMESPACE" logs "$POD" --all-containers=true --tail=-1 2>/dev/null \
    | sed 's/^/   /' || true
fi

case "$state" in
  complete) ok "build job completed" ;;
  failed)
    bad "build job FAILED"
    [ -n "$POD" ] && $KUBECTL -n "$NAMESPACE" get pod "$POD" -o json 2>/dev/null \
      | jq -r '(.status.initContainerStatuses // []) + (.status.containerStatuses // [])
               | .[] | "\(.name): \(.state.terminated.reason // "running") (exit \(.state.terminated.exitCode // "-"))"' \
      | sed 's/^/   /'
    ;;
  *) bad "build job neither completed nor failed within ${TIMEOUT}s" ;;
esac

# ── 4. The artefact exists ────────────────────────────────────────────────
echo
echo "-- artefact"
if tag_present; then
  ok "${DEST} is in the registry"
else
  bad "${DEST} is NOT in the registry -- the build reported success and produced nothing"
fi

echo
if [ "$fails" -eq 0 ]; then
  printf '\033[32m=== image built: %s ===\033[0m\n' "$DEST"
  exit 0
fi
printf '\033[31m=== %d check(s) failed ===\033[0m\n' "$fails"
exit 1
