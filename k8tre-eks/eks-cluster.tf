# https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/19.15.2
# Full example:
# https://github.com/terraform-aws-modules/terraform-aws-eks/blame/v19.14.0/examples/complete/main.tf
# https://github.com/terraform-aws-modules/terraform-aws-eks/blob/v19.14.0/docs/compute_resources.md

# This is complicated because we want to disable the default AWS vpc-cni so we can
# install Cilium, but the nodegroup will fail to become ready without a CNI.
# https://cilium.io/blog/2025/06/19/eks-eni-install/
#
# It should be possible to keep the AWS vpc-cni and chain the Cilium CNI
# https://cilium.io/blog/2025/07/08/byonci-overlay-install/
#
# but this fails when Gateway is enabled:
# https://github.com/cilium/cilium/issues/33685
#
# https://hackmd.io/@eCHO-live/138

data "aws_caller_identity" "current" {}

locals {
  aws_account_id = data.aws_caller_identity.current.account_id
  admin_principals = merge({
    # Anyone in the AWS account with sufficient permissions can access the cluster
    aws_admins = "arn:aws:iam::${local.aws_account_id}:root"
    # Optional GitHub OIDC role
    github_oidc = var.github_oidc_rolename == null ? null : "arn:aws:iam::${local.aws_account_id}:role/${var.github_oidc_rolename}"
    # ARN can't be resolved until after the role is created
    # eks_access = aws_iam_role.eks_access.arn
    eks_access = "arn:aws:iam::${local.aws_account_id}:role/${var.cluster_name}-eks-access"
    },
    var.additional_admin_principals
  )
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

  enable_irsa = false

  # Disable all addons since we don't yet have a nodegroup to run them on
  addons = {}

  # Send control plane logs to CloudWatch (is this the default anyway?)
  # https://docs.aws.amazon.com/eks/latest/userguide/control-plane-logs.html
  enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]
  cloudwatch_log_group_retention_in_days = 90
  create_cloudwatch_log_group            = true

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

# K8S Gateway CRDs: Cilium Helm chart detects whether Gateway CRDs are present
# so CRDs must be installed first

data "http" "gateway_standard_crds" {
  url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${var.gateway_api_version}/standard-install.yaml"
}

# Need to strip out status field
# https://github.com/hashicorp/terraform-provider-kubernetes/issues/2739
# https://github.com/hashicorp/terraform-provider-kubernetes/issues/1428#issuecomment-3053948214

locals {
  gateway_crds = provider::kubernetes::manifest_decode_multi(data.http.gateway_standard_crds.response_body)
  gateway_standard_crds_removed_status = [
    for manifest in local.gateway_crds : { for k, v in manifest : k => v if k != "status" }
  ]

  gateway_manifests = flatten([
    var.deployment_stage >= 1 ? [local.gateway_standard_crds_removed_status] : []
  ])
}

resource "kubernetes_manifest" "gateway_crds" {
  for_each = {
    for manifest in local.gateway_manifests :
    "${manifest.kind}--${manifest.metadata.name}" => manifest
  }

  manifest = each.value
}

resource "helm_release" "cilium" {
  count      = (var.deployment_stage >= 1) ? 1 : 0
  depends_on = [kubernetes_manifest.gateway_crds]

  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"

  # Will fail because on the first run there are no nodes
  wait = false

  # Azure values for comparison
  # https://github.com/karectl/kare-azure-infrastructure/blob/09f192fa4be77a10e1e93e82e32bb860ddea0a4c/modules/cluster-gateway/main.tf#L101


  set = [
    # pass the cluster_endpoint to the helm values so that we can configure kube-proxy replacement
    {
      name  = "k8sServiceHost"
      value = trimprefix(module.eks.cluster_endpoint, "https://")
    },
    {
      name  = "k8sServicePort"
      value = "443"
    },

    # {
    #   name  = "cni.chainingMode"
    #   value = "aws-cni"
    # },
    # {
    #   name  = "cni.exclusive"
    #   value = "false"
    # },

    # {
    #   name  = "enableIPv4Masquerade"
    #   value = "true"
    # },

    # {
    #   name  = "ipv4NativeRoutingCIDR"
    #   # value = data.terraform_remote_state.k8tre.outputs.vpc_cidr
    #   value = "0.0.0.0/0"
    # },
    {
      name  = "eni.enabled"
      value = "true"
    },
    {
      name  = "ipam.mode"
      value = "eni"
    },
    {
      name  = "kubeProxyReplacement"
      value = "true"
    },
    {
      name  = "routingMode"
      value = "native"
    },

    {
      name  = "gatewayAPI.enabled"
      value = "true"
    },

    {
      name  = "hubble.enabled"
      value = "true"
    },
    {
      name  = "hubble.ui.enabled"
      value = "true"
    },
    {
      name  = "hubble.relay.enabled"
      value = "true"
    }
  ]
}


