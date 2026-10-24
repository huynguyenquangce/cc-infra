# Provision the shared VPC, subnets, and routes before deploying applications.
module "network" {
  source          = "../../modules/network"
  vpc_cidr        = var.vpc_cidr
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets
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
# Publish IDs, not access to the entire networking state (which may contain VPN PSKs).
# Publish networking IDs through SSM so applications do not need access to state containing VPN PSKs.
resource "aws_ssm_parameter" "network_contract" {
  name = "/cc/networking/contract"
  type = "String"
  value = jsonencode({
    version                          = 2
    vpc_id                           = module.network.vpc_id
    vpc_cidr                         = var.vpc_cidr
    subnet_ids                       = module.network.subnet_ids
    route_table_ids                  = module.network.route_table_ids
    public_subnet_ids_by_environment = module.network.public_subnet_ids_by_environment
    public_route_table_ids           = module.network.public_route_table_ids
  })
}
