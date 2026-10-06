terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
  }
}


provider "kubernetes" {
  config_path    = "./.tmp/config.yml"
  config_context = "kind-kind"
}


provider "helm" {
  kubernetes = {
    config_path    = "./.tmp/config.yml"
    config_context = "kind-kind"
  }
}

variable "cert_manager_version" {
  type        = string
  description = "cert-manager chart version"
  nullable    = true
  default     = null
}

variable "haproxy_version" {
  type        = string
  description = "haproxy chart version"
  nullable    = true
  default     = null
}

resource "helm_release" "cert-manager" {
  name       = "jetstack/cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"

  create_namespace = true
  namespace        = "cert-manager"
  version          = var.cert_manager_version

  atomic = true

  values = [
    yamlencode({
      crds = {
        enabled = true
      }
    })
  ]
}

resource "helm_release" "haproxy" {
  name       = "haproxytech/kubernetes-ingress"
  repository = "https://haproxytech.github.io/helm-charts"
  chart      = "kubernetes-ingress"

  create_namespace = true
  namespace        = "haproxy-controller"
  version          = var.cert_manager_version

  atomic = true

  values = [
    yamlencode({
      controller = {
        service = {
          externalTrafficPolicy = "Local"
          type                  = "NodePort"
          nodePorts = {
            http  = 32080
            https = 32443
          }
          enablePorts = {
            quic = false
          }
        }
      }
    })
  ]
}


locals {
  rabbitmq_cluster_operator_yaml = provider::kubernetes::manifest_decode_multi(file("./.tmp/rabbitmq-cluster-operator.yml"))
  rabbitmq_cluster_operator_manifests = {
    for manifest in local.rabbitmq_cluster_operator_yaml :
    "${manifest.kind}--${manifest.metadata.name}" => manifest
  }

  scylla_cluster_operator_yaml = provider::kubernetes::manifest_decode_multi(file("./.tmp/scylla-cluster-operator.yml"))
  scylla_cluster_operator_manifests = {
    for manifest in local.scylla_cluster_operator_yaml :
    "${manifest.kind}--${manifest.metadata.name}" => manifest
  }
}

resource "kubernetes_manifest" "rabbitmq-cluster-operator" {
  for_each = local.rabbitmq_cluster_operator_manifests
  manifest = each.value

  wait {
    rollout = true
  }

  timeouts {
    create = "300s"
    update = "300s"
    delete = "300s"
  }
}

resource "kubernetes_manifest" "scylla-cluster-operator" {
  for_each = local.scylla_cluster_operator_manifests
  manifest = each.value

  depends_on = [helm_release.cert-manager]

  wait {
    rollout = true
  }

  timeouts {
    create = "300s"
    update = "300s"
    delete = "300s"
  }
}
