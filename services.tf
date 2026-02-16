variable "dns_domain" {
  type        = string
  default     = "chicken.k8tre-dev-eks.trevolution.dev.hic.dundee.ac.uk"
  description = "DNS domain"
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
    # ECS Aliases
    ["proxy", "CNAME", "squid-proxy.${var.dns_domain}"],
  ]

  # For now allow all since K8TRE is fetching external images and code
  allowed_domains = ["*."]
}


module "cluster" {
  source           = "./ecs-cluster"
  name             = "squid-proxy"
  vpc_id           = module.vpc.vpc_id
  vpc_r53_id       = module.vpc.vpc_id
  subnets          = slice(module.vpc.public_subnets, 0, 2)
  discovery_domain = "ecs.${var.dns_domain}"
}

module "squid" {
  source      = "./proxy"
  ecs_cluster = module.cluster.ecs_cluster
  kms_key     = module.cluster.kms_arn

  vpc_id           = module.vpc.vpc_id
  public_subnets   = slice(module.vpc.public_subnets, 0, 2)
  ecs_discovery_id = module.cluster.discovery_id
}
