# https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/19.15.2
# Full example:
# https://github.com/terraform-aws-modules/terraform-aws-eks/blame/v19.14.0/examples/complete/main.tf
# https://github.com/terraform-aws-modules/terraform-aws-eks/blob/v19.14.0/docs/compute_resources.md

data "aws_caller_identity" "current" {}

locals {
  aws_account_id = data.aws_caller_identity.current.account_id
  admin_principals = {
    # Anyone in the AWS account with sufficient permissions can access the cluster
    aws_admins = "arn:aws:iam::${local.aws_account_id}:root"
    # Optional GitHub OIDC role
    github_oidc = var.github_oidc_rolename == null ? null : "arn:aws:iam::${local.aws_account_id}:role/${var.github_oidc_rolename}"
    # ARN can't be resolved until after the role is created
    # eks_access = aws_iam_role.eks_access.arn
    eks_access = "arn:aws:iam::${local.aws_account_id}:role/${var.cluster_name}-eks-access"
  }
}

# This assumes the EKS service linked role is already created (or the current user has permissions to create it)
module "eks" {
  source             = "terraform-aws-modules/eks/aws"
  version            = "21.15.1"
  name               = var.cluster_name
  kubernetes_version = var.k8s_version
  subnet_ids         = var.private_subnets

  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.k8s_api_cidrs

  security_group_additional_rules = var.cluster_security_group_additional_rules

  vpc_id = var.vpc_id

  # Allow all allowed roles to access the KMS key
  kms_key_enable_default_policy = true
  # This duplicates the above, but the default is the current user/role so this will avoid
  # a deployment change when run by different users/roles
  kms_key_administrators = [
    "arn:aws:iam::${local.aws_account_id}:root",
  ]

  # TODO Is this needed?
  enable_irsa = true

  # https://docs.aws.amazon.com/eks/latest/userguide/workloads-add-ons-available-eks.html
  addons = merge(
    {
      coredns = {
        most_recent = var.autoupdate_addons
      }
      eks-pod-identity-agent = {
        before_compute = true
        most_recent    = var.autoupdate_addons
      }
      kube-proxy = {
        most_recent = var.autoupdate_addons
      }
      vpc-cni = {
        before_compute = true
        most_recent    = var.autoupdate_addons
      }

      aws-ebs-csi-driver = {
        most_recent = var.autoupdate_addons
        pod_identity_association = [{
          role_arn        = module.aws_ebs_csi_pod_identity.iam_role_arn
          service_account = "ebs-csi-controller-sa"
        }]
      }
      aws-efs-csi-driver = {
        most_recent = var.autoupdate_addons
        pod_identity_association = [{
          role_arn        = module.aws_efs_csi_pod_identity.iam_role_arn
          service_account = "efs-csi-controller-sa"
        }]
      }
    },
    var.additional_eks_addons
  )

  # # Send control plane logs to CloudWatch (is this the default anyway?)
  # # https://docs.aws.amazon.com/eks/latest/userguide/control-plane-logs.html
  # enabled_log_types = [
  #   "api",
  #   "audit",
  #   "authenticator",
  #   "controllerManager",
  #   "scheduler",
  # ]
  # cloudwatch_log_group_retention_in_days = 90
  # create_cloudwatch_log_group            = true

  eks_managed_node_groups = {
    worker_group_1 = {
      name           = "${var.cluster_name}-wg1"
      instance_types = [var.instance_type_wg1]
      ami_type       = var.use_bottlerocket ? "BOTTLEROCKET_x86_64" : "AL2023_x86_64_STANDARD"

      use_latest_ami_release_version = var.autoupdate_ami

      # additional_userdata = "echo foo bar"
      vpc_security_group_ids = concat([
        aws_security_group.all_worker_mgmt.id,
        aws_security_group.worker_group_all.id,
      ], var.additional_security_groups)

      desired_size = var.wg1_size
      min_size     = 1
      max_size     = var.wg1_max_size

      # Disk space can't be set with the default custom launch template
      # disk_size = 100
      block_device_mappings = {
        root = {
          # https://github.com/bottlerocket-os/bottlerocket/discussions/2011
          device_name = var.use_bottlerocket ? "/dev/xvdb" : "/dev/xvda"
          ebs = {
            # Uses default alias/aws/ebs key
            encrypted   = true
            volume_size = var.root_volume_size
            volume_type = "gp3"
          }
        }
      }

      subnet_ids = slice(var.private_subnets, 0, var.number_azs)

      capacity_type = "ON_DEMAND"
      iam_role_additional_policies = {
        ssmcore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
    },
    # Add more worker groups here
  }

  enable_cluster_creator_admin_permissions = true

  access_entries = {
    for key, principal in local.admin_principals :
    key => {
      principal_arn = principal
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
    if principal != null
  }
}

data "aws_eks_cluster_auth" "k8tre" {
  name = var.cluster_name
}
