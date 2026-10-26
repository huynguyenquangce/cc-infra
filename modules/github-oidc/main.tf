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
# Shared MCP networking: NAT egress, VPC endpoints with their security group, and shared ECR repositories.
resource "aws_iam_role_policy" "networking_shared_services" {
  role = aws_iam_role.terraform["networking"].id
  name = "networking-shared-services"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AllocateAddress", "ec2:ReleaseAddress", "ec2:DisassociateAddress", "ec2:CreateNatGateway", "ec2:DeleteNatGateway",
          "ec2:CreateVpcEndpoint", "ec2:DeleteVpcEndpoints", "ec2:ModifyVpcEndpoint", "ec2:GetManagedPrefixListEntries"
        ]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = var.aws_region } }
      },
      # Interface endpoints with private DNS associate an AWS-managed private hosted zone with the VPC.
      { Effect = "Allow", Action = ["route53:AssociateVPCWithHostedZone"], Resource = "*" },
      # Endpoint security group: created and changed only while tagged as the networking stack.
      {
        Effect    = "Allow", Action = ["ec2:CreateSecurityGroup", "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress"]
        Resource  = ["arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:security-group/*", "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:security-group-rule/*"]
        Condition = { StringEquals = { "aws:RequestTag/Stack" = "networking" } }
      },
      {
        Effect    = "Allow", Action = ["ec2:CreateSecurityGroup"]
        Resource  = "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:vpc/*"
        Condition = { StringEquals = { "aws:ResourceTag/Stack" = "networking" } }
      },
      {
        Effect    = "Allow", Action = ["ec2:DeleteSecurityGroup", "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress", "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress", "ec2:ModifySecurityGroupRules"]
        Resource  = ["arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:security-group/*", "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:security-group-rule/*"]
        Condition = { StringEquals = { "aws:ResourceTag/Stack" = "networking" } }
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:CreateRepository", "ecr:DeleteRepository", "ecr:DescribeRepositories", "ecr:PutLifecyclePolicy", "ecr:GetLifecyclePolicy", "ecr:DeleteLifecyclePolicy", "ecr:PutImageScanningConfiguration", "ecr:PutImageTagMutability", "ecr:GetRepositoryPolicy", "ecr:TagResource", "ecr:UntagResource", "ecr:ListTagsForResource"]
        Resource = "arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/cc-*"
      }
    ]
  })
}

