# Root Terragrunt config — included by every stage/<env>/<layer> unit.
# DRY: one place for state layout, encryption, and backend.
# State is keyed per env AND per layer: .tfstate/<env>/<layer>/terraform.tfstate
# (path_relative_to_include() = e.g. "dev/bootstrap").

# Use OpenTofu (not terraform) — so no TERRAGRUNT_TFPATH env var is needed.
terraform_binary = "tofu"

# --- State backend ----------------------------------------------------------
# Local for the sandbox. To move state to Codeberg (Forgejo's built-in HTTP state
# backend) switch this to backend = "http" and run
#   terragrunt run-all init -migrate-state
# with state encryption ON (below). Example:
#
#   remote_state {
#     backend = "http"
#     generate = { path = "backend_generated.tf", if_exists = "overwrite_terragrunt" }
#     config = {
#       address        = "https://codeberg.org/api/packages/<owner>/terraform/state/${path_relative_to_include()}"
#       lock_address   = "https://codeberg.org/api/packages/<owner>/terraform/state/${path_relative_to_include()}/lock"
#       unlock_address = "https://codeberg.org/api/packages/<owner>/terraform/state/${path_relative_to_include()}/lock"
#       lock_method    = "POST"
#       unlock_method  = "DELETE"
#       username       = "<codeberg-user>"
#       password       = get_env("CODEBERG_TOKEN", "")
#     }
#   }
remote_state {
  backend = "local"
  generate = {
    path      = "backend_generated.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    path = "${get_repo_root()}/.tfstate/${path_relative_to_include()}/terraform.tfstate"
  }
}

# --- State encryption (OpenTofu native, AES-GCM) ----------------------------
# Opt-in: export TF_STATE_PASSPHRASE (>= 16 chars) to encrypt state + plan at
# rest. REQUIRED before moving state off-machine (Codeberg) — the services layer
# state contains TF-generated secrets. Unset = plaintext local state (sandbox).
generate "encryption" {
  path      = "encryption_generated.tf"
  if_exists = "overwrite_terragrunt"
  contents  = get_env("TF_STATE_PASSPHRASE", "") == "" ? "# state encryption disabled — set TF_STATE_PASSPHRASE to enable\n" : <<-EOF
    terraform {
      encryption {
        key_provider "pbkdf2" "this" {
          passphrase = "${get_env("TF_STATE_PASSPHRASE", "")}"
        }
        method "aes_gcm" "this" {
          keys = key_provider.pbkdf2.this
        }
        state {
          method = method.aes_gcm.this
        }
        plan {
          method = method.aes_gcm.this
        }
      }
    }
  EOF
}

inputs = {}
