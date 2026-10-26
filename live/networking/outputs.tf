output "vpc_id" { value = module.network.vpc_id }
output "subnet_ids" { value = module.network.subnet_ids }
output "vpn_connections" { value = module.vpn.connections }

output "public_subnet_ids_by_environment" { value = module.network.public_subnet_ids_by_environment }
output "nat_public_ip" {
  description = "Fixed egress IP for vendor allowlists (Squirrel)."
  value       = module.network.nat_public_ip
}
output "ecr_repository_urls" { value = { for k, r in module.ecr : k => r.repository_url } }
