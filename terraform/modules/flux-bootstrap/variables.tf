variable "cluster_config" {
  description = "The raw Kubernetes cluster configuration"
  type        = string
}

variable "repository_url" {
  description = "URL of the Git repository"
  type = string
}

variable "gpg_private_key" {
  description = "Path to the GPG private key"
  type = string
}