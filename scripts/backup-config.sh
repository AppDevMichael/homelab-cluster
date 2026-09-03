#!/usr/bin/env bash
# Backs up the bits that live only on your laptop to the Storage Box (restic, encrypted):
# tofu tfvars + lock file, kubeconfigs, the Storage Box SSH key, .env.  (Tofu STATE lives in the cluster.)
set -euo pipefail
cd "$(dirname "$0")/.."
: "${BACKUP_KEY:?export BACKUP_KEY=\$(scripts/backup-key.sh)}"
: "${STORAGEBOX_USER:?}" "${STORAGEBOX_HOST:?}"

export RESTIC_PASSWORD="$BACKUP_KEY"
export RESTIC_REPOSITORY="sftp:${STORAGEBOX_USER}@${STORAGEBOX_HOST}:opi-k8s/restic"   # relative: sub-accounts are chrooted
SSH_CMD="ssh -p 23 -i ansible/secrets/storagebox_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new ${STORAGEBOX_USER}@${STORAGEBOX_HOST} -s sftp"
r() { restic -o "sftp.command=$SSH_CMD" "$@"; }

r snapshots >/dev/null 2>&1 || r init
case "${1:-backup}" in
  backup)
    r backup --tag laptop-config \
      tofu/terraform.tfvars tofu/.terraform.lock.hcl \
      kubeconfig kubeconfig-tailscale ansible/secrets .env kernel/debs 2>/dev/null || true
    r forget --tag laptop-config --keep-last 10 --prune ;;
  restore)
    r restore latest --tag laptop-config --target . ;;
  snapshots)
    r snapshots ;;
  *) echo "usage: $0 [backup|restore|snapshots]"; exit 1 ;;
esac
