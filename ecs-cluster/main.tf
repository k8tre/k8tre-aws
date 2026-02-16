data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_kms_key" "ecs" {
  description             = "${var.name} ECS Cluster KMS Key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "ECS"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = format("arn:aws:iam::%s:root", data.aws_caller_identity.current.account_id)
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow CloudWatch Logs"
        Effect = "Allow"
        Principal = {
          Service = format("logs.%s.amazonaws.com", data.aws_region.current.name)
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ],
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = [
              format("arn:aws:logs:%s:%s:log-group:%s", data.aws_region.current.name, data.aws_caller_identity.current.account_id, var.name)
            ]
          }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "ecs-logs" {
  name              = var.name
  retention_in_days = 3653

  kms_key_id = aws_kms_key.ecs.arn
}

# tfsec:ignore:aws-ecs-enable-container-insight
resource "aws_ecs_cluster" "ecs" {
  name = var.name

  configuration {
    execute_command_configuration {
      kms_key_id = aws_kms_key.ecs.arn
      logging    = "OVERRIDE"

      log_configuration {
        cloud_watch_encryption_enabled = true
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.ecs-logs.name
      }
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "fargate" {
  cluster_name = aws_ecs_cluster.ecs.name

  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = "FARGATE"
  }
}

# The service discovery namespace lives in the Route53 VPC, which
# means the TRE's route53 resolver is able to see it and will respond
# to queries for that zone.
resource "aws_service_discovery_private_dns_namespace" "ecs" {
  name        = var.discovery_domain
  description = "Service Discovery namespace for ECS"
  vpc         = var.vpc_r53_id
}
