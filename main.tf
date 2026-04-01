
# Get IP of caller to optionally limit inbound connections
data "http" "myip" {
  url = "https://checkip.amazonaws.com/"
}

locals {
  allow_ips = [
    for ip in var.allowed_cidrs :
    replace(ip, "/^myip$/", "${chomp(data.http.myip.response_body)}/32")
  ]
}


######################################################################
# VPC
######################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = var.name
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
  name_prefix = "internal-cluster-endpoint"
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

# This is not used in any Terraform resource, but can be referenced in
# non-terraform resources e.g. load-balancers
resource "aws_ec2_managed_prefix_list" "service_access_cidrs" {
  name           = "${var.name}-service-access-cidrs"
  address_family = "IPv4"
  max_entries    = 20

  dynamic "entry" {
    for_each = local.allow_ips
    content {
      cidr = entry.value
      # description =
    }
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

  deployment_stage = var.deployment_stage

  cluster_name    = var.name
  vpc_id          = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnets

  # k8s_version =

  # CIDRs that have access to the K8S API, e.g. `0.0.0.0/0`
  k8s_api_cidrs = local.allow_ips

  additional_security_groups = [aws_security_group.internal_cluster_access.id]

  # Allow ArgoCD to access K8S API
  cluster_security_group_additional_rules = {
    allow_argocd_k8s_access = local.allow_argocd_k8s_access
  }

  number_azs = var.number_availability_zones

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

  create_pod_identities = true
  hosted_zone_ids = concat(
    [module.dnsresolver.private-zone-id],
    module.dnsresolver.public-zone-id
  )

  github_oidc_rolename = var.enable_github_oidc ? "${var.name}-github-oidc" : null

  additional_admin_principals = var.additional_admin_principals
}


######################################################################
# ArgoCD K8TRE Kubernetes
######################################################################

module "k8tre-argocd-eks" {
  source = "./k8tre-eks"
  # source = "git::https://github.com/k8tre/k8tre-infrastructure-aws.git?ref=main"

  deployment_stage = var.deployment_stage

  cluster_name    = "${var.name}-argocd"
  vpc_id          = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnets

  # k8s_version =

  # CIDRs that have access to the K8S API, e.g. `0.0.0.0/0`
  k8s_api_cidrs = local.allow_ips

  additional_security_groups = [aws_security_group.internal_cluster_access.id]

  number_azs = var.number_availability_zones

  instance_type_wg1 = "t3a.xlarge"
  # use_bottlerocket  = false
  # root_volume_size = 100
  wg1_size     = 1
  wg1_max_size = 1

  # autoupdate_ami = false
  # autoupdate_addons = false
  create_pod_identities = false

  argocd_create_role            = true
  argocd_assume_eks_access_role = module.k8tre-eks.eks_access_role

  additional_admin_principals = var.additional_admin_principals
}

