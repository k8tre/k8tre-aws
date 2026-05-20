variable "name" {
  type        = string
  description = "Deployment name, used to prefix some resources"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR"
}

variable "public_subnet" {
  type        = string
  description = "Subnet ID"
}

variable "private_subnet_route_table_ids" {
  type        = list(string)
  description = "Update these route tables to use the proxy"
}

variable "private_subnet_route_table_cidrs" {
  type        = list(string)
  description = "Route these CIDRs to the transparent proxy, set to [] to not update"
  default     = ["0.0.0.0/0"]
}

variable "s3_config_bucket" {
  type        = string
  description = "An existing S3 bucket name used for storing config files"
}

variable "allowed_domains_re" {
  type        = list(string)
  default     = []
  description = "Allowed domains (HTTP and HTTPS)"
}

variable "log_group_retention_days" {
  type        = number
  default     = 365
  description = "Number of days to retain access logs for, see AWS documentation for allowed values"
}
