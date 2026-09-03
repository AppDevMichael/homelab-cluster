# Both providers read KUBE_CONFIG_PATH (exported by mise; kubeconfig-tailscale by default).
provider "kubernetes" {}

provider "helm" {
  kubernetes = {}
}
