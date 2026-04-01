
variable "deployment_stage" {
  type        = number
  default     = 3
  description = <<EOT
  Multi-stage deployment step.
  This is necessary because Terraform needs to resolve some resources before
  running, but those resource amy not exist yet.
  For the first deployment you must step through these starting at
  '-var deployment_stage=0', then '-var deployment_stage=1'.
  Future deployment can use the highest number (default).
  EOT
  validation {
    condition     = var.deployment_stage >= 0 && var.deployment_stage <= 3
    error_message = "deployment_stage must be one of [0, 1, 2, 3]"
  }
}

variable "name" {
  type        = string
  description = "Name used for most resources"
  default     = "k8tre-dev"
}

variable "region" {
  type        = string
  description = "AWS region"
  default     = "eu-west-2"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR to create"
  default     = "10.0.0.0/16"
}

variable "public_subnets" {
  type        = list(string)
  description = "Public subnet CIDRs to create"
  default = [
    "10.0.1.0/24", "10.0.2.0/24",
  ]
}

variable "private_subnets" {
  type        = list(string)
  description = "Private subnet CIDRs to create. These IPs are used by EKS pods so make it large!"
  default = [
    "10.0.64.0/18", "10.0.128.0/18",
  ]
}

variable "number_availability_zones" {
  type        = number
  default     = 1
  description = <<-EOT
  Number of availability zones to use for EKS.
  EBS volumes are tied to a single AZ, so if you have multiple AZs you must
  ensure you always have sufficient nodes in all AZs to run all pods
  that use EBS.
  EOT
}

variable "allowed_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to access K8TRE ('myip' is dynamically replaced by your current IP)"
  default     = ["myip"]
}

variable "additional_admin_principals" {
  type        = map(string)
  description = "Additional EKS admin principals"
  default     = {}
}

variable "efs_token" {
  type        = string
  description = "EFS name creation token, if null default to var.name"
  default     = null
}

variable "enable_github_oidc" {
  type        = bool
  description = "Create GitHub OIDC role"
  default     = false
}



variable "dns_domain" {
  type        = string
  default     = "k8tre.internal"
  description = "DNS domain"
}

variable "create_public_zone" {
  type        = bool
  default     = false
  description = "Create public DNS zone"
}

variable "request_certificate" {
  type        = string
  default     = "selfsigned"
  description = <<-EOT
  Request an ACM certificate (requires manual DNS validation),
  create a self-signed certificate,
  or none (fully manage certificate yourself)
  EOT
  validation {
    condition     = contains(["acm", "selfsigned", "none"], var.request_certificate)
    error_message = "Must be one of [acm, selfsigned, none]"
  }
}

variable "k8tre_cluster_labels" {
  type = map(string)
  default = {
    environment  = "dev"
    secret-store = "aws"
    vendor       = "aws"
    skip-metallb = "true"
    external-dns = "aws"
    # These are automatically set from other variables:
    # cluster-name
    # external-domain
    # region
  }
  description = "Argocd labels applied to K8TRE cluster"
}

variable "k8tre_cluster_label_overrides" {
  type        = map(string)
  default     = {}
  description = "Additional labels merged with k8tre_cluster_labels and applied to K8TRE cluster"
}

variable "argocd_version" {
  type        = string
  default     = "9.4.15"
  description = "ArgoCD Helm chart version"
}

variable "install_k8tre" {
  type        = bool
  default     = true
  description = "Install K8TRE root app-of-apps"
}

variable "k8tre_github_repo" {
  type        = string
  default     = "k8tre/k8tre"
  description = "K8TRE GitHub organisation and repository to install"
}

variable "k8tre_github_ref" {
  type        = string
  default     = "main"
  description = "K8TRE git ref (commit/branch/tag)"
}
