data "aws_subnet" "subnets" {
  for_each = toset(var.subnets)
  id       = each.value
}

# Allow NFS traffic 2049/tcp
resource "aws_security_group" "efs_sg" {
  name        = "efs-access-sg"
  description = "Allow NFS traffic for EFS"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [for s in data.aws_subnet.subnets : s.cidr_block]
  }
}

resource "aws_efs_file_system" "efs" {
  creation_token = var.name
  encrypted      = true

  tags = {
    Name = var.name
  }
}

# Mount targets, one per subnet
resource "aws_efs_mount_target" "mount" {
  for_each        = toset(var.subnets)
  file_system_id  = aws_efs_file_system.efs.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs_sg.id]
}



# data "aws_caller_identity" "current" {}
# data "aws_region" "current" {}

# resource "aws_kms_key" "efs" {
#   description             = "${var.name} KMS Key"
#   deletion_window_in_days = 30
#   enable_key_rotation     = true

#   policy = jsonencode({
#     Version = "2012-10-17"
#     Id      = "EFS"
#     Statement = [
#       {
#         Sid    = "Enable IAM User Permissions"
#         Effect = "Allow"
#         Principal = {
#           AWS = format("arn:aws:iam::%s:root", data.aws_caller_identity.current.account_id)
#         }
#         Action   = "kms:*"
#         Resource = "*"
#       }
#     ]
#   })
# }

# resource "aws_kms_alias" "efs" {
#   name          = "alias/${var.name}/efs"
#   target_key_id = aws_kms_key.efs.key_id
# }
