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
# Shared Internet Gateway, created only when public subnets or the NAT subnet are configured.
resource "aws_internet_gateway" "this" {
  count  = length(var.public_subnets) > 0 || var.nat_subnet != null ? 1 : 0
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

# NAT egress: one shared NAT gateway (single AZ by design) for private-subnet internet access.
# Shared public subnet that only hosts the NAT gateway; application load balancers stay in their own subnets.
resource "aws_subnet" "nat" {
  count                   = var.nat_subnet == null ? 0 : 1
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.nat_subnet.cidr
  availability_zone       = var.nat_subnet.availability_zone
  map_public_ip_on_launch = false
  tags                    = { Name = "cc-nat" }
}
# NAT subnet route table with a default route to the Internet Gateway.
resource "aws_route_table" "nat" {
  count  = var.nat_subnet == null ? 0 : 1
  vpc_id = aws_vpc.this.id
  tags   = { Name = "cc-nat" }
}
# Default route from the NAT subnet to the Internet Gateway.
resource "aws_route" "nat_internet" {
  count                  = var.nat_subnet == null ? 0 : 1
  route_table_id         = aws_route_table.nat[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}
# Associate the NAT subnet with its route table.
resource "aws_route_table_association" "nat" {
  count          = var.nat_subnet == null ? 0 : 1
  subnet_id      = aws_subnet.nat[0].id
  route_table_id = aws_route_table.nat[0].id
}
# Stable public egress IP that vendors can allowlist.
resource "aws_eip" "nat" {
  count  = var.nat_subnet == null ? 0 : 1
  domain = "vpc"
  tags   = { Name = "cc-nat" }
}
# Single-AZ NAT gateway shared by UAT and Production private subnets.
resource "aws_nat_gateway" "this" {
  count         = var.nat_subnet == null ? 0 : 1
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.nat[0].id
  tags          = { Name = "cc-nat" }
  depends_on    = [aws_internet_gateway.this]
}
# Default route from every private subnet to the NAT gateway; more specific BGP routes still win for VPN prefixes.
resource "aws_route" "private_egress" {
  for_each               = var.nat_subnet == null ? {} : var.private_subnets
  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}
