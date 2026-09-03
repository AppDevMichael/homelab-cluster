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
  count = var.git_ssh_private_key_file != "" ? 1 : 0
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
    sshPrivateKey = file(pathexpand(var.git_ssh_private_key_file))
  }
}

locals {
  argocd_chart_version = regex("targetRevision: ([0-9.]+)", file("${path.module}/../gitops/bootstrap/templates/argocd.yaml"))[0]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = local.argocd_chart_version # single pin: gitops/bootstrap/templates/argocd.yaml (Renovate bumps it there)
  wait       = true
  timeout    = 600

  values = [file("${path.module}/../gitops/argocd/values.yaml")]

  lifecycle {
    ignore_changes = [version, values]
  }

  depends_on = [kubernetes_secret_v1.argocd_repo]
}

# Root "app of apps": points ArgoCD at gitops/bootstrap in this repo. A separate release of the argocd-apps
# chart, ordered after argo-cd: the Application CRD must exist before Helm can validate this manifest
# (rendering it as extraObjects inside the argo-cd release fails on a fresh cluster for that reason).
resource "helm_release" "root_app" {
  name       = "argocd-root"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version
  wait       = false # ArgoCD reconciles it; nothing to wait for here

  values = [
    templatefile("${path.module}/root-app.yaml.tftpl", {
      repo_url = var.git_repo_url
      revision = var.git_revision
    }),
  ]

  lifecycle {
    ignore_changes = [version, values] # gitops/bootstrap/templates/root.yaml owns it from then on
  }

  depends_on = [helm_release.argocd]
}
