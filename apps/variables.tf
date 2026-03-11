
# Update this to point to your terraform state from ../main.tf
data "terraform_remote_state" "k8tre" {
  backend = "s3"

  config = {
    bucket = "k8tre-tfstate-0123456789abcdef"
    key    = "tfstate/dev/k8tre-dev"
    region = "eu-west-2"
  }
}

variable "k8tre_cluster_labels" {
  type = map(string)
  default = {
    environment     = "dev"
    secret-store    = "aws"
    vendor          = "aws"
    skip-metallb    = "true"
    external-domain = "k8tre-dev.internal"
    external-dns    = "aws"
  }
  description = "Argocd labels applied to K8TRE cluster"
}

variable "k8tre_cluster_label_overrides" {
  type        = map(string)
  default     = {}
  description = "Additional labels merged with k8tre_cluster_labels and applied to K8TRE cluster"
}

variable "install_k8tre" {
  type        = bool
  default     = true
  description = "Install K8TRE root app-of-apps"
}

variable "k8tre_github_repo" {
  type        = string
  default     = "k8tre/k8tre"
  description = "K8TRE GitHub organisation and repository to install"
}

variable "k8tre_github_ref" {
  type        = string
  default     = "main"
  description = "K8TRE git ref (commit/branch/tag)"
}

variable "efs_name" {
  type        = string
  description = "EFS name creation token, must match module.efs var.name"
}

# Cluster where K8TRE wil be deployed
data "aws_eks_cluster" "deployment" {
  name = data.terraform_remote_state.k8tre.outputs.k8tre_cluster_name
}
data "aws_eks_cluster_auth" "deployment" {
  name = data.terraform_remote_state.k8tre.outputs.k8tre_cluster_name
}

# Cluster where ArgoCD is deployed
data "aws_eks_cluster" "argocd" {
  name = data.terraform_remote_state.k8tre.outputs.k8tre_argocd_cluster_name
}
data "aws_eks_cluster_auth" "argocd" {
  name = data.terraform_remote_state.k8tre.outputs.k8tre_argocd_cluster_name
}
