######################################################################
# Squid proxy

variable "vpc_id" {
  type        = string
  description = "VPC ID"
}

variable "public_subnets" {
  type        = list(string)
  description = "Subnet IDs"
}

variable "ecs_cluster" {
  type        = string
  description = "ECS Cluster name"
}

variable "ecs_discovery_id" {
  type        = string
  description = "ECS Cluster DNS Discovery ID"
}

variable "kms_key" {
  type        = string
  description = "KMS key ARN"
}

variable "squid_proxy_repository" {
  type        = string
  default     = "docker.io/manics/squid-filtering-proxy"
  description = "Squid proxy container repository"
}

variable "squid_proxy_version" {
  type        = string
  default     = "dev-amd64"
  description = "Squid proxy container version"
}

variable "squid_proxy_allowed_domains" {
  type = list(string)
  default = [
    "github.com",
    "ghcr.io",
  ]
  description = "Squid proxy allowed domains"
}
