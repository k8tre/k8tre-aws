output "kms_id" {
  value = aws_kms_key.ecs.id
}

output "kms_arn" {
  value = aws_kms_key.ecs.arn
}

output "ecs_cluster" {
  value = aws_ecs_cluster.ecs.name
}

output "discovery_id" {
  value = aws_service_discovery_private_dns_namespace.ecs.id
}
