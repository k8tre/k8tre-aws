# EKS storage pod identities and networking

# EBS

module "aws_ebs_csi_pod_identity" {
  source                    = "terraform-aws-modules/eks-pod-identity/aws"
  version                   = var.module_eks_pod_identity_version
  name                      = "aws-ebs-csi"
  attach_aws_ebs_csi_policy = true
  aws_ebs_csi_kms_arns      = ["arn:aws:kms:*:*:key/*"]
}

# EFS

module "aws_efs_csi_pod_identity" {
  source                    = "terraform-aws-modules/eks-pod-identity/aws"
  version                   = var.module_eks_pod_identity_version
  name                      = "aws-efs-csi"
  attach_aws_efs_csi_policy = true
}

# S3 https://github.com/terraform-aws-modules/terraform-aws-eks-pod-identity/blob/v2.8.1/examples/complete/main.tf#L425-L450

module "mountpoint_s3_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = var.module_eks_pod_identity_version
  count   = local.create_s3_csi_pod_identity
  name    = "mountpoint-s3-csi"

  # The built-in policy allows read-write
  # For now we only need read-only, so define our own policy
  # attach_mountpoint_s3_csi_policy    = true
  # mountpoint_s3_csi_bucket_arns      = formatlist("arn:aws:s3:::%s", var.s3_mountable_buckets)
  # mountpoint_s3_csi_bucket_path_arns = formatlist("arn:aws:s3:::%s/*", var.s3_mountable_buckets)

  attach_custom_policy = true
  policy_statements = [
    {
      sid       = "MountpointListBucket"
      actions   = ["s3:ListBucket"]
      effect    = "Allow"
      resources = var.s3_mountable_bucket_arns
    },
    {
      sid       = "MountpointReadOnlyObjectAccess"
      actions   = ["s3:GetObject"]
      effect    = "Allow"
      resources = formatlist("%s/*", var.s3_mountable_bucket_arns)
    },
    {
      sid       = "DecryptData"
      actions   = ["kms:Decrypt"]
      effect    = "Allow"
      resources = var.s3_mountable_bucket_keys
    },
  ]

  association_defaults = {
    namespace       = "kube-system"
    service_account = "s3-csi-driver-sa"
  }
}
