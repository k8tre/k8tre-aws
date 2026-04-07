variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_r53_id" {
  type = string
}

variable "subnets" {
  type = list(string)
}

variable "discovery_domain" {
  type = string
}
