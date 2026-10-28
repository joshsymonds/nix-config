variable "state_passphrase" {
  description = "Passphrase for OpenTofu client-side state and plan encryption (pbkdf2 + aes_gcm). Supplied via TF_VAR_state_passphrase."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.state_passphrase) >= 16
    error_message = "state_passphrase must be at least 16 characters."
  }
}
