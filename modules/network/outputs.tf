output "vpc_id" { value = aws_vpc.this.id }
output "subnet_ids" { value = { for k, s in aws_subnet.private : k => s.id } }
output "route_table_ids" { value = { for k, r in aws_route_table.private : k => r.id } }

output "public_subnet_ids_by_environment" {
  value = { for env in ["uat", "production"] : env => {
    for name, subnet in aws_subnet.public : name => subnet.id if var.public_subnets[name].environment == env
  } }
}
output "public_route_table_ids" { value = { for k, r in aws_route_table.public : k => r.id } }

output "nat_gateway_id" { value = one(aws_nat_gateway.this[*].id) }
output "nat_public_ip" { value = one(aws_eip.nat[*].public_ip) }
