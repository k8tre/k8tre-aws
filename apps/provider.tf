terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.14"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "3.0.2"
    }

    http = {
      source  = "hashicorp/http"
      version = "~> 3.5"
    }
  }

  required_version = ">= 1.10.0"

  # Must match aws_s3_bucket.bucket in ../bootstrap/backend.tf
  backend "s3" {
    bucket       = "k8tre-tfstate-0123456789abcdef"
    key          = "tfstate/dev/k8tre-dev-apps"
    region       = "eu-west-2"
    use_lockfile = true
  }
}


provider "kubernetes" {
  alias                  = "k8tre-dev"
  host                   = data.aws_eks_cluster.deployment.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.deployment.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.deployment.token
}

provider "helm" {
  alias = "k8tre-dev"
  kubernetes = {
    host                   = data.aws_eks_cluster.deployment.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.deployment.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.deployment.token
  }
}


provider "kubernetes" {
  alias                  = "k8tre-dev-argocd"
  host                   = data.aws_eks_cluster.argocd.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.argocd.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.argocd.token
}

provider "helm" {
  alias = "k8tre-dev-argocd"
  kubernetes = {
    host                   = data.aws_eks_cluster.argocd.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.argocd.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.argocd.token
  }
}
