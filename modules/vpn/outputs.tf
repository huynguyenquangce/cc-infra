output "gateway_id" { value = aws_vpn_gateway.this.id }
output "connections" {
  value = { for k, v in aws_vpn_connection.this : k => {
    id      = v.id
    tunnel1 = { outside_ip = v.tunnel1_address, aws_inside_ip = v.tunnel1_vgw_inside_address, customer_inside_ip = v.tunnel1_cgw_inside_address, aws_bgp_asn = v.tunnel1_bgp_asn }
    tunnel2 = { outside_ip = v.tunnel2_address, aws_inside_ip = v.tunnel2_vgw_inside_address, customer_inside_ip = v.tunnel2_cgw_inside_address, aws_bgp_asn = v.tunnel2_bgp_asn }
  } }
}
