locals {
  gpg_private_key = file(var.gpg_private_key)
}

resource "helm_release" "this" {
  name = "flux2"

  repository = "https://fluxcd-community.github.io/helm-charts"
  chart      = "flux2"

  namespace        = "flux-system"
  create_namespace = true
  wait             = true
}


resource "kubernetes_secret_v1" "this" {
  metadata {
    name      = "sops-gpg"
    namespace = "flux-system"
  }

  data = {
    "sops.asc" = local.gpg_private_key
  }

  depends_on = [helm_release.this]
}


resource "helm_release" "sync" {
  name = "infra"

  repository = "https://fluxcd-community.github.io/helm-charts"
  chart      = "flux2-sync"

  namespace = "flux-system"
  wait      = true

  ## Git Repository
  set = [
    {
      name  = "gitRepository.spec.url"
      value = var.repository_url
    },
    {
      name  = "gitRepository.spec.interval"
      value = "5m"
    },
    {
      name  = "gitRepository.spec.ref.branch"
      value = "main"
    },
    {
      name  = "gitRepository.spec.recurseSubmodules"
      value = true
    },
    {
      name  = "kustomization.spec.interval"
      value = "5m"
    },
    {
      name  = "kustomization.spec.prune"
      value = "true"
    },
    {
      name  = "kustomization.spec.wait"
      value = "false"
    },
    {
      name  = "kustomization.spec.path"
      value = "flux"
    },
    {
      name = "kustomization.spec.decryption.provider"
      value = "sops"
    },
    {
      name  = "kustomization.spec.decryption.secretRef.name"
      value = "sops-gpg"
    }
  ]

  depends_on = [kubernetes_secret_v1.this]
}
