
variable "region" {
  type        = string
  description = "AWS region"
  default     = "eu-west-2"
}

variable "vpc_name" {
  type        = string
  description = "EKS cluster name"
  default     = "k8tre-dev"
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
    "10.0.9.0/24", "10.0.10.0/24",
  ]
}

variable "private_subnets" {
  type        = list(string)
  description = "Private subnet CIDRs to create"
  default = [
    "10.0.3.0/24", "10.0.4.0/24",
    "10.0.11.0/24", "10.0.12.0/24",
  ]
}


terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.14"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.21"
    }

    http = {
      source  = "hashicorp/http"
      version = "~> 3.5"
    }
  }

  required_version = ">= 1.10.0"

  # Bootstrapping: Create the bucket using the ./bootstrap directory
  # Must match aws_s3_bucket.bucket in bootstrap/backend.tf
  backend "s3" {
    bucket       = "k8tre-tfstate-0123456789abcdef"
    key          = "tfstate/dev/k8tre-dev"
    region       = "eu-west-2"
    use_lockfile = true
  }
}

provider "aws" {
  region = "eu-west-2"
  default_tags {
    tags = {
      "owner" : "trevolution"
    }
  }
}

# Get IP of caller to optionally limit inbound connections
data "http" "myip" {
  url = "https://checkip.amazonaws.com/"
}

locals {
  allow_ips = [
    "${chomp(data.http.myip.response_body)}/32",
  ]
}


######################################################################
# VPC
######################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = var.vpc_name
  cidr = var.vpc_cidr
  # EKS requires at least two AZ (though node groups can be placed in just one)
  azs                = ["${var.region}a", "${var.region}b"]
  public_subnets     = var.public_subnets
  private_subnets    = var.private_subnets
  enable_nat_gateway = true
  single_nat_gateway = true

  # tags = {
  #   "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  # }

  # https://repost.aws/knowledge-center/eks-load-balancer-controller-subnets
  public_subnet_tags = {
    # "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {}
}

# Security group that allows clusters to access each other
resource "aws_security_group" "internal_cluster_access" {
  name_prefix = "internal_cluster_endpoint"
  vpc_id      = module.vpc.vpc_id
  description = "Internal cluster endpoint"

  // allows traffic from the SG itself
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }
}

######################################################################
# Main K8TRE Kubernetes
######################################################################

locals {
  allow_argocd_k8s_access = {
    description              = "Allow ArgoCD to access internal K8S endpoint"
    type                     = "ingress"
    from_port                = 443
    to_port                  = 443
    protocol                 = "tcp"
    source_security_group_id = aws_security_group.internal_cluster_access.id
  }
}

module "k8tre-eks" {
  source = "./k8tre-eks"
  # source = "git::https://github.com/k8tre/k8tre-infrastructure-aws.git?ref=main"

  cluster_name    = "k8tre-dev"
  vpc_id          = module.vpc.vpc_id
  private_subnets = slice(module.vpc.private_subnets, 0, 2)

  # k8s_version =

  # CIDRs that have access to the K8S API, e.g. `0.0.0.0/0`
  k8s_api_cidrs = local.allow_ips
  # CIDRs that have access to services running on K8S
  service_access_cidrs = local.allow_ips

  additional_security_groups = [aws_security_group.internal_cluster_access.id]

  # Allow ArgoCD to access K8S API
  cluster_security_group_additional_rules = {
    allow_argocd_k8s_access = local.allow_argocd_k8s_access
  }

  # number_azs        = 1
  # instance_type_wg1 = "t3a.2xlarge"
  # use_bottlerocket  = false
  root_volume_size = 200
  wg1_size         = 2
  wg1_max_size     = 2

  # For available addons see
  # https://docs.aws.amazon.com/eks/latest/userguide/workloads-add-ons-available-eks.html
  # additional_eks_addons = {}

  # autoupdate_ami = false
  # autoupdate_addons = false

  github_oidc_rolename = "k8tre-dev-github-oidc"
}


######################################################################
# ArgoCD K8TRE Kubernetes
######################################################################

module "k8tre-argocd-eks" {
  source = "./k8tre-eks"
  # source = "git::https://github.com/k8tre/k8tre-infrastructure-aws.git?ref=main"

  cluster_name    = "k8tre-dev-argocd"
  vpc_id          = module.vpc.vpc_id
  private_subnets = slice(module.vpc.private_subnets, 2, 4)

  # k8s_version =

  # CIDRs that have access to the K8S API, e.g. `0.0.0.0/0`
  k8s_api_cidrs = local.allow_ips
  # CIDRs that have access to services running on K8S
  service_access_cidrs = local.allow_ips

  additional_security_groups = [aws_security_group.internal_cluster_access.id]

  # number_azs        = 1
  instance_type_wg1 = "t3a.xlarge"
  # use_bottlerocket  = false
  # root_volume_size = 100
  wg1_size     = 1
  wg1_max_size = 1

  # autoupdate_ami = false
  # autoupdate_addons = false

  argocd_create_role            = true
  argocd_assume_eks_access_role = module.k8tre-eks.eks_access_role
}


output "kubeconfig_command_k8tre-dev" {
  description = "Create kubeconfig for k8tre-dev"
  value       = "aws eks update-kubeconfig --name ${module.k8tre-eks.cluster_name}"
}

output "kubeconfig_command_k8tre-argocd-dev" {
  description = "Create kubeconfig for k8tre-argocd-dev"
  value       = "aws eks update-kubeconfig --name ${module.k8tre-argocd-eks.cluster_name}"
}

output "service_access_prefix_list" {
  description = "ID of the prefix list that can access services running on K8s"
  value       = module.k8tre-eks.service_access_cidrs_prefix_list
}

output "k8tre_cluster_name" {
  description = "K8TRE dev cluster name"
  value       = module.k8tre-eks.cluster_name
}

output "k8tre_argocd_cluster_name" {
  description = "K8TRE dev cluster name"
  value       = module.k8tre-argocd-eks.cluster_name
}

output "k8tre_eks_access_role" {
  description = "K8TRE EKS deployment role ARN"
  value       = module.k8tre-eks.eks_access_role
}
