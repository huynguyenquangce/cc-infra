mock_provider "aws" {}
variables {
  vpc_cidr = "10.0.0.0/16"
  private_subnets = {
    private-a = { cidr = "10.0.10.0/24", availability_zone = "us-east-1a" }
    private-b = { cidr = "10.0.11.0/24", availability_zone = "us-east-1b" }
  }
}
run "nat_is_opt_in" {
  command = plan
  assert {
    condition     = length(aws_nat_gateway.this) == 0 && length(aws_route.private_egress) == 0 && length(aws_internet_gateway.this) == 0
    error_message = "Private subnets must have no internet route until a NAT subnet is configured."
  }
}
run "nat_routes_every_private_subnet" {
  command = plan
  variables {
    nat_subnet = { cidr = "10.0.1.0/28", availability_zone = "us-east-1a" }
  }
  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_internet_gateway.this) == 1 && length(aws_route.private_egress) == 2 && length(aws_route.nat_internet) == 1
    error_message = "One NAT gateway must serve both private route tables through the shared IGW."
  }
}
run "reject_nat_subnet_too_small" {
  command = plan
  variables {
    nat_subnet = { cidr = "10.0.1.0/29", availability_zone = "us-east-1a" }
  }
  expect_failures = [var.nat_subnet]
}
