#!/usr/bin/env bash
# smoke.sh -- is the cloud environment serving this commit, does the page
# work against the managed database, and is it reachable from the Internet?
#
#   ./ci/smoke.sh <sha>            # CI's verify job (defaults to HEAD)
#
# Week 10's smoke.sh, for the Week 11 `cloud` environment. Three checks, each
# a precondition of the next:
#
#   1. Argo CD has rolled out THIS image (poll with a budget; a check against
#      the previous pod would pass for the wrong build).
#   2. The page renders, in the deployed image, with the deployed config. A
#      Job runs ci/smoke_render.py with the Deployment's own DEPLOY_ENV and
#      APP_VERSION and the same DATABASE_URL secretKeyRef, and expects the
#      caption to say Cloud, PostgreSQL and that version. The health endpoint
#      alone would pass on a page that crashes (the Week 10 lesson).
#   3. The PUBLIC health URL answers `ok`: tunnel -> WFE -> Service, the path
#      a user takes.
#
# What changed from Week 10: there is no data volume to mount (the data is in
# CNPG), the image runs as UID 1000, and the Job reads the database by the same
# reference the app does. The Job's pod reads the Secret; this script never
# does, and act-runner has no right to (oupi-ops apps/helpdesk.yaml).
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

SHA="${1:-$(git rev-parse HEAD)}"
NAMESPACE="${NAMESPACE:-helpdesk-cloud}"
RELEASE="${RELEASE:-helpdesk}"
REGISTRY="${REGISTRY:-cr.oupi.local:5000}"
IMAGE="${REGISTRY}/${IMAGE_NAME:-demo/helpdesk-cloud}:${SHA}"
DB_SECRET="${DB_SECRET:-helpdesk-cloud-db-app}"
PUBLIC_HEALTH="${PUBLIC_HEALTH:-https://oupi-demo.rmk.lol/helpdesk/_stcore/health}"
TIMEOUT="${TIMEOUT:-600}"
INTERVAL="${INTERVAL:-10}"
KUBECTL="${KUBECTL:-kubectl}"
JOB="smoke-${SHA:0:12}"

fails=0
ok()   { printf '   \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '   \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails+1)); }
note() { printf '   \033[33mNOTE\033[0m  %s\n' "$*"; }
k()    { $KUBECTL -n "$NAMESPACE" "$@"; }

echo "=== smoke test: cloud ==="
echo "  expect: ${IMAGE}"
DEADLINE=$(( SECONDS + TIMEOUT ))

