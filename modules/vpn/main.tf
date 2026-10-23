resource "aws_vpn_gateway" "this" {
  vpc_id          = var.vpc_id
  amazon_side_asn = var.amazon_side_asn
  tags            = { Name = "cc-shared-vgw" }
}
resource "aws_customer_gateway" "this" {
  for_each   = var.customer_gateways
  ip_address = each.value.ip_address
  bgp_asn    = each.value.bgp_asn
  type       = "ipsec.1"
  tags       = { Name = "cc-${each.key}" }
  lifecycle {
    precondition {
      condition     = each.value.bgp_asn != var.amazon_side_asn
      error_message = "Customer ASN must differ from the AWS VGW ASN."
    }
  }
}
resource "aws_cloudwatch_log_group" "vpn" {
  for_each          = var.customer_gateways
  name              = "/aws/vendedlogs/cc/vpn/${each.key}"
  retention_in_days = 90
}
resource "aws_vpn_connection" "this" {
  for_each            = var.customer_gateways
  vpn_gateway_id      = aws_vpn_gateway.this.id
  customer_gateway_id = aws_customer_gateway.this[each.key].id
  type                = "ipsec.1"
  static_routes_only  = false
  # AWS generates PSKs and /30 tunnel addresses. Never put PSKs in tfvars or outputs.
  tunnel1_ike_versions                 = ["ikev2"]
  tunnel1_phase1_encryption_algorithms = ["AES256"]
  tunnel1_phase2_encryption_algorithms = ["AES256"]
  tunnel1_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase1_dh_group_numbers      = [19]
  tunnel1_phase2_dh_group_numbers      = [19]
  tunnel1_phase1_lifetime_seconds      = var.phase1_lifetime_seconds
  tunnel1_phase2_lifetime_seconds      = var.phase2_lifetime_seconds
  tunnel1_dpd_timeout_action           = "restart"
  tunnel1_startup_action               = "add"
  tunnel1_log_options {
    cloudwatch_log_options {
      log_enabled       = true
      log_group_arn     = aws_cloudwatch_log_group.vpn[each.key].arn
      log_output_format = "json"
    }
  }
  tunnel2_ike_versions                 = ["ikev2"]
  tunnel2_phase1_encryption_algorithms = ["AES256"]
  tunnel2_phase2_encryption_algorithms = ["AES256"]
  tunnel2_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase1_dh_group_numbers      = [19]
  tunnel2_phase2_dh_group_numbers      = [19]
  tunnel2_phase1_lifetime_seconds      = var.phase1_lifetime_seconds
  tunnel2_phase2_lifetime_seconds      = var.phase2_lifetime_seconds
  tunnel2_dpd_timeout_action           = "restart"
  tunnel2_startup_action               = "add"
  tunnel2_log_options {
    cloudwatch_log_options {
      log_enabled       = true
      log_group_arn     = aws_cloudwatch_log_group.vpn[each.key].arn
      log_output_format = "json"
    }
  }
  tags = { Name = "cc-${each.key}" }
}
resource "aws_vpn_gateway_route_propagation" "private" {
  for_each       = var.route_table_ids
  vpn_gateway_id = aws_vpn_gateway.this.id
  route_table_id = each.value
}
locals {
  tunnels = merge([for name in keys(var.customer_gateways) : {
    for index in [1, 2] : "${name}-${index}" => {
      vpn_id  = aws_vpn_connection.this[name].id
      address = index == 1 ? aws_vpn_connection.this[name].tunnel1_address : aws_vpn_connection.this[name].tunnel2_address
    }
  }]...)
}
resource "aws_cloudwatch_metric_alarm" "tunnel_down" {
  for_each            = local.tunnels
  alarm_name          = "cc-vpn-${each.key}-down"
  alarm_description   = "VPN tunnel down. Check IPsec, BGP and received routes."
  namespace           = "AWS/VPN"
  metric_name         = "TunnelState"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  dimensions          = { VpnId = each.value.vpn_id, TunnelIpAddress = each.value.address }
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns
}
