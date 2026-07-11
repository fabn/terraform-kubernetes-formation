terraform {
  required_providers {
    http = {
      source = "hashicorp/http"
    }
  }
}

variable "url" {
  description = "The url to test"
  type        = string
  validation {
    condition     = can(regex("https?://", var.url))
    error_message = "The URL must start with http:// or https://, given: '${var.url}'"
  }
}

variable "method" {
  description = "HTTP method"
  default     = "GET"
  validation {
    condition     = contains(["GET", "POST", "HEAD"], var.method)
    error_message = "Unsupported method given ${var.method}"
  }
}

variable "status_codes" {
  description = "List of expected status codes to validate"
  type        = list(number)
  default     = [200]
}

variable "skip_tls_verify" {
  description = "Whether to skip SSL certificate validation"
  type        = bool
  default     = false
}

variable "max_retry" {
  description = "Maximum number of retries"
  type        = number
  default     = 3
}

variable "retry_interval" {
  description = "Interval between retries in seconds"
  type        = number
  default     = 5
}

variable "request_headers" {
  description = "Request headers"
  type        = map(string)
  default     = {}
}

variable "request_body" {
  description = "Request body"
  type        = string
  default     = ""
}

data "http" "request" {
  url             = var.url
  method          = var.method
  request_headers = var.request_headers
  request_body    = var.request_body
  insecure        = var.skip_tls_verify
  retry {
    attempts     = var.max_retry
    min_delay_ms = var.retry_interval * 1000
  }
  lifecycle {
    postcondition {
      condition     = contains(var.status_codes, tonumber(self.status_code))
      error_message = "Status code invalid while accessing ${var.method} ${var.url}: Code ${self.status_code}"
    }
  }
}

output "http" {
  description = "The full object"
  value       = data.http.request
  sensitive   = true
}

output "status_code" {
  description = "HTTP status code"
  value       = tonumber(data.http.request.status_code)
}

output "response_body" {
  description = "Request response body"
  value       = data.http.request.response_body
}

output "headers" {
  description = "Response headers"
  value       = data.http.request.response_headers
}

output "parsed" {
  description = "Request response body as object (JSON only)"
  value       = try(jsondecode(data.http.request.response_body), {})
}
