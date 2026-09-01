terraform {
  required_version = "~> 1.12.0" # stable 1.12 series

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.2" # v3 syntax: kubernetes = {...}, set = [{...}]
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38" # only used for namespaces + bootstrap secrets
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}