# ── 1. This image, rolled out ─────────────────────────────────────────────
echo
echo "-- rollout"
while :; do
  dep="$(k get deployment "$RELEASE" -o json 2>/dev/null || true)"
  image="$(printf '%s' "$dep" | jq -r '.spec.template.spec.containers[0].image // empty' 2>/dev/null)"
  ready="$(printf '%s' "$dep" | jq -r '
      (.status.observedGeneration // 0) >= (.metadata.generation // 1)
      and (.status.updatedReplicas // 0) == (.spec.replicas // 1)
      and (.status.availableReplicas // 0) == (.spec.replicas // 1)
      and (.status.replicas // 0) == (.spec.replicas // 1)' 2>/dev/null)"
  if [ "$image" = "$IMAGE" ] && [ "$ready" = "true" ]; then
    ok "deployment/${RELEASE} runs ${SHA:0:12} and is available"
    break
  fi
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    bad "deployment/${RELEASE} not on ${SHA:0:12} within ${TIMEOUT}s (image: ${image:-none}, rolled out: ${ready:-?})"
    printf '\033[31m=== %d check(s) failed ===\033[0m\n' "$fails"
    exit 1
  fi
  note "waiting for Argo CD: image ${image##*:}, rolled out ${ready:-?} ($(( DEADLINE - SECONDS ))s left)"
  sleep "$INTERVAL"
done

# What the environment says it is: read from the Deployment Argo CD applied,
# so the expectation is the configuration in git, not a copy of it here.
envval() {
  printf '%s' "$dep" | jq -r --arg n "$1" \
    '.spec.template.spec.containers[0].env[]? | select(.name==$n) | .value // empty'
}
EXPECT_ENV="$(envval DEPLOY_ENV)"
EXPECT_VERSION="$(envval APP_VERSION)"
BASE_PATH="$(envval STREAMLIT_SERVER_BASE_URL_PATH)"
note "configured: DEPLOY_ENV=${EXPECT_ENV:-?} APP_VERSION=${EXPECT_VERSION:-?} basePath=${BASE_PATH:-/}"

# ── 2. The page, in the deployed image, against the managed database ─────
echo
echo "-- render (in-cluster Job)"
k create configmap smoke-render --from-file=smoke_render.py=ci/smoke_render.py \
  --dry-run=client -o yaml | k apply -f - >/dev/null \
  || { bad "could not apply ConfigMap smoke-render"; exit 1; }
k delete job "$JOB" --ignore-not-found --wait=true >/dev/null 2>&1 || true

k apply -f - >/dev/null <<YAML || { bad "could not create Job ${JOB}"; exit 1; }
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  labels:
    app.kubernetes.io/name: helpdesk-smoke
    app.kubernetes.io/version: "${SHA}"
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: smoke
          image: ${IMAGE}
          workingDir: /app
          command: ["python", "/smoke/smoke_render.py"]
          env:
            - { name: DEPLOY_ENV, value: "${EXPECT_ENV}" }
            - { name: APP_VERSION, value: "${EXPECT_VERSION}" }
            - { name: EXPECT_ENV, value: "${EXPECT_ENV}" }
            - { name: EXPECT_VERSION, value: "${EXPECT_VERSION}" }
            - { name: EXPECT_DB, value: "PostgreSQL" }
            - { name: STREAMLIT_BROWSER_GATHER_USAGE_STATS, value: "false" }
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef: { name: ${DB_SECRET}, key: uri }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          resources:
            requests: { cpu: 100m, memory: 192Mi }
            limits: { memory: 384Mi }
          volumeMounts:
            - { name: smoke, mountPath: /smoke, readOnly: true }
            - { name: home, mountPath: /home/appuser }
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: smoke
          configMap: { name: smoke-render }
        - name: home
          emptyDir: {}
        - name: tmp
          emptyDir: {}
YAML

state=""
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  cond="$(k get job "$JOB" -o json 2>/dev/null \
          | jq -r '[.status.conditions[]? | select(.status=="True") | .type] | join(",")' 2>/dev/null || true)"
  case "$cond" in
    *Complete*) state=complete; break ;;
    *Failed*)   state=failed;   break ;;
  esac
  sleep 3
done
k logs "job/${JOB}" --tail=-1 2>/dev/null | grep -v 'missing ScriptRunContext' | sed 's/^/   /' || true
case "$state" in
  complete) ok "page renders against PostgreSQL and reports ${EXPECT_ENV} ${EXPECT_VERSION}" ;;
  failed)   bad "page render failed (log above)" ;;
  *)        bad "smoke Job neither completed nor failed in time" ;;
esac

# ── 3. The public path ────────────────────────────────────────────────────
echo
echo "-- public"
body="$(curl -sS -m 20 "$PUBLIC_HEALTH" 2>&1 || true)"
if [ "$body" = "ok" ]; then
  ok "${PUBLIC_HEALTH} answers ok"
else
  bad "${PUBLIC_HEALTH} answered: ${body:0:120}"
fi

echo
if [ "$fails" -eq 0 ]; then
  printf '\033[32m=== cloud is healthy on %s ===\033[0m\n' "${SHA:0:12}"
  exit 0
fi
printf '\033[31m=== %d check(s) failed: cloud is NOT healthy on %s ===\033[0m\n' "$fails" "${SHA:0:12}"
exit 1
