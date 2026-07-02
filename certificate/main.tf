terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.14"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~>4.2.1"
    }
  }

  required_version = ">= 1.15.0"
}

locals {
  request_acm_certificate = var.request_acm_certificate ? 1 : 0
  create_self_signed_cert = var.request_acm_certificate ? 0 : 1
}


######################################################################
# Self signed certificate

resource "tls_private_key" "self_signed_cert_key" {
  count = local.create_self_signed_cert

  algorithm = "RSA"
}

resource "tls_self_signed_cert" "self_signed_cert" {
  count = local.create_self_signed_cert

  private_key_pem = tls_private_key.self_signed_cert_key[0].private_key_pem

  # One month, renew wirth 10 days to go
  early_renewal_hours   = 240
  validity_period_hours = 750

  subject {
    common_name  = var.domain_name
    organization = var.organisation
  }

  allowed_uses = ["key_encipherment", "digital_signature", "server_auth"]
}

resource "aws_acm_certificate" "self_signed_cert" {
  count = local.create_self_signed_cert

  private_key      = tls_private_key.self_signed_cert_key[0].private_key_pem
  certificate_body = tls_self_signed_cert.self_signed_cert[0].cert_pem
}


######################################################################
# Request AWS ACM certificate

resource "aws_acm_certificate" "certificate" {
  count = local.request_acm_certificate

  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = "DNS"
}
