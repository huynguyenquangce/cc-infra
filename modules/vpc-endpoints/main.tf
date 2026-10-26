# Private access to AWS APIs for ECS tasks: ECR, CloudWatch Logs, Secrets Manager, and S3.
# Endpoint ENIs accept HTTPS only from inside the VPC.
resource "aws_security_group" "endpoints" {
  name        = "cc-vpc-endpoints"
  description = "HTTPS from the shared VPC to AWS interface endpoints"
  vpc_id      = var.vpc_id
  tags        = { Name = "cc-vpc-endpoints" }
}
# Allow HTTPS from any workload inside the VPC.
resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.endpoints.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}
# Interface endpoints with private DNS so SDKs resolve the regional hostnames to the endpoint ENIs.
resource "aws_vpc_endpoint" "interface" {
  for_each            = var.interface_services
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = { Name = "cc-${each.key}" }
}
# Free S3 gateway endpoint so image layer downloads bypass the NAT gateway.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.route_table_ids
  tags              = { Name = "cc-s3" }
}
