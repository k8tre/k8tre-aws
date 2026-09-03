# Locals that may be used in multiple places

data "aws_caller_identity" "current" {}

locals {
  aws_account_id = data.aws_caller_identity.current.account_id

  create_pod_identities            = var.create_pod_identities ? 1 : 0
  create_external_dns_pod_identity = (var.create_pod_identities && length(var.hosted_zone_ids) > 0) ? 1 : 0

  enable_s3_csi = (length(var.s3_mountable_bucket_arns) > 0) ? 1 : 0

  create_s3_csi_pod_identity = (var.create_pod_identities && local.enable_s3_csi > 0) ? 1 : 0
}
