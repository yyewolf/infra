resource "infomaniak_kaas" "kluster" {
  public_cloud_id         = var.infomaniak.cloud_id
  public_cloud_project_id = var.infomaniak.project_id

  name               = var.cluster_name
  pack_name          = var.cluster_type
  kubernetes_version = var.cluster_version
  region             = var.cluster_region
}

output "kluster_kubeconfig" {
  value = infomaniak_kaas.kluster.kubeconfig
  sensitive = true
}
resource "infomaniak_kaas_instance_pool" "rondin" {
  public_cloud_id         = infomaniak_kaas.kluster.public_cloud_id
  public_cloud_project_id = infomaniak_kaas.kluster.public_cloud_project_id
  kaas_id                 = infomaniak_kaas.kluster.id

  name              = "rondin"
  flavor_name       = var.pool_type
  min_instances     = var.pool_min
  availability_zone = "az-1"
}

resource "infomaniak_kaas_instance_pool" "rondeux" {
  public_cloud_id         = infomaniak_kaas.kluster.public_cloud_id
  public_cloud_project_id = infomaniak_kaas.kluster.public_cloud_project_id
  kaas_id                 = infomaniak_kaas.kluster.id

  name              = "rondeux"
  flavor_name       = var.pool_type
  min_instances     = var.pool_min
  availability_zone = "az-2"
}

module "flux-bootstrap" {
  source         = "./modules/flux-bootstrap"
  repository_url = var.repository_url
  gpg_private_key = var.gpg_private_key

  cluster_config = infomaniak_kaas.kluster.kubeconfig
}
