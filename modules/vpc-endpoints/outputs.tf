output "security_group_id" { value = aws_security_group.endpoints.id }
output "s3_prefix_list_id" { value = aws_vpc_endpoint.s3.prefix_list_id }
output "interface_endpoint_ids" { value = { for k, e in aws_vpc_endpoint.interface : k => e.id } }
