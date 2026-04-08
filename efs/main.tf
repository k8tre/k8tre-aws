terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.14"
    }
  }

  required_version = ">= 1.10.0"
}

data "aws_subnet" "subnets" {
  count = length(var.subnets)

  id = var.subnets[count.index]
}

# Allow NFS traffic 2049/tcp
resource "aws_security_group" "efs_sg" {
  name        = "${var.name}-efs-sg"
  description = "Allow NFS traffic for EFS"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = data.aws_subnet.subnets[*].cidr_block
  }
}

resource "aws_efs_file_system" "efs" {
  creation_token = var.name
  encrypted      = true
  kms_key_id     = var.kms_key_arn

  tags = {
    Name = var.name
  }
}

# Mount targets, one per subnet
resource "aws_efs_mount_target" "mount" {
  count = length(var.subnets)

  file_system_id  = aws_efs_file_system.efs.id
  subnet_id       = var.subnets[count.index]
  security_groups = [aws_security_group.efs_sg.id]
}

