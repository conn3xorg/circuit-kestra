variable "port" {
  type    = number
  default = 2222
}

# Example values only. Pass your own with -var or TF_VAR_ on a real host.
variable "admin_password" {
  type      = string
  default   = "Correct-horse-battery-9"
  ephemeral = true
  sensitive = true
}

variable "greeting" {
  type      = string
  default   = "hello-from-a-secret-7"
  ephemeral = true
  sensitive = true
}

# CI sets these to apply an older release first, then upgrade.
variable "kestra_version" {
  type    = string
  default = null
}

variable "image_digest" {
  type    = string
  default = null
}

module "kestra" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  kestra_version = var.kestra_version
  image_digest   = var.image_digest

  admin          = { email = "owner@example.com" }
  admin_password = var.admin_password
  secrets        = { CI_GREETING = var.greeting }
}
