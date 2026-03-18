variable "dns_domain" {
  type        = string
  default     = "k8tre.internal"
  description = "DNS domain"
}

variable "create_public_zone" {
  type        = bool
  default     = true
  description = "Create public DNS zone"
}


######################################################################
# EFS

module "efs" {
  source  = "./efs"
  name    = var.efs_token
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

  # For now allow all since K8TRE is fetching external images and code
  allowed_domains = ["*."]

  create_public_zone = var.create_public_zone
}
