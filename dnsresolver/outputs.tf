output "private-zone-id" {
  value = aws_route53_zone.private-zone.id
}

output "public-zone-id" {
  value = aws_route53_zone.public-zone.id
}

output "public-primary-nameserver" {
  value = aws_route53_zone.public-zone.primary_name_server
}

output "public-nameservers" {
  value = aws_route53_zone.public-zone.name_servers
}
