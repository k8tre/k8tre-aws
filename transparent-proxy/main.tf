terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.14"
    }
  }

  required_version = ">= 1.10.0"
}

resource "aws_s3_object" "allowlist" {
  bucket       = var.s3_config_bucket
  key          = "${var.name}/squid-proxy/allowlist.txt"
  content      = join("\n", var.allowed_domains)
  content_type = "text/plain"
}


resource "aws_security_group" "squid_proxy" {
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

resource "aws_iam_role" "squid_proxy" {
  name = "transparent-proxy-instance-role"

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

resource "aws_iam_role_policy_attachment" "squid_proxy" {
  role       = aws_iam_role.squid_proxy.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "squid_proxy_cw" {
  role       = aws_iam_role.squid_proxy.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy" "proxy_s3_read" {
  name = "proxy-s3-configuration-read"
  role = aws_iam_role.squid_proxy.id

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

resource "aws_iam_instance_profile" "squid_proxy" {
  name = "transparent-proxy-instance-profile"
  role = aws_iam_role.squid_proxy.name
}

resource "aws_instance" "squid_proxy" {
  ami                         = data.aws_ssm_parameter.latest_ami_id.value
  instance_type               = "t3a.medium"
  subnet_id                   = var.public_subnet
  vpc_security_group_ids      = [aws_security_group.squid_proxy.id]
  iam_instance_profile        = aws_iam_instance_profile.squid_proxy.name
  associate_public_ip_address = true

  # Disable source/destination checking to allow packet interception
  source_dest_check = false

  # Bootstrap Squid, iptables, and the whitelist
  # To debug this login with SSM and check /var/log/cloud-init.log /var/log/cloud-init-output.log
  user_data = <<-EOF
              #!/bin/bash
              set -ex

              # Wait until the apt/dpkg locks are released by unattended-upgrades
              while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
                echo "Waiting for automatic system updates to finish..."
                sleep 10
              done

              export DEBIAN_FRONTEND=noninteractive


              ############################################################
              # Install Squid and setup routing
              ############################################################

              # Pre-seed iptables-persistent to avoid the purple interactive config screen
              echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
              echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

              # Install Squid and other requirements
              apt-get update -y -o DPkg::Lock::Timeout=180
              apt-get install -y -o DPkg::Lock::Timeout=180 iptables-persistent netfilter-persistent openssl squid-openssl unzip

              curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              unzip awscliv2.zip
              ./aws/install

              # Enable IPv4 Forwarding in the kernel
              echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
              sysctl -p

              # ens5 should be the default NIC, if it isn't this will error out
              ip addr show ens5

              # Configure iptables to intercept traffic and route to Squid ports
              iptables -t nat -A PREROUTING -i ens5 -p tcp --dport 80 -j REDIRECT --to-port 3128
              iptables -t nat -A PREROUTING -i ens5 -p tcp --dport 443 -j REDIRECT --to-port 3129

              # Replaces original private IP with the proxy's private IP
              iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE

              # Save iptables rules and ensure they're reloaded on reboot
              iptables-save > /etc/iptables/rules.v4
              systemctl enable netfilter-persistent
              systemctl restart netfilter-persistent


              ############################################################
              # Configure Squid
              ############################################################

              # Generate dummy SSL certificate required for Squid's transparent peering framework
              mkdir -p /etc/squid/ssl
              openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
                -subj "/C=UK/O=K8TRE/CN=transparent-proxy" \
                -keyout /etc/squid/ssl/dummy.pem -out /etc/squid/ssl/dummy.pem
              chown -R proxy:proxy /etc/squid/ssl
              chmod 400 /etc/squid/ssl/dummy.pem

              # Initialize the SSL certificate database for the certgen helper
              mkdir -p /var/lib/squid
              rm -rf /var/lib/squid/ssl_db
              /usr/lib/squid/security_file_certgen -c -s /var/lib/squid/ssl_db -M 4MB
              # Give the squid user ownership of the new database
              chown -R proxy:proxy /var/lib/squid

              # Ensure file exists before first s3 copy, must be non-empty
              echo localhost > /etc/squid/allowlist.txt
              chown proxy:proxy /etc/squid/allowlist.txt

              # Overwrite default Squid configuration for transparent peek-and-splice
              cat << 'SQUID' > /etc/squid/squid.conf
              # Fix public hostname warning (unable to detect)
              visible_hostname squid-proxy

              # Standard forward-proxy port (required by Squid to start)
              http_port localhost:3130

              # Intercept standard HTTP
              http_port 3128 intercept
              
              # Intercept HTTPS (using ssl-bump parsing)
              https_port 3129 intercept ssl-bump cert=/etc/squid/ssl/dummy.pem generate-host-certificates=on dynamic_cert_mem_cache_size=4MB

              # Point to the initialized cert database
              sslcrtd_program /usr/lib/squid/security_file_certgen -s /var/lib/squid/ssl_db -M 4MB

              # Access Control Lists
              # This is complicated because for HTTPS we want to check the SNI host, but
              # if it's allowed we want to pass the request through unchanged without
              # replacing it with our dummy certificate
              acl SSL_port port 443

              # Define an ACL that matches Step 1 only of the TLS handshake
              acl step1 at_step SslBump1

              acl allowed_domains dstdomain "/etc/squid/allowlist.txt"
              acl allowed_domains_ssl ssl::server_name "/etc/squid/allowlist.txt"

              # SSL Bump configuration
              # ONLY peek if at step 1, to prevent the dummy certificate being returned to client
              ssl_bump peek step1
              # If the SNI matches our whitelist, splice (pass through untouched)
              ssl_bump splice allowed_domains_ssl
              # Otherwise terminate the connection.
              ssl_bump terminate all

              # Disable caching since we're only interested in restricting domains
              cache deny all

              # Allow standard HTTP traffic if it matches the whitelist
              http_access allow allowed_domains
              # Allow intercepted HTTPS IP addresses to pass this initial check.
              http_access allow SSL_port
              # Block everything else
              http_access deny all
              SQUID

              # Create a systemd drop-in directory to override Squid's default startup mechanics
              mkdir -p /etc/systemd/system/squid.service.d

              cat << 'SYSTEMD_OVERRIDE' > /etc/systemd/system/squid.service.d/override.conf
              [Service]
              # Pull the configuration down from S3 prior to starting the main engine
              ExecStartPre=/usr/local/bin/aws s3 cp s3://${var.s3_config_bucket}/${var.name}/squid-proxy/allowlist.txt /etc/squid/allowlist.txt
              # ExecStartPre=/bin/chown proxy:proxy /etc/squid/allowlist.txt
              SYSTEMD_OVERRIDE

              systemctl daemon-reload
              systemctl restart squid
              systemctl enable squid

              # Latest Ubuntu AMD64 CloudWatch Agent package
              wget https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb -O /tmp/amazon-cloudwatch-agent.deb
              dpkg -i -E /tmp/amazon-cloudwatch-agent.deb

              # Create the CloudWatch Agent configuration file
              cat << 'CWAGENT' > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
              {
                "agent": {
                  "run_as_user": "root"
                },
                "logs": {
                  "logs_collected": {
                    "files": {
                      "collect_list": [
                        {
                          "file_path": "/var/log/squid/access.log",
                          "log_group_name": "${var.name}/squid-proxy",
                          "log_stream_name": "{instance_id}",
                          "timezone": "UTC"
                        }
                      ]
                    }
                  }
                }
              }
              CWAGENT

              # Start and enable the CloudWatch agent using the config
              /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s
              systemctl enable --now amazon-cloudwatch-agent

              EOF

  tags = {
    Name = "transparent-proxy"
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
  network_interface_id   = aws_instance.squid_proxy.primary_network_interface_id
}


resource "aws_cloudwatch_log_group" "transparent_proxy" {
  name              = "${var.name}/squid-proxy"
  retention_in_days = var.log_group_retention_days

  # Use default server-side encryption
}

resource "aws_cloudwatch_log_metric_filter" "transparent_proxy_denied" {
  name    = "transparent-proxy-denied"
  pattern = "TCP_DENIED"

  log_group_name = aws_cloudwatch_log_group.transparent_proxy.name

  metric_transformation {
    name      = "ProxyTcpDenied"
    namespace = "ServiceAnomalies"
    value     = "1"
  }
}

# # The threshold should ignore the health check, but any additional requests should trigger the alarm.
# resource "aws_cloudwatch_metric_alarm" "squid_tcp_denied" {
#   alarm_name                = "Transparent proxy TCP_DENIED rate"
#   comparison_operator       = "GreaterThanThreshold"
#   evaluation_periods        = "1"
#   metric_name               = "ProxyTcpDenied"
#   namespace                 = "ServiceAnomalies"
#   period                    = "30"
#   statistic                 = "Sum"
#   threshold                 = "4"
#   alarm_description         = "Transparent proxy TCP_DENIED requests is higher than expected"
#   insufficient_data_actions = []
#   alarm_actions             = []
#   ok_actions                = []
# }
