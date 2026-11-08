# Operator shortcuts for the private-cloud deployment (the oupi estate).
# The handout's Render dashboard buttons, as commands. Nothing here holds a
# secret: the Gitea token is read from ~/.git-credentials at run time and the
# database URL is never read at all.
#
#   make sync      pull GitHub main into the estate mirror now (skip the 10 min wait)
#   make status    what is deployed: image, pods, database, Argo CD sync
#   make logs      runtime logs of the web service
#   make restart   replace the running instance (Part I: persistence)
#   make env       environment-variable NAMES on the live Deployment (Part F)

KUBECONFIG ?= $(HOME)/.kube/oupi-node0.yaml
export KUBECONFIG
NS      := helpdesk-cloud
GITEA   := https://oupi-git.rmk.lol
MIRROR  := demo/helpdesk-cloud
TOKEN    = $(shell sed -n 's#^https://oupiadmin:\([^@]*\)@oupi-git.rmk.lol.*#\1#p' $(HOME)/.git-credentials | head -1)

.PHONY: sync status logs restart env

sync:
	@curl -sS -o /dev/null -w 'mirror-sync: HTTP %{http_code}\n' -X POST \
	  -H "Authorization: token $(TOKEN)" $(GITEA)/api/v1/repos/$(MIRROR)/mirror-sync

status:
	@kubectl -n argocd get application helpdesk-cloud \
	  -o custom-columns=APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
	@kubectl -n $(NS) get deployment helpdesk \
	  -o custom-columns=IMAGE:.spec.template.spec.containers[0].image,READY:.status.readyReplicas
	@kubectl -n $(NS) get pods -o wide
	@kubectl -n $(NS) get cluster.postgresql.cnpg.io helpdesk-cloud-db

logs:
	@kubectl -n $(NS) logs deployment/helpdesk --tail=50

restart:
	@kubectl -n $(NS) rollout restart deployment/helpdesk
	@kubectl -n $(NS) rollout status deployment/helpdesk --timeout=180s

env:
	@kubectl -n $(NS) get deployment helpdesk -o json \
	  | jq -r '.spec.template.spec.containers[0].env[] | "\(.name)\t\(if .valueFrom then "(from secret \(.valueFrom.secretKeyRef.name))" else .value end)"'
