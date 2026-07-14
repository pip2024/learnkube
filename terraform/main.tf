terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
  }
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

resource "helm_release" "learnkube" {
  name       = "learnkube"
  chart      = "${path.module}/../helm/learnkube"
  namespace  = var.namespace

  set {
    name  = "replicaCount"
    value = var.replica_count
  }

  set {
    name  = "image.repository"
    value = var.image_repository
  }

  set {
    name  = "image.tag"
    value = var.image_tag
  }

  set {
    name  = "appVersion"
    value = var.image_tag
  }
}
