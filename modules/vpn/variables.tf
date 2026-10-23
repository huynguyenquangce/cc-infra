variable "vpc_id" { type = string }
variable "route_table_ids" { type = map(string) }
variable "amazon_side_asn" {
  type = number
  validation {
    condition     = var.amazon_side_asn >= 64512 && var.amazon_side_asn <= 65534 && floor(var.amazon_side_asn) == var.amazon_side_asn
    error_message = "Use a private 16-bit AWS ASN (64512–65534)."
  }
}
variable "customer_gateways" {
  description = "Explicitly confirmed Commerce endpoints. Each entry creates one connection with two AWS tunnels."
  type        = map(object({ ip_address = string, bgp_asn = number }))
  validation {
    condition = length(var.customer_gateways) > 0 && alltrue([
      for c in values(var.customer_gateways) : can(cidrnetmask("${c.ip_address}/32")) && c.bgp_asn >= 64512 && c.bgp_asn <= 65534 && floor(c.bgp_asn) == c.bgp_asn
    ])
    error_message = "Supply at least one IPv4 endpoint and a private 16-bit customer ASN."
  }
}
variable "phase1_lifetime_seconds" {
  type    = number
  default = 28800
  validation {
    condition     = var.phase1_lifetime_seconds >= 900 && var.phase1_lifetime_seconds <= 28800
    error_message = "Phase 1 lifetime must be 900–28800 seconds."
  }
}
variable "phase2_lifetime_seconds" {
  type    = number
  default = 3600
  validation {
    condition     = var.phase2_lifetime_seconds >= 1080 && var.phase2_lifetime_seconds <= 3600
    error_message = "Phase 2 lifetime must be 1080–3600 seconds (540-second rekey margin)."
  }
}
variable "alarm_action_arns" {
  type    = list(string)
  default = []
}
