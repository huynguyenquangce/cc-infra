# Connect AWS to GitHub OIDC using a shared provider across environments.
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.existing_provider_arn == null ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}
locals {
  stacks       = toset(["networking", "uat", "production"])
  provider_arn = var.existing_provider_arn != null ? var.existing_provider_arn : aws_iam_openid_connect_provider.github[0].arn
}
# Workflow AWS identity; the trust policy requires the exact repository and environment.
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
# Allow each role to write its own environment's state and manage the corresponding lock.
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
# Allow the networking workflow to manage VPC/VPN resources, routes, logs, and the network contract.
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
          "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway", "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
          "ec2:CreateRoute", "ec2:ReplaceRoute", "ec2:DeleteRoute",
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

# API Proxy deployment permissions: separate roles for UAT and Production.
locals {
  application_environments = toset(["uat", "production"])
  log_bucket_arns          = { for env in local.application_environments : env => "arn:aws:s3:::cc-${var.aws_account_id}-${var.aws_region}-${env}-api-proxy-logs" }
}
# Allow UAT/Production workflows to manage API Proxy resources within their assigned scope.
resource "aws_iam_role_policy" "application" {
  for_each = local.application_environments
  role     = aws_iam_role.terraform[each.key].id
  name     = "api-proxy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow", Action = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/cc/networking/contract"
      },
      {
        Effect   = "Allow", Action = ["elasticloadbalancing:Describe*", "ec2:Describe*", "acm:ListCertificates", "ssm:DescribeParameters"]
        Resource = "*", Condition = { StringEquals = { "aws:RequestedRegion" = var.aws_region } }
      },
      {
        Effect = "Allow"
        Action = ["elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:DeleteLoadBalancer", "elasticloadbalancing:ModifyLoadBalancerAttributes", "elasticloadbalancing:SetSecurityGroups", "elasticloadbalancing:SetSubnets", "elasticloadbalancing:SetIpAddressType", "elasticloadbalancing:CreateTargetGroup", "elasticloadbalancing:DeleteTargetGroup", "elasticloadbalancing:ModifyTargetGroup", "elasticloadbalancing:ModifyTargetGroupAttributes", "elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets", "elasticloadbalancing:CreateListener", "elasticloadbalancing:DeleteListener", "elasticloadbalancing:ModifyListener", "elasticloadbalancing:AddListenerCertificates", "elasticloadbalancing:RemoveListenerCertificates", "elasticloadbalancing:CreateRule", "elasticloadbalancing:DeleteRule", "elasticloadbalancing:ModifyRule", "elasticloadbalancing:SetRulePriorities", "elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags"]
        Resource = [
          "arn:aws:elasticloadbalancing:${var.aws_region}:${var.aws_account_id}:loadbalancer/app/cc-${each.key}-api-proxy/*",
          "arn:aws:elasticloadbalancing:${var.aws_region}:${var.aws_account_id}:targetgroup/cc-${each.key}-api-proxy/*",
          "arn:aws:elasticloadbalancing:${var.aws_region}:${var.aws_account_id}:listener/app/cc-${each.key}-api-proxy/*/*",
          "arn:aws:elasticloadbalancing:${var.aws_region}:${var.aws_account_id}:listener-rule/app/cc-${each.key}-api-proxy/*/*/*"
        ]
      },
      # Create groups only in the Terraform-managed shared networking VPC.
      {
        Effect    = "Allow", Action = ["ec2:CreateSecurityGroup"]
        Resource  = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:vpc/*"
        Condition = { StringEquals = { "aws:ResourceTag/Stack" = "networking", "aws:ResourceTag/Project" = "commerce-casino" } }
      },
      {
        Effect    = "Allow", Action = ["ec2:CreateSecurityGroup"]
        Resource  = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:security-group/*"
        Condition = { StringEquals = { "aws:RequestTag/Environment" = each.key, "aws:RequestTag/Stack" = each.key } }
      },
      {
        Effect    = "Allow"
        Action    = ["ec2:DeleteSecurityGroup", "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress", "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress", "ec2:ModifySecurityGroupRules"]
        Resource  = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:security-group/*"
        Condition = { StringEquals = { "aws:ResourceTag/Environment" = each.key, "aws:ResourceTag/Stack" = each.key } }
      },
      # Tagged rule creation also authorizes the new rule resource; it has no resource tags yet.
      {
        Effect    = "Allow", Action = ["ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress"]
        Resource  = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:security-group-rule/*"
        Condition = { StringEquals = { "aws:RequestTag/Environment" = each.key, "aws:RequestTag/Stack" = each.key } }
      },
      {
        Effect    = "Allow", Action = ["ec2:ModifySecurityGroupRules"]
        Resource  = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:security-group-rule/*"
        Condition = { StringEquals = { "aws:ResourceTag/Environment" = each.key, "aws:ResourceTag/Stack" = each.key } }
      },
      # Tag-on-create only: this cannot retag an existing Production SG as UAT.
      {
        Effect   = "Allow", Action = ["ec2:CreateTags"]
        Resource = ["arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:security-group/*", "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:security-group-rule/*"]
        Condition = { StringEquals = {
          "ec2:CreateAction"           = ["CreateSecurityGroup", "AuthorizeSecurityGroupIngress", "AuthorizeSecurityGroupEgress"]
          "aws:RequestTag/Environment" = each.key, "aws:RequestTag/Stack" = each.key
        } }
      },
      {
        Effect   = "Allow", Action = ["ec2:CreateTags", "ec2:DeleteTags"]
        Resource = ["arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:security-group/*", "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:security-group-rule/*"]
        Condition = {
          StringEquals                   = { "aws:ResourceTag/Environment" = each.key, "aws:ResourceTag/Stack" = each.key }
          "ForAllValues:StringNotEquals" = { "aws:TagKeys" = ["Environment", "Stack"] }
        }
      },
      {
        Effect    = "Allow", Action = ["iam:CreateServiceLinkedRole"]
        Resource  = "arn:aws:iam::${var.aws_account_id}:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing*"
        Condition = { StringEquals = { "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com" } }
      },
      {
        Effect    = "Allow", Action = ["acm:RequestCertificate"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = var.aws_region, "aws:RequestTag/Environment" = each.key } }
      },
      # Tagged certificate creation also checks AddTags before the resource tag exists.
      {
        Effect   = "Allow", Action = ["acm:AddTagsToCertificate"]
        Resource = "arn:aws:acm:${var.aws_region}:${var.aws_account_id}:certificate/*"
        Condition = {
          StringEquals = { "aws:RequestTag/Environment" = each.key }
          Null         = { "aws:ResourceTag/Environment" = "true" }
        }
      },
      {
        Effect   = "Allow", Action = ["acm:DescribeCertificate", "acm:GetCertificate", "acm:ListTagsForCertificate"]
        Resource = "arn:aws:acm:${var.aws_region}:${var.aws_account_id}:certificate/*"
      },
      {
        Effect    = "Allow", Action = ["acm:DeleteCertificate", "acm:AddTagsToCertificate", "acm:RemoveTagsFromCertificate", "acm:UpdateCertificateOptions"]
        Resource  = "arn:aws:acm:${var.aws_region}:${var.aws_account_id}:certificate/*"
        Condition = { StringEquals = { "aws:ResourceTag/Environment" = each.key } }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:CreateBucket", "s3:DeleteBucket", "s3:ListBucket", "s3:GetBucket*", "s3:GetBucketLocation", "s3:GetBucketPolicy", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:GetBucketTagging", "s3:PutBucketTagging", "s3:GetBucketPublicAccessBlock", "s3:PutBucketPublicAccessBlock", "s3:GetEncryptionConfiguration", "s3:PutEncryptionConfiguration", "s3:GetLifecycleConfiguration", "s3:PutLifecycleConfiguration", "s3:GetBucketOwnershipControls", "s3:PutBucketOwnershipControls", "s3:DeleteBucketOwnershipControls", "s3:GetBucketAcl", "s3:GetBucketVersioning", "s3:GetBucketLogging", "s3:GetAccelerateConfiguration", "s3:GetBucketRequestPayment", "s3:GetBucketObjectLockConfiguration", "s3:GetReplicationConfiguration", "s3:GetBucketCORS", "s3:GetBucketWebsite", "s3:ListBucketVersions"]
        Resource = local.log_bucket_arns[each.key]
      },
      {
        Effect   = "Allow", Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource = "${local.log_bucket_arns[each.key]}/*"
      },
      {
        Effect   = "Allow", Action = ["cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource", "cloudwatch:TagResource", "cloudwatch:UntagResource"]
        Resource = "arn:aws:cloudwatch:${var.aws_region}:${var.aws_account_id}:alarm:cc-${each.key}-api-proxy-*"
      },
      {
        Effect   = "Allow", Action = ["cloudwatch:PutDashboard", "cloudwatch:GetDashboard", "cloudwatch:DeleteDashboards"]
        Resource = "arn:aws:cloudwatch::${var.aws_account_id}:dashboard/cc-${each.key}-api-proxy"
      },
      {
        Effect   = "Allow", Action = ["sns:CreateTopic", "sns:DeleteTopic", "sns:GetTopicAttributes", "sns:SetTopicAttributes", "sns:Subscribe", "sns:Unsubscribe", "sns:GetSubscriptionAttributes", "sns:SetSubscriptionAttributes", "sns:ListSubscriptionsByTopic", "sns:ListTagsForResource", "sns:TagResource", "sns:UntagResource"]
        Resource = "arn:aws:sns:${var.aws_region}:${var.aws_account_id}:cc-${each.key}-api-proxy-alerts"
      }
    ]
  })
}
