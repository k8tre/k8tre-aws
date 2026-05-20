terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.14"
    }
  }

  required_version = ">= 1.15.0"
}

resource "aws_s3_object" "allowlist" {
  bucket       = var.s3_config_bucket
  key          = "${var.name}-transparent-proxy/allowlist.txt"
  content      = format("%s\n", join("\n", var.allowed_domains_re))
  content_type = "text/plain"
}


resource "aws_security_group" "transparent_proxy" {
  name        = "transparent-proxy-sg"
  description = "Allow inbound HTTP/HTTPS traffic from VPC"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Allow all outbound to the internet
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Get AMI from SSM
# https://documentation.ubuntu.com/aws/aws-how-to/instances/find-ubuntu-images/
data "aws_ssm_parameter" "latest_ami_id" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_iam_role" "transparent_proxy" {
  name = "${var.name}-transparent-proxy-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "transparent_proxy" {
  role       = aws_iam_role.transparent_proxy.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "transparent_proxy_cw" {
  role       = aws_iam_role.transparent_proxy.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy" "proxy_s3_read" {
  name = "${var.name}-proxy-s3-configuration-read"
  role = aws_iam_role.transparent_proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.s3_config_bucket}",
          "arn:aws:s3:::${var.s3_config_bucket}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "transparent_proxy" {
  name = "${var.name}-transparent-proxy-instance-profile"
  role = aws_iam_role.transparent_proxy.name
}

resource "aws_instance" "transparent_proxy" {
  ami                         = data.aws_ssm_parameter.latest_ami_id.value
  instance_type               = "t3a.medium"
  subnet_id                   = var.public_subnet
  vpc_security_group_ids      = [aws_security_group.transparent_proxy.id]
  iam_instance_profile        = aws_iam_instance_profile.transparent_proxy.name
  associate_public_ip_address = true

  # Disable source/destination checking to allow packet interception
  source_dest_check = false

  # Install and configure proxy and dependencies
  # To debug this login with SSM and check /var/log/cloud-init.log /var/log/cloud-init-output.log
  user_data = templatefile("${path.module}/userdata.sh", {
    s3_config_bucket = var.s3_config_bucket
    name             = var.name
  })

  tags = {
    Name = "${var.name}-transparent-proxy"
  }

  # AMI is dynamically lookedup, don't replace instance if it changes
  lifecycle {
    ignore_changes = [ami]
  }
}

# Update the private subnet route table to route through the proxy
locals {
  route_matrix = {
    for pair in setproduct(var.private_subnet_route_table_ids, var.private_subnet_route_table_cidrs) :
    "${pair[0]}_${pair[1]}" => {
      route_table_id = pair[0]
      cidr_block     = pair[1]
    }
  }
}

resource "aws_route" "private_subnet_to_proxy" {
  for_each = local.route_matrix

  route_table_id         = each.value.route_table_id
  destination_cidr_block = each.value.cidr_block
  network_interface_id   = aws_instance.transparent_proxy.primary_network_interface_id
}


resource "aws_cloudwatch_log_group" "transparent_proxy" {
  name              = "${var.name}/transparent-proxy"
  retention_in_days = var.log_group_retention_days

  # Use default server-side encryption
}

resource "aws_cloudwatch_log_metric_filter" "transparent_proxy_denied" {
  name    = aws_cloudwatch_log_group.transparent_proxy.name
  pattern = "\"<NOSRV>\""

  log_group_name = aws_cloudwatch_log_group.transparent_proxy.name

  metric_transformation {
    name          = "ProxyDenied"
    namespace     = "ServiceAnomalies"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "transparent_proxy_denied" {
  alarm_name                = "Transparent proxy NOSRV rate"
  comparison_operator       = "GreaterThanThreshold"
  evaluation_periods        = "1"
  metric_name               = "ProxyDenied"
  namespace                 = "ServiceAnomalies"
  period                    = "30"
  statistic                 = "Sum"
  threshold                 = "1"
  alarm_description         = "Transparent proxy NOSRV requests is higher than expected"
  insufficient_data_actions = []
  alarm_actions             = []
  ok_actions                = []
}
