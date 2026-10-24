# Shared VPC for networking and application environments.
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "cc-shared" }
}
# Shared private subnets; automatic public IP assignment is disabled.
resource "aws_subnet" "private" {
  for_each                = var.private_subnets
  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = false
  tags                    = { Name = "cc-${each.key}" }
}
# Dedicated route table per private subnet, receiving propagated VPN routes.
resource "aws_route_table" "private" {
  for_each = var.private_subnets
  vpc_id   = aws_vpc.this.id
  tags     = { Name = "cc-${each.key}" }
}
# Associate each subnet with its corresponding route table.
resource "aws_route_table_association" "private" {
  for_each       = var.private_subnets
  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

# Public ALB networking: environment-specific subnets, an IGW, and internet routes.
# Shared Internet Gateway, created only when public subnets are configured.
resource "aws_internet_gateway" "this" {
  count  = length(var.public_subnets) > 0 ? 1 : 0
  vpc_id = aws_vpc.this.id
  tags   = { Name = "cc-shared-igw" }
}
# Public ALB subnets allocated by environment and availability zone.
resource "aws_subnet" "public" {
  for_each                = var.public_subnets
  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = false
  tags                    = { Name = "cc-${each.key}", Environment = each.value.environment }
}
# Public ALB subnet route tables for internet access and customer networks over VPN.
resource "aws_route_table" "public" {
  for_each = var.public_subnets
  vpc_id   = aws_vpc.this.id
  tags     = { Name = "cc-${each.key}-public", Environment = each.value.environment }
}
# Default route from each public subnet to the Internet Gateway.
resource "aws_route" "internet" {
  for_each               = var.public_subnets
  route_table_id         = aws_route_table.public[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}
# Associate each subnet with its corresponding route table.
resource "aws_route_table_association" "public" {
  for_each       = var.public_subnets
  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public[each.key].id
}
