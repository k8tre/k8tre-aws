
######################################################################
# EFS

locals {
  efs_token = var.efs_token == null ? var.name : var.efs_token
}

module "efs" {
  source  = "./efs"
  name    = local.efs_token
  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.private_subnets
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
