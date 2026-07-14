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
# Bucket for study data

resource "aws_s3_bucket" "studydata" {
  bucket_prefix = "${var.name}-studydata-"
  # force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "studydata" {
  bucket = aws_s3_bucket.studydata.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.default-storage.arn
      sse_algorithm     = "aws:kms"
    }
  }
}


######################################################################
# Bucket for storing configuration

resource "aws_s3_bucket" "services-config" {
  bucket_prefix = "${var.name}-config-"
  force_destroy = true
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

  private-records = {
    "_ldap._tcp.gc._msdcs.ad SRV" = ["0 100 3268 dc0.ad.${var.dns_domain}"]
    "_kerberos._tcp.ad SRV"       = ["0 100 88 dc0.ad.${var.dns_domain}"]
    "_kerberos._udp.ad SRV"       = ["0 100 88 dc0.ad.${var.dns_domain}"]
    "_ldap._tcp.ad SRV"           = ["0 100 389 dc0.ad.${var.dns_domain}"]
    "_ldap._udp.ad SRV"           = ["0 100 389 dc0.ad.${var.dns_domain}"]
  }

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


######################################################################
# VPC endpoints

resource "aws_security_group" "vpc_endpoints" {
  name        = "eks-vpc-endpoints-sg"
  description = "Allow inbound HTTPS to VPC Endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

# https://docs.aws.amazon.com/eks/latest/userguide/private-clusters.html
# https://docs.aws.amazon.com/vpc/latest/privatelink/aws-services-privatelink-support.html
resource "aws_vpc_endpoint" "interface" {
  for_each = toset([
    # CloudWatch logs
    "com.amazonaws.${var.region}.logs",

    # Encrypted secrets and storage
    "com.amazonaws.${var.region}.kms",

    # Needed for AssumeRole
    "com.amazonaws.${var.region}.sts",

    # EC2 instances, and EBS storage volumes
    "com.amazonaws.${var.region}.ec2",

    # EFS
    "com.amazonaws.${var.region}.elasticfilesystem",

    # Autoscaling controller
    "com.amazonaws.${var.region}.autoscaling",

    # Uncomment if using ECR hosted images
    # "com.amazonaws.${var.region}.ecr.api",
    # "com.amazonaws.${var.region}.ecr.dkr",

    # EKS
    "com.amazonaws.${var.region}.eks",
    # EKS pod identities
    "com.amazonaws.${var.region}.eks-auth",

    # Load balancing
    "com.amazonaws.${var.region}.elasticloadbalancing",

    # SSM sessions and SSM Parameter store (External Secrets operator)
    "com.amazonaws.${var.region}.ssm",

    # SSM sessions
    "com.amazonaws.${var.region}.ec2messages",
    "com.amazonaws.${var.region}.ssmmessages",

    # "aws.api.${var.region}.s3files",
  ])
  service_name = each.value

  vpc_id              = module.vpc.vpc_id
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpc_endpoints.id]

  # policy =
}

resource "aws_vpc_endpoint" "route53_interface_endpoint" {
  vpc_id            = module.vpc.vpc_id
  vpc_endpoint_type = "Interface"
  # This is a global service
  service_name       = "com.amazonaws.route53"
  service_region     = "us-east-1"
  subnet_ids         = module.vpc.private_subnets
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  # policy =
}

resource "aws_vpc_endpoint" "s3_gateway_endpoint" {
  vpc_id            = module.vpc.vpc_id
  vpc_endpoint_type = "Gateway"
  service_name      = "com.amazonaws.${var.region}.s3"
  route_table_ids   = module.vpc.private_route_table_ids

  # policy =
}


######################################################################
# Transparent proxy

module "transparent-proxy" {
  count = var.require_outbound_proxy ? 1 : 0

  source                           = "./transparent-proxy"
  name                             = var.name
  vpc_id                           = module.vpc.vpc_id
  vpc_cidr                         = module.vpc.vpc_cidr_block
  public_subnet                    = module.vpc.public_subnets[0]
  private_subnet_route_table_ids   = module.vpc.private_route_table_ids
  private_subnet_route_table_cidrs = var.outbound_proxy_cidrs

  s3_config_bucket   = aws_s3_bucket.services-config.id
  allowed_domains_re = concat(var.default_outbound_proxy_allowed_domains_re, var.additional_outbound_proxy_allowed_domains_re)
}
