output "grafana_admin_password" {
  value     = kubernetes_secret_v1.grafana_admin.data["admin-password"]
  sensitive = true
}
