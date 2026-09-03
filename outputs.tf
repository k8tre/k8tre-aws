
output "kubeconfig_command_k8tre-dev" {
  description = "Create kubeconfig for k8tre-dev"
  value       = "aws eks update-kubeconfig --name ${module.k8tre-eks.cluster_name}"
}

output "kubeconfig_command_k8tre-argocd-dev" {
  description = "Create kubeconfig for k8tre-argocd-dev"
  value       = "aws eks update-kubeconfig --name ${module.k8tre-argocd-eks.cluster_name}"
}

output "name" {
  description = "Name used for most resources"
  value       = var.name
}

output "efs_token" {
  description = "EFS name creation token"
  value       = local.efs_token
}

output "service_access_prefix_list" {
  description = "ID of the prefix list that can access services running on K8s"
  value       = aws_ec2_managed_prefix_list.service_access_cidrs.id
}

output "vpc_cidr" {
  description = "VPC CIDR"
  value       = module.vpc.vpc_cidr_block
}

output "k8tre_cluster_name" {
  description = "K8TRE dev cluster name"
  value       = module.k8tre-eks.cluster_name
}

output "k8tre_argocd_cluster_name" {
  description = "K8TRE dev cluster name"
  value       = module.k8tre-argocd-eks.cluster_name
}

output "k8tre_eks_access_role" {
  description = "K8TRE EKS deployment role ARN"
  value       = module.k8tre-eks.eks_access_role
}

output "dns_validation_records" {
  description = "DNS validation records to be created for ACM certificate"
  value       = module.certificate[*].dns_validation_records
}

output "proxy_ec2_instance_id" {
  description = "Transparent proxy EC2 instance ID if enabled"
  value       = module.transparent-proxy[*].instance_id
}

output "s3_studydata_bucket_name" {
  description = "Name of the S3 studydata bucket"
  value       = aws_s3_bucket.studydata.id
}
