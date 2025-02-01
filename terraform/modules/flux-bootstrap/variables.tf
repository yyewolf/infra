variable "cluster_config" {
  description = "The raw Kubernetes cluster configuration"
  type        = string
}

variable "repository_url" {
  description = "URL of the Git repository"
  type = string
}