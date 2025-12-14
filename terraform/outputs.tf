output "api_gateway_url" {
  value       = yandex_api_gateway.api.domain
  description = "API Gateway endpoint URL"
}

