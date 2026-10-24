output "vpc_id" { value = module.network.vpc_id }
output "subnet_ids" { value = module.network.subnet_ids }
output "vpn_connections" { value = module.vpn.connections }

output "public_subnet_ids_by_environment" { value = module.network.public_subnet_ids_by_environment }
