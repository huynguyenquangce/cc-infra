resource "aws_iam_openid_connect_provider" "github" {
  count          = var.existing_provider_arn == null ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}
locals {
  stacks       = toset(["networking"])
  provider_arn = var.existing_provider_arn != null ? var.existing_provider_arn : aws_iam_openid_connect_provider.github[0].arn
}
resource "aws_iam_role" "terraform" {
  for_each             = local.stacks
  name                 = "cc-terraform-${each.key}"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = { Federated = local.provider_arn }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = "repo:${var.repository}:environment:${each.key}"
      } }
    }]
  })
}
resource "aws_iam_role_policy" "state" {
  for_each = local.stacks
  role     = aws_iam_role.terraform[each.key].id
  name     = "state-access"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow", Action = ["s3:ListBucket"], Resource = var.state_bucket_arn
        Condition = { StringLike = { "s3:prefix" = ["${each.key}/*"] } }
      },
      {
        Effect   = "Allow", Action = ["s3:GetObject", "s3:PutObject"]
        Resource = "${var.state_bucket_arn}/${each.key}/terraform.tfstate"
      },
      {
        Effect   = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${var.state_bucket_arn}/${each.key}/terraform.tfstate.tflock"
      }
    ]
  })
}
# VPN phase only. No IAM, application deployment, or bucket administration permissions.
resource "aws_iam_role_policy" "networking" {
  role = aws_iam_role.terraform["networking"].id
  name = "networking-vpn"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:Describe*", "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute",
          "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
          "ec2:CreateRouteTable", "ec2:DeleteRouteTable", "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
          "ec2:CreateTags", "ec2:DeleteTags", "ec2:CreateVpnGateway", "ec2:DeleteVpnGateway",
          "ec2:AttachVpnGateway", "ec2:DetachVpnGateway", "ec2:EnableVgwRoutePropagation", "ec2:DisableVgwRoutePropagation",
          "ec2:CreateCustomerGateway", "ec2:DeleteCustomerGateway",
          "ec2:CreateVpnConnection", "ec2:DeleteVpnConnection", "ec2:ModifyVpnConnection",
          "ec2:ModifyVpnConnectionOptions", "ec2:ModifyVpnTunnelOptions", "ec2:ModifyVpnTunnelCertificate"
        ]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = var.aws_region } }
      },
      # DescribeParameters lists metadata and does not support parameter-level ARNs.
      # Keep value reads/writes scoped to /cc/networking/* in the next statement.
      {
        Effect    = "Allow"
        Action    = ["ssm:DescribeParameters"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = var.aws_region } }
      },
      {
        Effect   = "Allow", Action = ["ssm:PutParameter", "ssm:GetParameter", "ssm:GetParameters", "ssm:DeleteParameter", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource"]
        Resource = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/cc/networking/*"
      },
      {
        Effect   = "Allow", Action = ["logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy", "logs:TagResource", "logs:UntagResource", "logs:ListTagsForResource"]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/vendedlogs/cc/vpn/*"
      },
      {
        Effect   = "Allow", Action = ["logs:DescribeLogGroups", "logs:CreateLogDelivery", "logs:DeleteLogDelivery", "logs:UpdateLogDelivery", "logs:GetLogDelivery", "logs:ListLogDeliveries", "logs:PutResourcePolicy", "logs:DescribeResourcePolicies"]
        Resource = "*"
      },
      {
        Effect   = "Allow", Action = ["cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource", "cloudwatch:TagResource", "cloudwatch:UntagResource"]
        Resource = "arn:aws:cloudwatch:${var.aws_region}:${var.aws_account_id}:alarm:cc-vpn-*"
      }
    ]
  })
}
