output "instance_id" {
  description = "Proxy EC2 instance ID"
  value       = aws_instance.transparent_proxy.id
}
