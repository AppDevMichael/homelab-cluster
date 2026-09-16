# Namespaces + secrets that git-managed apps depend on.
# ArgoCD never sees these values; the charts reference them by name (existingSecret / operator-oauth).

resource "random_password" "grafana" {
  length  = 24
  special = false
}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged" # node-exporter needs hostPID/hostNetwork
    }
  }
}

resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  data = {
    admin-user     = "admin"
    admin-password = var.grafana_admin_password != "" ? var.grafana_admin_password : random_password.grafana.result
  }
}

resource "kubernetes_namespace_v1" "tailscale" {
  count = var.tailscale_oauth_client_id != "" ? 1 : 0
  metadata {
    name = "tailscale"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

# The tailscale-operator chart looks for this exact Secret when oauth.* values are unset.
resource "kubernetes_secret_v1" "tailscale_oauth" {
  count = var.tailscale_oauth_client_id != "" ? 1 : 0
  metadata {
    name      = "operator-oauth"
    namespace = kubernetes_namespace_v1.tailscale[0].metadata[0].name
  }
  data = {
    client_id     = var.tailscale_oauth_client_id
    client_secret = var.tailscale_oauth_client_secret
  }
}

# cert-manager (gitops/cert-manager) solves Let's Encrypt DNS-01 challenges with a Cloudflare token (Zone.DNS Edit).
resource "kubernetes_namespace_v1" "cert_manager" {
  count = var.cloudflare_api_token != "" ? 1 : 0
  metadata {
    name = "cert-manager"
  }
}

resource "kubernetes_secret_v1" "cloudflare_api_token" {
  count = var.cloudflare_api_token != "" ? 1 : 0
  metadata {
    name      = "cloudflare-api-token"
    namespace = kubernetes_namespace_v1.cert_manager[0].metadata[0].name
  }
  data = {
    api-token = var.cloudflare_api_token
  }
}

# Renovate (self-hosted CronJob, gitops/renovate) opens PRs on this repo with a fine-grained GitHub token.
resource "kubernetes_namespace_v1" "renovate" {
  count = var.renovate_github_token != "" ? 1 : 0
  metadata {
    name = "renovate"
  }
}

resource "kubernetes_secret_v1" "renovate_token" {
  count = var.renovate_github_token != "" ? 1 : 0
  metadata {
    name      = "renovate-token"
    namespace = kubernetes_namespace_v1.renovate[0].metadata[0].name
  }
  data = {
    RENOVATE_TOKEN = var.renovate_github_token
  }
}

# Alertmanager reads the SMTP password from this file mount (smtp_auth_password_file); the rest of the SMTP config is in git.
resource "kubernetes_secret_v1" "alertmanager_smtp" {
  count = var.smtp_password != "" ? 1 : 0
  metadata {
    name      = "alertmanager-smtp"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  data = {
    password = var.smtp_password
  }
}
