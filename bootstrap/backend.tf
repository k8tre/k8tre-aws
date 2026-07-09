# Initial setup of S3 bucket to store tfstate file

variable "region" {
  type        = string
  default     = "eu-west-2"
  description = "AWS region"
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.14"
    }
  }
  required_version = ">= 1.15.0"
}

# Configure the AWS Provider
provider "aws" {
  region = var.region
  default_tags {
    tags = {
      "owner" : "trevolution"
    }
  }
}

resource "aws_s3_bucket" "bucket" {
  # Generate a random bucket name, e.g. `openssl rand -hex 8`
  bucket = "k8tre-tfstate-0123456789abcdef"
}

resource "aws_s3_bucket_versioning" "bucket_versioning" {
  bucket = aws_s3_bucket.bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "public-block" {
  bucket                  = aws_s3_bucket.bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
