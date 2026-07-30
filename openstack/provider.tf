terraform {
  required_version = ">= 1.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.0"
    }
  }
}

provider "openstack" {
  cloud = var.openstack_cloud
}