# Application deployment permissions (API Proxy + shared CloudFront edge): separate roles for UAT and Production.
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
        Effect   = "Allow", Action = ["elasticloadbalancing:Describe*", "ec2:Describe*", "ec2:GetManagedPrefixListEntries", "ssm:DescribeParameters"]
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
      # Shared edge for API Proxy and MCP. CloudFront IDs are generated and the service has no
      # resource-tag conditions, so distributions and VPC origins are scoped per account.
      {
        Effect   = "Allow"
        Action   = ["cloudfront:CreateDistribution", "cloudfront:CreateDistributionWithTags", "cloudfront:UpdateDistribution", "cloudfront:DeleteDistribution", "cloudfront:GetDistribution", "cloudfront:GetDistributionConfig", "cloudfront:CreateVpcOrigin", "cloudfront:UpdateVpcOrigin", "cloudfront:DeleteVpcOrigin", "cloudfront:GetVpcOrigin", "cloudfront:TagResource", "cloudfront:UntagResource", "cloudfront:ListTagsForResource"]
        Resource = ["arn:aws:cloudfront::${var.aws_account_id}:distribution/*", "arn:aws:cloudfront::${var.aws_account_id}:vpcorigin/*"]
      },
      {
        Effect    = "Allow", Action = ["iam:CreateServiceLinkedRole"]
        Resource  = "arn:aws:iam::${var.aws_account_id}:role/aws-service-role/vpcorigin.cloudfront.amazonaws.com/*"
        Condition = { StringEquals = { "iam:AWSServiceName" = "vpcorigin.cloudfront.amazonaws.com" } }
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

# MCP Server deployment permissions for the UAT/Production Terraform roles.
# Customer-managed policies keep the roles under the 10,240-character inline policy quota.
# Compute: ECS, auto scaling, task roles, and the internal MCP ALB (CloudFront is in the shared application policy).
resource "aws_iam_policy" "mcp_compute" {
  for_each = local.application_environments
  name     = "cc-terraform-${each.key}-mcp-compute"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecs:CreateCluster", "ecs:DeleteCluster", "ecs:DescribeClusters", "ecs:UpdateCluster", "ecs:PutClusterCapacityProviders", "ecs:CreateService", "ecs:UpdateService", "ecs:DeleteService", "ecs:DescribeServices", "ecs:TagResource", "ecs:UntagResource", "ecs:ListTagsForResource"]
        Resource = ["arn:aws:ecs:${var.aws_region}:${var.aws_account_id}:cluster/cc-${each.key}-mcp", "arn:aws:ecs:${var.aws_region}:${var.aws_account_id}:service/cc-${each.key}-mcp/*", "arn:aws:ecs:${var.aws_region}:${var.aws_account_id}:task-definition/cc-${each.key}-mcp:*"]
      },
      # Task definition registration and auto scaling APIs do not support resource-level scoping.
      {
        Effect    = "Allow", Action = ["ecs:RegisterTaskDefinition", "ecs:DeregisterTaskDefinition", "ecs:DescribeTaskDefinition", "application-autoscaling:*ScalableTarget*", "application-autoscaling:*ScalingPolic*", "application-autoscaling:TagResource", "application-autoscaling:ListTagsForResource", "ec2:GetManagedPrefixListEntries"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = var.aws_region } }
      },
      {
        Effect   = "Allow"
        Action   = ["iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags", "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole"]
        Resource = "arn:aws:iam::${var.aws_account_id}:role/cc-${each.key}-mcp-*"
      },
      {
        Effect    = "Allow", Action = ["iam:PassRole"]
        Resource  = "arn:aws:iam::${var.aws_account_id}:role/cc-${each.key}-mcp-*"
        Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
      },
      {
        Effect    = "Allow", Action = ["iam:CreateServiceLinkedRole"]
        Resource  = "arn:aws:iam::${var.aws_account_id}:role/aws-service-role/*"
        Condition = { StringEquals = { "iam:AWSServiceName" = ["ecs.amazonaws.com", "ecs.application-autoscaling.amazonaws.com"] } }
      },
      {
        Effect = "Allow"
        Action = ["elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:DeleteLoadBalancer", "elasticloadbalancing:ModifyLoadBalancerAttributes", "elasticloadbalancing:SetSecurityGroups", "elasticloadbalancing:SetSubnets", "elasticloadbalancing:CreateTargetGroup", "elasticloadbalancing:DeleteTargetGroup", "elasticloadbalancing:ModifyTargetGroup", "elasticloadbalancing:ModifyTargetGroupAttributes", "elasticloadbalancing:CreateListener", "elasticloadbalancing:DeleteListener", "elasticloadbalancing:ModifyListener", "elasticloadbalancing:CreateRule", "elasticloadbalancing:DeleteRule", "elasticloadbalancing:ModifyRule", "elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags"]
        Resource = [
          "arn:aws:elasticloadbalancing:${var.aws_region}:${var.aws_account_id}:loadbalancer/app/cc-${each.key}-mcp/*",
          "arn:aws:elasticloadbalancing:${var.aws_region}:${var.aws_account_id}:targetgroup/cc-${each.key}-mcp/*",
          "arn:aws:elasticloadbalancing:${var.aws_region}:${var.aws_account_id}:listener/app/cc-${each.key}-mcp/*/*",
          "arn:aws:elasticloadbalancing:${var.aws_region}:${var.aws_account_id}:listener-rule/app/cc-${each.key}-mcp/*/*/*"
        ]
      }
    ]
  })
}
# Configuration and monitoring: secret containers, image parameter, logs, alarms, and notifications.
resource "aws_iam_policy" "mcp_operations" {
  for_each = local.application_environments
  name     = "cc-terraform-${each.key}-mcp-operations"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Secret metadata only: no GetSecretValue, so Terraform never reads vendor credentials.
      {
        Effect   = "Allow", Action = ["secretsmanager:CreateSecret", "secretsmanager:DeleteSecret", "secretsmanager:DescribeSecret", "secretsmanager:UpdateSecret", "secretsmanager:RestoreSecret", "secretsmanager:GetResourcePolicy", "secretsmanager:TagResource", "secretsmanager:UntagResource"]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:cc-mcp/${each.key}/*"
      },
      {
        Effect   = "Allow", Action = ["ssm:PutParameter", "ssm:GetParameter", "ssm:GetParameters", "ssm:DeleteParameter", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource"]
        Resource = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/cc/${each.key}/mcp/*"
      },
      {
        Effect   = "Allow", Action = ["logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy", "logs:TagResource", "logs:UntagResource", "logs:ListTagsForResource"]
        Resource = ["arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/ecs/mcp-server/${each.key}", "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/ecs/mcp-server/${each.key}:*"]
      },
      { Effect = "Allow", Action = ["logs:DescribeLogGroups"], Resource = "*" },
      {
        Effect   = "Allow"
        Action   = ["s3:CreateBucket", "s3:DeleteBucket", "s3:ListBucket", "s3:GetBucket*", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutBucketTagging", "s3:PutBucketPublicAccessBlock", "s3:GetEncryptionConfiguration", "s3:PutEncryptionConfiguration", "s3:GetLifecycleConfiguration", "s3:PutLifecycleConfiguration", "s3:PutBucketOwnershipControls", "s3:DeleteBucketOwnershipControls", "s3:GetAccelerateConfiguration", "s3:GetReplicationConfiguration", "s3:ListBucketVersions"]
        Resource = "arn:aws:s3:::cc-${var.aws_account_id}-${var.aws_region}-${each.key}-mcp-logs"
      },
      {
        Effect   = "Allow", Action = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource = "arn:aws:s3:::cc-${var.aws_account_id}-${var.aws_region}-${each.key}-mcp-logs/*"
      },
      {
        Effect   = "Allow", Action = ["cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource", "cloudwatch:TagResource", "cloudwatch:UntagResource"]
        Resource = "arn:aws:cloudwatch:${var.aws_region}:${var.aws_account_id}:alarm:cc-${each.key}-mcp-*"
      },
      {
        Effect   = "Allow", Action = ["sns:CreateTopic", "sns:DeleteTopic", "sns:GetTopicAttributes", "sns:SetTopicAttributes", "sns:Subscribe", "sns:Unsubscribe", "sns:GetSubscriptionAttributes", "sns:SetSubscriptionAttributes", "sns:ListSubscriptionsByTopic", "sns:ListTagsForResource", "sns:TagResource", "sns:UntagResource"]
        Resource = "arn:aws:sns:${var.aws_region}:${var.aws_account_id}:cc-${each.key}-mcp-alerts"
      }
    ]
  })
}
# Attach both MCP policies to the matching environment role only.
resource "aws_iam_role_policy_attachment" "mcp" {
  for_each   = { for pair in setproduct(local.application_environments, ["compute", "operations"]) : "${pair[0]}-${pair[1]}" => { environment = pair[0], part = pair[1] } }
  role       = aws_iam_role.terraform[each.value.environment].name
  policy_arn = each.value.part == "compute" ? aws_iam_policy.mcp_compute[each.value.environment].arn : aws_iam_policy.mcp_operations[each.value.environment].arn
}

# Application CI (cc-mcp-server repository): push the image once, then roll it out per environment.
# Never runs Terraform: one ECR repository, one ECS service and one SSM parameter per role.
locals {
  mcp_app_subjects = var.mcp_app_repository == null ? {} : {
    image-push        = "repo:${var.mcp_app_repository}:ref:refs/heads/main"
    deploy-uat        = "repo:${var.mcp_app_repository}:environment:uat"
    deploy-production = "repo:${var.mcp_app_repository}:environment:production"
  }
}
# Application CI identities; each trusts one exact branch or GitHub Environment subject.
resource "aws_iam_role" "mcp_app" {
  for_each             = local.mcp_app_subjects
  name                 = "cc-mcp-${each.key}"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = { Federated = local.provider_arn }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = each.value
      } }
    }]
  })
}
# Push scanned images to the MCP repository only (tags are immutable).
resource "aws_iam_role_policy" "mcp_image_push" {
  count = var.mcp_app_repository == null ? 0 : 1
  role  = aws_iam_role.mcp_app["image-push"].id
  name  = "ecr-push"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      {
        Effect   = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages", "ecr:DescribeImageScanFindings"]
        Resource = "arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/${var.mcp_ecr_repository_name}"
      }
    ]
  })
}
# Register a task definition revision with the new image and roll out this environment's service.
resource "aws_iam_role_policy" "mcp_deploy" {
  for_each = var.mcp_app_repository == null ? toset([]) : local.application_environments
  role     = aws_iam_role.mcp_app["deploy-${each.key}"].id
  name     = "ecs-deploy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"], Resource = "*", Condition = { StringEquals = { "aws:RequestedRegion" = var.aws_region } } },
      {
        Effect   = "Allow", Action = ["ecs:UpdateService", "ecs:DescribeServices"]
        Resource = "arn:aws:ecs:${var.aws_region}:${var.aws_account_id}:service/cc-${each.key}-mcp/cc-${each.key}-mcp"
      },
      {
        Effect    = "Allow", Action = ["iam:PassRole"]
        Resource  = ["arn:aws:iam::${var.aws_account_id}:role/cc-${each.key}-mcp-execution", "arn:aws:iam::${var.aws_account_id}:role/cc-${each.key}-mcp-task"]
        Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
      },
      {
        Effect   = "Allow", Action = ["ssm:GetParameter", "ssm:PutParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/cc/${each.key}/mcp/image"
      }
    ]
  })
}
