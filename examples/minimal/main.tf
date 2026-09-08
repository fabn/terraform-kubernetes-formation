# =============================================================================
# Minimal Example
# =============================================================================
# The simplest possible formation: a single web process behind an ingress.

module "app" {
  source = "../.."

  name        = "hello"
  namespace   = "hello"
  environment = "example"
  image       = "ealen/echo-server:latest"
  domain      = "hello.lvh.me"

  formation = {
    web = {
      web   = true
      ports = { http = 80 }
    }
  }
}
