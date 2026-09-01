# All targets assume `mise install` has been run and .env exists (see .env.example).
SHELL := /bin/bash
export BACKUP_KEY ?= $(shell scripts/backup-key.sh 2>/dev/null)
export TF_VAR_backup_key := $(BACKUP_KEY)
export TF_VAR_storagebox_user := $(STORAGEBOX_USER)

.PHONY: help deps lint bootstrap argocd all nodes apps key argocd-password grafana-password \
        backup-config backup-restore-config restore-volumes os-upgrade destroy state-migrate state-show

help:
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | column -t -s$$'\t'

deps:              ## install all CLI tools (collections are bundled with the ansible package)
	mise install

lint:              ## static checks
	cd ansible && ansible-lint site.yml upgrade-os.yml || true
	cd tofu && tofu fmt -check -recursive && tofu validate
	helm lint gitops/bootstrap
	kustomize build gitops/system-upgrade >/dev/null

key:               ## print the derived backup key (store it in your password manager too!)
	@scripts/backup-key.sh

bootstrap:         ## nodes: prep, Tailscale, hardening, updates, k3s HA, restic backups
	@test -n "$(BACKUP_KEY)" || (echo "BACKUP_KEY empty — is your SSH key in the agent?"; exit 1)
	cd ansible && ansible-playbook site.yml

argocd:            ## bootstrap ArgoCD + secrets; ArgoCD deploys gitops/  (state lives in the cluster)
	@test -n "$(BACKUP_KEY)" || (echo "BACKUP_KEY empty — is your SSH key in the agent?"; exit 1)
	cd tofu && tofu init && tofu apply
	scripts/backup-config.sh backup || true

state-migrate:     ## one-off: move an existing local terraform.tfstate into the cluster backend
	@test -n "$(BACKUP_KEY)" || (echo "BACKUP_KEY empty"; exit 1)
	cd tofu && tofu init -migrate-state && rm -f terraform.tfstate terraform.tfstate.backup

state-show:        ## where is the state and what's in it
	kubectl -n kube-system get secret tfstate-default-opi-k8s -o jsonpath='{.metadata.creationTimestamp}'; echo
	cd tofu && tofu state list

all: deps bootstrap argocd

nodes:             ## node status
	kubectl get nodes -o wide

apps:              ## ArgoCD application status
	kubectl -n argocd get applications

argocd-password:
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

grafana-password:
	@cd tofu && tofu output -raw grafana_admin_password; echo

backup-config:     ## push tofu state/tfvars/kubeconfigs to the Storage Box (encrypted)
	scripts/backup-config.sh backup

backup-restore-config: ## pull them back (disaster recovery step 1)
	scripts/backup-config.sh restore

restore-volumes:   ## recreate Longhorn volumes + PV/PVCs from the latest backups (disaster recovery step 3)
	scripts/restore-longhorn-volumes.sh

os-upgrade:        ## rolling apt full-upgrade (Armbian kernel etc.), one node at a time
	cd ansible && ansible-playbook upgrade-os.yml

destroy:           ## remove ArgoCD + bootstrap secrets (nodes and Longhorn data on disk untouched)
	cd tofu && tofu destroy
