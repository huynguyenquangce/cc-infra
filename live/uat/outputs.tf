# Empty object while MCP is disabled so workflow output commands succeed.
output "mcp_server" { value = merge({}, one(module.mcp_server)) }
output "mcp_endpoint" { value = var.enable_mcp ? module.mcp_server[0].endpoint : null }
output "api_proxy_url" { value = var.enable_alb ? module.api_proxy[0].api_url : null }
# Empty object while the API Proxy is disabled so workflow output commands succeed.
output "api_proxy" { value = var.enable_alb ? one(module.api_proxy) : {} }
