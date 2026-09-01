output "argocd_url" {
  value = "http://argocd.<node-ip>.nip.io  (host set in gitops/argocd/values.yaml)"
}

output "argocd_initial_admin_password_cmd" {
  value = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "grafana_admin_password" {
  value     = kubernetes_secret_v1.grafana_admin.data["admin-password"]
  sensitive = true
}
