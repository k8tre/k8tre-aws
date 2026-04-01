#

variable "deployment_stage" {
  type        = number
  description = "Multi-stage deployment step, run with 0 the first time, then with 1."
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID"
}

variable "private_subnets" {
  type        = list(string)
  description = "Private subnet IDs"
}

variable "k8s_version" {
  type        = string
  description = "Kubernetes cluster version"
  default     = "1.35"
}

variable "k8s_api_cidrs" {
  type        = list(string)
  default     = ["127.0.0.1/8"]
  description = "CIDRs that have access to the K8s API"
}

variable "additional_security_groups" {
  type        = list(string)
  default     = []
  description = "Additional security groups to add to nodes"
}

# https://github.com/terraform-aws-modules/terraform-aws-eks/blob/v21.8.0/docs/network_connectivity.md
variable "cluster_security_group_additional_rules" {
  type        = map(any)
  default     = {}
  description = "Additional rules to add to the cluster security group which controls access to the control plane"
}

variable "number_azs" {
  type = number
  # Default to just one so we don't have to deal with node/volume affinity-
  # can't use EBS volumes across AZs
  default     = 1
  description = "Number of AZs to use"
  validation {
    condition     = var.number_azs >= 0 && var.number_azs <= length(var.private_subnets)
    error_message = "number_azs must be > 0 and <= number of private_subnets"
  }
}

variable "instance_type_wg1" {
  type        = string
  default     = "t3a.2xlarge"
  description = "Worker-group-1 EC2 instance type"
}

variable "use_bottlerocket" {
  type        = bool
  default     = false
  description = "Use Bottlerocket for worker nodes"
}

variable "root_volume_size" {
  type        = number
  default     = 100
  description = "Root volume size in GB"
}

variable "wg1_size" {
  type        = number
  default     = 2
  description = <<-EOT
    Worker-group-1 initial desired number of nodes.
    Note this has no effect after the cluster is provisioned:
    - https://github.com/terraform-aws-modules/terraform-aws-eks/issues/2030
    - https://github.com/bryantbiggs/eks-desired-size-hack
    Manually change the node group size in the AWS console instead.
    EOT
}

variable "wg1_max_size" {
  type        = number
  default     = 2
  description = "Worker-group-1 maximum number of nodes"
}

variable "autoupdate_ami" {
  type        = bool
  default     = false
  description = "Whether to autoupdate the AMI version when Terraform is run"
}

# variable "autoupdate_addons" {
#   type        = bool
#   default     = false
#   description = "Whether to autoupdate the versions of EKS addons when Terraform is run"
# }

variable "create_pod_identities" {
  type        = bool
  default     = false
  description = "Create additional EKS pod identities (EBS and EFS CSI and are always created)"
}

variable "hosted_zone_ids" {
  type        = list(string)
  default     = []
  description = "Route53 hosted zone IDs for External DNS, set to empty to disable"
}

variable "argocd_create_role" {
  type        = bool
  description = "Whether to create an ArgoCD pod identity and roles"
  default     = false
}

variable "argocd_namespace" {
  type        = string
  description = "Namespace of ArgoCD, used to create a pod identity"
  default     = "argocd"
}

variable "argocd_assume_eks_access_role" {
  type        = string
  description = "IAM role ARN that ArgoCD should assume to access the target cluster, default is eks-access role in this cluster"
  default     = ""
}

variable "argocd_serviceaccount_names" {
  type        = list(string)
  description = "Names of the ArgoCD serviceaccount, used to create a pod identity"
  # https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#argo-cd-management-role
  default = ["argocd-application-controller", "argocd-applicationset-controller", "argocd-server"]
}

variable "github_oidc_rolename" {
  type        = string
  description = "The name of the IAM role that will be created for the GitHub OIDC provider, set to null to disable"
  default     = null
}

variable "github_oidc_role_sub" {
  type        = list(string)
  description = "List of githubusercontent.com:sub repositories and refs allowed to use the OIDC role"
  # default     = ["repo:k8tre/k8tre:ref:refs/heads/main"]
  default = []
}

variable "additional_admin_principals" {
  type        = map(string)
  description = "Additional EKS admin pricipals"
  default     = {}
}

variable "gateway_api_version" {
  type        = string
  description = "Gateway API CRD version"
  default     = "1.4.1"
}

variable "cilium_version" {
  type        = string
  description = "Cilium version"
  default     = "1.19.1"
}
