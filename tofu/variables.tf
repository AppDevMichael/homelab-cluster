variable "kubeconfig_path" {
  type    = string
  default = "../kubeconfig"
}

# ---- GitOps source ----
variable "git_repo_url" {
  description = "URL of THIS repo, as ArgoCD should clone it (https://github.com/you/opi-k8s.git or git@github.com:you/opi-k8s.git)"
  type        = string
}

variable "git_revision" {
  description = "Branch/tag ArgoCD tracks"
  type        = string
  default     = "main"
}

variable "git_ssh_private_key" {
  description = "Deploy key for a private repo (SSH URL). Leave empty for public HTTPS repos."
  type        = string
  default     = ""
  sensitive   = true
}

# ---- ArgoCD ----
variable "argocd_chart_version" {
  description = "argo/argo-cd chart version. Keep in sync with gitops/bootstrap/templates/argocd.yaml"
  type        = string
  default     = "10.4.2"
}

# ---- Secrets ArgoCD apps depend on (never go in git) ----
variable "grafana_admin_password" {
  type      = string
  default   = ""
  sensitive = true
}

variable "tailscale_oauth_client_id" {
  type      = string
  default   = ""
  sensitive = true
}

variable "tailscale_oauth_client_secret" {
  type      = string
  default   = ""
  sensitive = true
}

# ---- Backups / storage ----
variable "backup_key" {
  description = "Cluster backup passphrase — export BACKUP_KEY=$(scripts/backup-key.sh) and pass via TF_VAR_backup_key"
  type        = string
  sensitive   = true
}

variable "storagebox_user" {
  description = "Hetzner Storage Box user (TF_VAR_storagebox_user or tfvars)"
  type        = string
}

variable "storagebox_password" {
  description = "Storage Box password — used by Longhorn for SMB (SSH keys aren't an option for CIFS)"
  type        = string
  sensitive   = true
}
