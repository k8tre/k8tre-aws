data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_cloudwatch_log_group" "squid_proxy" {
  name = "${var.ecs_cluster}/squid-proxy"

  kms_key_id = var.kms_key
}

resource "aws_cloudwatch_log_metric_filter" "squid_proxy_denied" {
  name    = "squid-proxy-denied"
  pattern = "TCP_DENIED"

  log_group_name = aws_cloudwatch_log_group.squid_proxy.name

  metric_transformation {
    name      = "SquidTcpDenied"
    namespace = "ServiceAnomalies"
    value     = "1"
  }
}

# The threshold should ignore the health check, but any additional requests should trigger the alarm.
resource "aws_cloudwatch_metric_alarm" "squid_tcp_denied" {
  alarm_name                = "Squid proxy TCP_DENIED rate"
  comparison_operator       = "GreaterThanThreshold"
  evaluation_periods        = "1"
  metric_name               = "SquidTcpDenied"
  namespace                 = "ServiceAnomalies"
  period                    = "30"
  statistic                 = "Sum"
  threshold                 = "4"
  alarm_description         = "Squid proxy TCP_DENIED requests is higher than expected"
  insufficient_data_actions = []
  alarm_actions             = []
  ok_actions                = []
}

resource "aws_iam_role_policy" "squid_proxy_exec" {
  name = "execution-role"
  role = aws_iam_role.squid_proxy_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = format("arn:aws:logs:%s:%s:log-group:%s:*", data.aws_region.current.region, data.aws_caller_identity.current.account_id, aws_cloudwatch_log_group.squid_proxy.name)
      }
    ]
  })
}

resource "aws_iam_role" "squid_proxy_exec" {
  name = "squid-proxy-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role" "squid_proxy_task" {
  name = "squid-proxy-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Condition = {
          ArnLike = {
            "aws:SourceArn" = format("arn:aws:ecs:%s:%s:*", data.aws_region.current.region, data.aws_caller_identity.current.account_id)
          },
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

resource "aws_ecs_task_definition" "squid_proxy" {
  family       = "squid-proxy"
  network_mode = "awsvpc"

  requires_compatibilities = [
    "FARGATE"
  ]

  cpu    = 256
  memory = 512

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  task_role_arn      = aws_iam_role.squid_proxy_task.arn
  execution_role_arn = aws_iam_role.squid_proxy_exec.arn

  container_definitions = jsonencode([
    {
      name  = "squid"
      image = "${var.squid_proxy_repository}:${var.squid_proxy_version}"

      essential = true
      portMappings = [
        {
          containerPort = 3128
          hostPort      = 3128
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.squid_proxy.name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = "ecs"
        }
      }
      healthCheck = {
        command = [
          "CMD-SHELL",
          "curl -k -x http://localhost:3128 http://localhost"
        ]
        interval    = 30
        retries     = 3
        startPeriod = 180
        timeout     = 5
      }
      environment = [
        {
          name  = "ALLOWED_DOMAINS"
          value = join(",", var.squid_proxy_allowed_domains)
        }
      ]
    }
  ])
}

resource "aws_security_group" "squid_proxy" {
  name        = "ecs-squid-proxy"
  description = "Security group for squid-proxy-container"
  vpc_id      = var.vpc_id

  tags = {
    Name = "squid-proxy"
  }
}

resource "aws_vpc_security_group_ingress_rule" "squid_proxy_local" {
  security_group_id            = aws_security_group.squid_proxy.id
  referenced_security_group_id = aws_security_group.squid_proxy.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_ingress_rule" "squid_proxy_tre" {
  security_group_id = aws_security_group.squid_proxy.id
  ip_protocol       = "tcp"
  from_port         = 3128
  to_port           = 3128
  cidr_ipv4         = "10.0.0.0/8"
}

# todo: tighten this
resource "aws_vpc_security_group_egress_rule" "squid_proxy_out" {
  security_group_id = aws_security_group.squid_proxy.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_ecs_service" "squid_proxy" {
  name            = "squid-proxy"
  cluster         = var.ecs_cluster
  task_definition = aws_ecs_task_definition.squid_proxy.arn
  desired_count   = 1

  network_configuration {
    subnets = var.public_subnets

    security_groups = [
      aws_security_group.squid_proxy.id
    ]

    assign_public_ip = true
  }

  service_registries {
    registry_arn   = aws_service_discovery_service.squid_proxy.arn
    container_name = "sqiud"
  }

  capacity_provider_strategy {
    base              = 1
    capacity_provider = "FARGATE"
    weight            = 100
  }

  enable_execute_command = true

  propagate_tags = "TASK_DEFINITION"
}

resource "aws_service_discovery_service" "squid_proxy" {
  name = "squid-proxy"

  dns_config {
    namespace_id = var.ecs_discovery_id

    dns_records {
      ttl  = 60
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  # health_check_config {
  #   failure_threshold = 1
  #   type              = "TCP"
  # }
}
