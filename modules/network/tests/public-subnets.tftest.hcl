mock_provider "aws" {}
variables {
  vpc_cidr = "10.0.0.0/16"
  private_subnets = {
    private-a = { cidr = "10.0.10.0/24", availability_zone = "us-east-1a" }
    private-b = { cidr = "10.0.11.0/24", availability_zone = "us-east-1b" }
  }
}
run "legacy_private_only_deployment" {
  command = plan
  assert {
    condition     = length(aws_internet_gateway.this) == 0 && length(aws_subnet.public) == 0 && length(aws_subnet.private) == 2
    error_message = "Public network must be opt-in and leave existing private subnet addresses intact."
  }
}
run "two_az_public_network" {
  command = plan
  variables {
    public_subnets = {
      uat-a = { cidr = "10.0.100.0/24", availability_zone = "us-east-1a", environment = "uat" }
      uat-b = { cidr = "10.0.101.0/24", availability_zone = "us-east-1b", environment = "uat" }
    }
  }
  assert {
    condition     = length(aws_internet_gateway.this) == 1 && length(aws_route.internet) == 2 && length(aws_subnet.private) == 2
    error_message = "Both public AZs need IGW routes without replacing private resources."
  }
}
run "reject_single_az" {
  command = plan
  variables {
    public_subnets = {
      uat-a = { cidr = "10.0.100.0/24", availability_zone = "us-east-1a", environment = "uat" }
    }
  }
  expect_failures = [var.public_subnets]
}

run "reject_duplicate_az_for_same_alb" {
  command = plan
  variables {
    public_subnets = {
      uat-a = { cidr = "10.0.100.0/24", availability_zone = "us-east-1a", environment = "uat" }
      uat-b = { cidr = "10.0.101.0/24", availability_zone = "us-east-1b", environment = "uat" }
      uat-c = { cidr = "10.0.102.0/24", availability_zone = "us-east-1b", environment = "uat" }
    }
  }
  expect_failures = [var.public_subnets]
}
run "reject_subnets_too_small_for_alb" {
  command = plan
  variables {
    public_subnets = {
      uat-a = { cidr = "10.0.100.0/28", availability_zone = "us-east-1a", environment = "uat" }
      uat-b = { cidr = "10.0.101.0/28", availability_zone = "us-east-1b", environment = "uat" }
    }
  }
  expect_failures = [var.public_subnets]
}
