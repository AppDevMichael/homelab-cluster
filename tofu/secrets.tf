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
