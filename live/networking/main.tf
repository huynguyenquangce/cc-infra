# Provision the shared VPC, subnets, and routes before deploying applications.
module "network" {
  source          = "../../modules/network"
  vpc_cidr        = var.vpc_cidr
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets
  nat_subnet      = var.nat_subnet
}
# Connect the shared VPC to customer networks and enable route propagation.
module "vpn" {
  source                  = "../../modules/vpn"
  vpc_id                  = module.network.vpc_id
  route_table_ids         = merge(module.network.route_table_ids, { for k, id in module.network.public_route_table_ids : "public/${k}" => id })
  amazon_side_asn         = var.amazon_side_asn
  customer_gateways       = var.customer_gateways
  phase1_lifetime_seconds = var.phase1_lifetime_seconds
  phase2_lifetime_seconds = var.phase2_lifetime_seconds
  alarm_action_arns       = var.alarm_action_arns
}
# Private AWS API access for ECS tasks, shared by UAT and Production.
module "vpc_endpoints" {
  count           = length(var.vpc_endpoint_subnet_keys) > 0 ? 1 : 0
  source          = "../../modules/vpc-endpoints"
  vpc_id          = module.network.vpc_id
  vpc_cidr        = var.vpc_cidr
  aws_region      = var.aws_region
  subnet_ids      = [for k in var.vpc_endpoint_subnet_keys : module.network.subnet_ids[k]]
  route_table_ids = values(module.network.route_table_ids)
}
# Shared image registries: the same image digest is promoted from UAT to Production.
module "ecr" {
  for_each = var.ecr_repositories
  source   = "../../modules/ecr"
  name     = each.key
}
# Publish IDs, not access to the entire networking state (which may contain VPN PSKs).
# Publish networking IDs through SSM so applications do not need access to state containing VPN PSKs.
resource "aws_ssm_parameter" "network_contract" {
  name = "/cc/networking/contract"
  type = "String"
  value = jsonencode({
    version                          = 3
    vpc_id                           = module.network.vpc_id
    vpc_cidr                         = var.vpc_cidr
    subnet_ids                       = module.network.subnet_ids
    route_table_ids                  = module.network.route_table_ids
    public_subnet_ids_by_environment = module.network.public_subnet_ids_by_environment
    public_route_table_ids           = module.network.public_route_table_ids
    nat_gateway_id                   = module.network.nat_gateway_id
    vpc_endpoint_security_group_id   = try(module.vpc_endpoints[0].security_group_id, null)
    s3_prefix_list_id                = try(module.vpc_endpoints[0].s3_prefix_list_id, null)
    ecr_repository_urls              = { for k, r in module.ecr : k => r.repository_url }
  })
}
