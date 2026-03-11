variable "name" {
  type        = string
  description = "Name used for resources"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID"
}

variable "subnets" {
  type        = list(string)
  description = "List of subnet IDs"
}
