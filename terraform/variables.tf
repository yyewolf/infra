#######################
#      Kluster        #
#######################
variable "infomaniak" {
  description = "Infomaniak informations"
  type = object({
    cloud_id   = number
    project_id = number
  })
  nullable  = false
}

variable "cluster_name" {
  description = "Cluster name"
  type        = string
  nullable    = false
}

variable "cluster_region" {
  description = "Cluster region"
  type        = string
  default     = "dc4-a"
}

variable "cluster_type" {
  description = "Cluster type"
  type        = string
  default     = "shared"
}

variable "cluster_version" {
  description = "Cluster version"
  type        = string
  default     = "1.31"
}

variable "pool_name" {
  description = "Pool instance name"
  type        = string
  default     = "name"
}

variable "pool_type" {
  description = "Pool instance type"
  type        = string
  default     = "a1-ram2-disk20-perf1"
}

variable "pool_min" {
  description = "Minimum pool instance number"
  type        = number
  default     = 3
}

variable "pool_az" {
  description = "Pool instance availability zone"
  type        = string
  default     = "az-2"
}

#######################
#       Flux          #
#######################

variable "gpg_private_key" {
  description = "Path to the GPG private key"
}

variable "repository_url" {
  description = "URL of the Git repository"
}