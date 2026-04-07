# EKS pod identities for Kubernetes Service Accounts

locals {
  create_pod_identities            = var.create_pod_identities ? 1 : 0
  create_external_dns_pod_identity = (var.create_pod_identities && length(var.hosted_zone_ids) > 0) ? 1 : 0
}

######################################################################
# Built in policies
# https://registry.terraform.io/modules/terraform-aws-modules/eks-pod-identity/aws/latest

module "eks_pod_identity_load_balancer" {
  source                          = "terraform-aws-modules/eks-pod-identity/aws"
  version                         = "2.7.0"
  name                            = "${module.eks.cluster_name}-aws-lb-controller"
  attach_aws_lb_controller_policy = true

  # Associate identity with the ServiceAccount that will be created by the
  # aws-load-balancer-controller Helm chart
  association_defaults = {
    namespace       = "loadbalancer"
    service_account = "aws-load-balancer-controller"
  }

  associations = {
    cluster1 = {
      cluster_name = module.eks.cluster_name
    }
  }
}

module "aws_ebs_csi_pod_identity" {
  source                    = "terraform-aws-modules/eks-pod-identity/aws"
  version                   = "2.7.0"
  name                      = "aws-ebs-csi"
  attach_aws_ebs_csi_policy = true
  aws_ebs_csi_kms_arns      = ["arn:aws:kms:*:*:key/*"]
}

module "aws_efs_csi_pod_identity" {
  source                    = "terraform-aws-modules/eks-pod-identity/aws"
  version                   = "2.7.0"
  name                      = "aws-efs-csi"
  attach_aws_efs_csi_policy = true
}

module "cluster_autoscaler_pod_identity" {
  source                           = "terraform-aws-modules/eks-pod-identity/aws"
  version                          = "2.7.0"
  count                            = local.create_pod_identities
  name                             = "cluster-autoscaler"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [module.eks.cluster_name]

  # Associate identity with the ServiceAccount that will be created by the
  # cluster-autoscaler Helm chart
  association_defaults = {
    namespace       = "kube-system"
    service_account = "cluster-autoscaler-sa"
  }

  associations = {
    cluster1 = {
      cluster_name = module.eks.cluster_name
    }
  }
}

module "external_dns_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.7.0"

  count = local.create_external_dns_pod_identity

  name = "external-dns"

  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = formatlist("arn:aws:route53:::hostedzone/%s", var.hosted_zone_ids)

  associations = {
    cluster1 = {
      cluster_name    = module.eks.cluster_name
      namespace       = "externaldns"
      service_account = "externaldns-sa"
    }
  }
}

module "external_secrets_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.7.0"
  count   = local.create_pod_identities

  name = "external-secrets"

  # TODO: tighten up these policies
  attach_external_secrets_policy        = true
  external_secrets_ssm_parameter_arns   = ["arn:aws:ssm:*:*:parameter/*"]
  external_secrets_secrets_manager_arns = ["arn:aws:secretsmanager:*:*:secret:*"]
  external_secrets_kms_key_arns         = ["arn:aws:kms:*:*:key/*"]

  # Should External Secrets be able to create AWS secrets?
  external_secrets_create_permission = false

  associations = {
    cluster1 = {
      cluster_name = module.eks.cluster_name
      namespace    = "external-secrets"
      # Must match account referenced in K8TRE external-secrets
      service_account = "external-secrets"
    }
  }
}


######################################################################
# ACK EC2 Controller pod identity
# https://aws-controllers-k8s.github.io/docs/api-reference/#ec2

data "aws_iam_policy_document" "ack_ec2" {
  count = local.create_pod_identities
  statement {
    sid       = "InstanceProfiles"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*"]
  }
}

module "ack_ec2_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.7.0"
  count   = local.create_pod_identities
  name    = "ack-ec2-controller"

  # Associate identity with the ServiceAccount that will be created by the
  # aws-load-balancer-controller Helm chart
  association_defaults = {
    namespace       = "aws-ack"
    service_account = "ack-ec2-controller"
  }

  associations = {
    cluster1 = {
      cluster_name = module.eks.cluster_name
    }
  }

  attach_custom_policy = true
  # TODO: narrow scope to only the EC2 actions we need
  source_policy_documents = [data.aws_iam_policy_document.ack_ec2[0].json]
  additional_policy_arns = {
    AmazonEC2FullAccess = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
  }
}
