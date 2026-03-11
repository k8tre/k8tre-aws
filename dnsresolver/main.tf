terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

######################################################################
# Public zone
######################################################################

resource "aws_route53_zone" "public-zone" {
  name = var.name
}

resource "aws_route53_record" "public-record" {
  for_each = var.public-records

  zone_id = aws_route53_zone.public-zone.zone_id
  name    = format("%s.%s", split(" ", each.key)[0], var.name)
  type    = split(" ", each.key)[1]
  ttl     = 300
  records = each.value
}


######################################################################
# Private zone
######################################################################

resource "aws_security_group" "inbound-dns" {
  name        = "inbound-dns"
  description = "Allow inbound DNS"
  vpc_id      = var.vpc
}

resource "aws_security_group_rule" "inbound-dns-tcp" {
  description       = "Permits inbound dns lookups on 53/tcp"
  type              = "ingress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = var.allow_dns_from_cidrs
  security_group_id = aws_security_group.inbound-dns.id
}

resource "aws_security_group_rule" "inbound-dns-udp" {
  description       = "Permits inbound dns lookups on 53/udp"
  type              = "ingress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = var.allow_dns_from_cidrs
  security_group_id = aws_security_group.inbound-dns.id
}

resource "aws_route53_resolver_endpoint" "private-resolver" {
  name      = "${var.name_tag}-Resolver"
  direction = "INBOUND"

  security_group_ids = [
    aws_security_group.inbound-dns.id
  ]

  ip_address {
    subnet_id = var.subnet0
    ip        = var.ip0
  }

  ip_address {
    subnet_id = var.subnet1
    ip        = var.ip1
  }
}

resource "aws_route53_zone" "private-zone" {
  name = var.name

  # This is required for a private zone
  vpc {
    vpc_id = var.vpc
  }
}

resource "aws_route53_record" "static-record" {
  for_each = zipmap([for e in var.static : format("%s:%s:%s", e[0], e[1], e[2])], var.static)

  zone_id = aws_route53_zone.private-zone.zone_id
  name    = format("%s.%s", each.value[0], var.name)
  type    = each.value[1]
  ttl     = var.static-ttl
  records = [each.value[2]]
}

resource "aws_route53_resolver_firewall_rule_group" "resolver-fw" {
  name = "${var.name_tag}-resolver-firewall"
}

resource "aws_route53_resolver_firewall_rule_group_association" "resolver-fw-assoc" {
  name                   = "${var.name_tag}-vpc-resolver-firewall-assoc"
  firewall_rule_group_id = aws_route53_resolver_firewall_rule_group.resolver-fw.id
  priority               = 101
  vpc_id                 = var.vpc
}

locals {
  r53_always_allowed_domains = [
    "*.amazonaws.com.",
    format("*.%s.", var.name),
    format("%s.", var.name)
  ]
}

resource "aws_route53_resolver_firewall_domain_list" "resolver-fw-list-mass" {
  name    = var.name_tag
  domains = concat(local.r53_always_allowed_domains, var.allowed_domains)
  tags = {
    "TFModule" = "${var.name_tag}/resolver",
    "Name"     = "${var.name_tag}-resolver-fw-list-${var.name_tag}"
  }
}

resource "aws_route53_resolver_firewall_domain_list" "resolver-fw-list-default" {
  name = "default-deny"
  domains = [
    "*."
  ]
  tags = {
    "TFModule" = "${var.name_tag}/resolver",
    "Name"     = "${var.name_tag}-resolver-fw-list-default"
  }
}

resource "aws_route53_resolver_firewall_rule" "resolver-rule-private-allow" {
  name                    = "${var.name_tag}-allow"
  action                  = "ALLOW"
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.resolver-fw.id
  firewall_domain_list_id = aws_route53_resolver_firewall_domain_list.resolver-fw-list-mass.id
  priority                = 10
}

resource "aws_route53_resolver_firewall_rule" "resolver-rule-default-deny" {
  name                    = "default-deny"
  action                  = "BLOCK"
  block_response          = "NODATA"
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.resolver-fw.id
  firewall_domain_list_id = aws_route53_resolver_firewall_domain_list.resolver-fw-list-default.id
  priority                = 50
}

resource "aws_cloudwatch_metric_alarm" "alarm-resolver" {
  alarm_name                = format("%s %s Route53 Request Volume", var.name_tag, var.name)
  comparison_operator       = "GreaterThanThreshold"
  evaluation_periods        = "2"
  metric_name               = "InboundQueryVolume"
  namespace                 = "AWS/Route53Resolver"
  period                    = "300"
  statistic                 = "Average"
  threshold                 = "5000"
  alarm_description         = "High Query Volume"
  insufficient_data_actions = []
  alarm_actions             = var.alarm_topics
  ok_actions                = var.alarm_topics

  dimensions = {
    EndpointId = aws_route53_resolver_endpoint.private-resolver.id
  }
}
