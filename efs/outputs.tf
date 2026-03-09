output "file_system_id" {
  description = "EFS file system ID"
  value       = aws_efs_file_system.efs.id
}
