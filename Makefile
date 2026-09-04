# All targets assume `mise install` has been run and .env exists (see .env.example).
SHELL := /bin/bash
# Derive the backup key only inside the recipes that need it (signing asks the SSH agent, which may prompt).
NEED_KEY = export BACKUP_KEY="$${BACKUP_KEY:-$$(scripts/backup-key.sh)}"; export TF_VAR_backup_key="$$BACKUP_KEY"; test -n "$$BACKUP_KEY" || { echo "BACKUP_KEY empty — is your SSH key in the agent?"; exit 1; }
PLAY = cd ansible && ansible-playbook
LIMITFLAG = $(if $(LIMIT),-l $(LIMIT),)

.PHONY: help deps lint bootstrap argocd check nodes apps key argocd-password grafana-password \
        backup-config backup-restore-config restore-volumes os-upgrade destroy state-show \
        kernel kernel-install kernel-clean spi-boot reboot

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

kernel:            ## build the custom vendor kernel (dm-crypt/iSCSI/CIFS, headless) in Docker → kernel/debs/
	scripts/build-kernel.sh

kernel-install:    ## install/upgrade kernel/debs/ on the nodes one at a time (drains if k3s is up); LIMIT=opi-2 for a canary
	$(PLAY) kernel.yml $(LIMITFLAG)

spi-boot:          ## u-boot → SPI NOR, /boot → NVMe, one node at a time; then pull the SD cards. LIMIT=opi-2 for a canary
	$(PLAY) spi-boot.yml $(LIMITFLAG)

kernel-clean:      ## delete the armbian/build checkout and its caches (~15 GB)
	rm -rf kernel/build

bootstrap:         ## nodes: kernel, prep, Tailscale, hardening, updates, k3s HA, restic backups
	$(NEED_KEY); $(PLAY) site.yml $(LIMITFLAG)

argocd:            ## bootstrap ArgoCD + secrets; ArgoCD deploys gitops/  (state lives in the cluster). APPROVE=1 skips the prompt
	$(NEED_KEY); cd tofu && tofu init -reconfigure && tofu apply $(if $(APPROVE),-auto-approve,)
	$(NEED_KEY); scripts/backup-config.sh backup || true

state-show:        ## where is the state and what's in it
	kubectl -n kube-system get secret tfstate-default-opi-k8s -o jsonpath='{.metadata.creationTimestamp}'; echo
	$(NEED_KEY); cd tofu && tofu state list

check:             ## cluster health: nodes, ArgoCD apps, pods, Longhorn + backup target, restic snapshot age, timers
	$(NEED_KEY); scripts/check.sh

nodes:             ## node status
	kubectl get nodes -o wide

apps:              ## ArgoCD application status
	kubectl -n argocd get applications

argocd-password:
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

grafana-password:
	@$(NEED_KEY); cd tofu && tofu output -raw grafana_admin_password; echo

backup-config:     ## push tofu state/tfvars/kubeconfigs to the Storage Box (encrypted)
	$(NEED_KEY); scripts/backup-config.sh backup

backup-restore-config: ## pull them back (disaster recovery step 1)
	$(NEED_KEY); scripts/backup-config.sh restore

restore-volumes:   ## recreate Longhorn volumes + PV/PVCs from the latest backups (disaster recovery step 3)
	scripts/restore-longhorn-volumes.sh

reboot:            ## rolling drain → reboot → uncordon, one node at a time; LIMIT=opi-2 for one node
	$(PLAY) reboot.yml $(LIMITFLAG)

os-upgrade:        ## rolling apt full-upgrade (Armbian kernel etc.), one node at a time; LIMIT=opi-2 for one node
	$(PLAY) upgrade-os.yml $(LIMITFLAG)

destroy:           ## remove ArgoCD + bootstrap secrets (nodes and Longhorn data on disk untouched)
	$(NEED_KEY); cd tofu && tofu destroy
