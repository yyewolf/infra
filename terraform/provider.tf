# Define required providers
terraform {
  required_version = ">= 0.14.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.3.0"
    }
    cloudinit = {
      source = "hashicorp/cloudinit"
      version = "2.3.7"
    }
    infomaniak = {
      source = "Infomaniak/infomaniak"
      version = "1.2.1"
    }
  }
}

# Configure the OpenStack Provider
provider "openstack" {
  cloud = "openstack"
}
