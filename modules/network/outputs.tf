output "vpc_id" { value = aws_vpc.this.id }
output "subnet_ids" { value = { for k, s in aws_subnet.private : k => s.id } }
output "route_table_ids" { value = { for k, r in aws_route_table.private : k => r.id } }
