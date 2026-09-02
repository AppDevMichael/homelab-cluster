# State lives IN the cluster, as a Secret in kube-system: locking built in, reachable from any
# machine with the kubeconfig, encrypted at rest by k3s (secrets-encryption) AND by OpenTofu
# below (so cluster-admin alone can't read the secrets inside the state).
#
# Why this works here: Ansible creates the cluster before Tofu ever runs, so Tofu can use it.
# Why it's fine for disaster recovery: a fresh cluster = empty state = "create everything",
# which is exactly what you want. Nothing Tofu manages needs to survive the cluster.
#
# Fresh machine → just `make argocd` (tofu init finds the state in the cluster).
# Moving here from local state: `make state-migrate` (tofu init -migrate-state).

terraform {
  backend "kubernetes" {
    secret_suffix = "opi-k8s" # Secret name: tfstate-default-opi-k8s
    namespace     = "kube-system"
    config_path   = "../kubeconfig"
  }

  encryption {
    key_provider "pbkdf2" "backup_key" {
      passphrase = var.backup_key # same key as backups — export BACKUP_KEY=$(scripts/backup-key.sh)
    }
    method "aes_gcm" "default" {
      keys = key_provider.pbkdf2.backup_key
    }
    state {
      method   = method.aes_gcm.default
      enforced = true # refuse to write unencrypted state, ever
    }
    plan {
      method   = method.aes_gcm.default
      enforced = true
    }
  }
}
