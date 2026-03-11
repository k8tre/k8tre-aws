variable "name" {
  type        = string
  description = "zone name"
}

variable "subnet0" {
  type        = string
  description = "Private zone subnet id"
}

variable "ip0" {
  type        = string
  description = "Private zone resolver ip 0"
}

variable "subnet1" {
  type        = string
  description = "Private zone subnet id"
}

variable "ip1" {
  type        = string
  description = "Private zone resolver ip 1"
}

variable "vpc" {
  type        = string
  description = "vpc id"
}

variable "name_tag" {
  type        = string
  description = "Name used for private resources"
  default     = "private"
}

variable "allow_dns_from_cidrs" {
  type        = list(any)
  description = "List of cidrs to allow private zone dns from"
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

variable "alarm_topics" {
  type        = list(string)
  description = "ARN of CloudWatch alarms"
}

variable "allowed_domains" {
  type        = list(string)
  description = "List of allowed private zone DNS lookup domains"
  default     = []
}

variable "public-records" {
  type        = map(list(string))
  description = <<EOF
    "map of {'<name> <type>' => [destinations]}"
    e.g.
      "dev-a A" = ["18.133.53.195"]
      "dev-cname CNAME" = ["foo.example.org"]
  EOF
  default     = {}
}