# https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/21.15.1/submodules/eks-managed-node-group
module "eks_nodegroup" {
  count = (var.deployment_stage >= 1) ? 1 : 0

  # Need a CNI otherwise node group never becomes ready and terraform fails
  depends_on = [helm_release.cilium]

  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "21.15.1"

  cluster_name   = module.eks.cluster_name
  name           = "${module.eks.cluster_name}-wg1"
  instance_types = [var.instance_type_wg1]
  ami_type       = var.use_bottlerocket ? "BOTTLEROCKET_x86_64" : "AL2023_x86_64_STANDARD"

  use_latest_ami_release_version = var.autoupdate_ami

  cluster_service_cidr = module.eks.cluster_service_cidr

  # https://github.com/terraform-aws-modules/terraform-aws-eks/blob/v21.15.1/modules/eks-managed-node-group/README.md?plain=1#L17-L19
  // The following variables are necessary if you decide to use the module outside of the parent EKS module context.
  // Without it, the security groups of the nodes are empty and thus won't join the cluster.

  # Except including cluster_primary_security_group_id and node_security_group_id
  # leads to the load balancer failing, because it expects only one security group
  # tagged with the cluster attached to each node but both these groups are tagged
  # cluster_primary_security_group_id = module.eks.cluster_primary_security_group_id
  vpc_security_group_ids = concat([
    module.eks.node_security_group_id,
    aws_security_group.all_worker_mgmt.id,
    aws_security_group.worker_group_all.id,
  ], var.additional_security_groups)


  # additional_userdata = "echo foo bar"

  desired_size = var.wg1_size
  min_size     = 1
  max_size     = var.wg1_max_size

  labels = {
    cluster = var.cluster_name
  }

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
    # Cilium ENI requires these:
    # https://cilium.io/blog/2025/06/19/eks-eni-install/
    eksworker = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    ekscni    = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    ecr       = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  }
}


# Now that the nodegroup is ready we can deploy addons

resource "aws_eks_addon" "coredns" {
  count      = (var.deployment_stage >= 1) ? 1 : 0
  depends_on = [module.eks_nodegroup]

  cluster_name                = module.eks.cluster_name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
}

resource "aws_eks_addon" "eks-pod-identity-agent" {
  count      = (var.deployment_stage >= 1) ? 1 : 0
  depends_on = [module.eks_nodegroup]

  cluster_name                = module.eks.cluster_name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
}

resource "aws_eks_addon" "aws-ebs-csi-driver" {
  count      = (var.deployment_stage >= 1) ? 1 : 0
  depends_on = [module.eks_nodegroup]

  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"

  pod_identity_association {
    role_arn        = module.aws_ebs_csi_pod_identity.iam_role_arn
    service_account = "ebs-csi-controller-sa"
  }
}

resource "aws_eks_addon" "aws-efs-csi-driver" {
  count      = (var.deployment_stage >= 1) ? 1 : 0
  depends_on = [module.eks_nodegroup]

  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-efs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"

  pod_identity_association {
    role_arn        = module.aws_efs_csi_pod_identity.iam_role_arn
    service_account = "efs-csi-controller-sa"
  }
}


data "aws_eks_cluster_auth" "k8tre" {
  name = var.cluster_name
}
