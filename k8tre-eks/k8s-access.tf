# Roles to allow access to EKS

# Allow GitHub workflows to access AWS using OIDC (no hardcoded credentials)
# https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services

# Use in conjunction with a role, and
# https://github.com/aws-actions/configure-aws-credentials
resource "aws_iam_openid_connect_provider" "github_oidc" {
  count = var.github_oidc_rolename == null ? 0 : 1

  client_id_list = [
    "sts.amazonaws.com",
  ]
  tags = {
    "Name" = "github-oidc"
  }
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1"
  ]
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_policy" "eks_access" {
  name        = "${var.cluster_name}-eks-access"
  description = "Kubernetes EKS access to ${var.cluster_name}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["eks:DescribeCluster"]
        Effect   = "Allow"
        Resource = module.eks.cluster_arn
      }
    ]
  })
}

resource "aws_iam_role" "github_oidc" {
  count = var.github_oidc_rolename == null ? 0 : 1

  name = var.github_oidc_rolename

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_oidc[0].arn
        }
        Condition = {
          StringLike = {
            # GitHub repositories and refs allowed to use this role
            "token.actions.githubusercontent.com:sub" = var.github_oidc_role_sub
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_oidc" {
  count = var.github_oidc_rolename == null ? 0 : 1

  role       = aws_iam_role.github_oidc[0].name
  policy_arn = aws_iam_policy.eks_access.arn
}

# IAM role that can be assumed by anyone in the AWS account (assuming they have sufficient permissions)
resource "aws_iam_role" "eks_access" {
  name = "${var.cluster_name}-eks-access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "sts:AssumeRole",
          "sts:TagSession",
        ]
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.aws_account_id}:root"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_access" {
  role       = aws_iam_role.eks_access.name
  policy_arn = aws_iam_policy.eks_access.arn
}

# Create a pod identity role that ArgoCD can assume if running outside the cluster
#
# TODO: Currently this assumes the ArgoCD EKS is in the same account as the
# K8TRE cluster. In future we should support cross-account access, which means
# ArgoCD will need permission to assume a role in a different account.
#
# See https://github.com/argoproj/argo-cd/issues/17064#issuecomment-2271623966
# for details
#
# This requires multiple roles:
# - A PodIdentity role: The ArgoCD ServiceAccounts can run as this role
# - ArgoCD deployment role: Role that has permissions to deploy ArgoCD applications,
#   this role is assumed by the PodIdentity role


resource "aws_iam_policy" "argocd_pod_identity" {
  count = var.argocd_create_role ? 1 : 0

  name        = "${var.cluster_name}-argocd-pod"
  description = "Kubernetes EKS ArgoCD pod identity"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "sts:AssumeRole",
          "sts:TagSession",
        ]
        Effect   = "Allow"
        Resource = length(var.argocd_assume_eks_access_role) > 0 ? var.argocd_assume_eks_access_role : aws_iam_role.eks_access.arn
      }
    ]
  })
}

resource "aws_iam_role" "argocd_pod_identity" {
  count = var.argocd_create_role ? 1 : 0

  name = "${var.cluster_name}-argocd-pod"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          AWS = module.eks_pod_identity_argocd_access[count.index].iam_role_arn
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "argocd_pod_identity" {
  count = var.argocd_create_role ? 1 : 0

  role       = aws_iam_role.argocd_pod_identity[count.index].name
  policy_arn = aws_iam_policy.argocd_pod_identity[count.index].arn
}


# https://github.com/terraform-aws-modules/terraform-aws-eks-pod-identity/tree/v2.2.1?tab=readme-ov-file#custom-iam-role
module "eks_pod_identity_argocd_access" {
  count = var.argocd_create_role ? 1 : 0

  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.7.0"
  name    = "${var.cluster_name}-argocd"

  # attach_custom_policy      = true
  # source_policy_documents   = [data.aws_iam_policy_document.source.json]
  # override_policy_documents = [data.aws_iam_policy_document.override.json]
  additional_policy_arns = {
    eks_access = aws_iam_policy.argocd_pod_identity[count.index].arn
  }

  # Associate identity with the ServiceAccount that will be used by ArgoCD
  # to access this cluster
  association_defaults = {
    # namespace       = var.argocd_namespace
    # service_account = item
    cluster_name = var.cluster_name
  }

  associations = {
    for name in var.argocd_serviceaccount_names :
    name => {
      namespace       = var.argocd_namespace
      service_account = name
    }

  }
}
