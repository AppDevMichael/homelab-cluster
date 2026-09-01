# Bootstraps ArgoCD once. After this, ArgoCD manages itself from gitops/argocd/values.yaml
# (see gitops/bootstrap/templates/argocd.yaml). Bump versions in git, not here — the
# lifecycle block below stops Tofu from fighting ArgoCD over its own release.

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }
}

# Deploy key for private repos (optional)
resource "kubernetes_secret_v1" "argocd_repo" {
  count = var.git_ssh_private_key != "" ? 1 : 0
  metadata {
    name      = "repo-opi-k8s"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }
  data = {
    type          = "git"
    url           = var.git_repo_url
    sshPrivateKey = var.git_ssh_private_key
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  wait       = true
  timeout    = 600

  values = [
    file("${path.module}/../gitops/argocd/values.yaml"),
    # Root "app of apps": points ArgoCD at gitops/bootstrap in this repo.
    templatefile("${path.module}/root-app.yaml.tftpl", {
      repo_url = var.git_repo_url
      revision = var.git_revision
    }),
  ]

  lifecycle {
    ignore_changes = [version, values]
  }

  depends_on = [kubernetes_secret_v1.argocd_repo]
}
