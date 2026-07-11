terraform {
  required_version = ">= 1.9"

  # Range deliberately broad: works against helm v2 (used elsewhere in the
  # motohelp ecosystem) and v3. The module sticks to the `values = [...]`
  # argument only — no `set` block — so the syntax is source-compatible
  # across major versions.
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.0, < 4.0"
    }
  }
}
