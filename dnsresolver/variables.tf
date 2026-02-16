variable "name" {
  type        = string
  description = "zone name"
}

variable "subnet0" {
  type        = string
  description = "subnet id"
}

variable "ip0" {
  type        = string
  description = "resolver ip 0"
}

variable "subnet1" {
  type        = string
  description = "subnet id"
}

variable "ip1" {
  type        = string
  description = "resolver ip 1"
}

variable "vpc" {
  type        = string
  description = "vpc id"
}

variable "name_tag" {
  type        = string
  description = "a name used for tagging"
  default     = "mass"
}

variable "allow_dns_from_cidrs" {
  type        = list(any)
  description = "list of cidrs to allow dns from"
  default     = ["10.0.0.0/8"]
}

variable "static-ttl" {
  type        = number
  description = "ttl for static entries"
}

variable "static" {
  type        = list(any)
  description = "list of lists of records [ [name, type, ip], [name, type, ip] ]"
}

variable "alarm_topic" {
  type        = string
  description = "ARN of CloudWatch alarm"
}
