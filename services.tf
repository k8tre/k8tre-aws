######################################################################
# Storage encryption key

data "aws_caller_identity" "current" {}

resource "aws_kms_key" "default-storage" {
  description             = "${var.name} default storage key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Root IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = format("arn:aws:iam::%s:root", data.aws_caller_identity.current.account_id)
        }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "default-storage" {
  name          = "alias/${var.name}/default-storage"
  target_key_id = aws_kms_key.default-storage.key_id
}


######################################################################
# EFS

locals {
  efs_token = var.efs_token == null ? var.name : var.efs_token
}

module "efs" {
  source      = "./efs"
  name        = local.efs_token
  vpc_id      = module.vpc.vpc_id
  subnets     = module.vpc.private_subnets
  kms_key_arn = aws_kms_key.default-storage.arn
}


######################################################################
# DNS

module "dnsresolver" {
  source = "./dnsresolver"
  name   = var.dns_domain

  subnet0 = module.vpc.private_subnets[0]
  ip0     = cidrhost(module.vpc.private_subnets_cidr_blocks[0], -3)
  subnet1 = module.vpc.private_subnets[1]
  ip1     = cidrhost(module.vpc.private_subnets_cidr_blocks[1], -3)

  vpc = module.vpc.vpc_id

  alarm_topics = []

  static-ttl = 3600
  static = [
    # # ECS Aliases
    # ["proxy", "CNAME", "squid-proxy.${var.dns_domain}"],
  ]

  # For now allow all since K8TRE is fetching external images and code
  allowed_domains = ["*."]

  create_public_zone = var.create_public_zone
}


######################################################################
# Certificate

module "certificate" {
  count = var.request_certificate == "none" ? 0 : 1

  source = "./certificate"

  domain_name               = "*.${var.dns_domain}"
  subject_alternative_names = [var.dns_domain]

  request_acm_certificate = var.request_certificate == "acm" ? true : false
}
