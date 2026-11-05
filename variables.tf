variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file or jump_hosts."
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}


variable "kestra_version" {
  type        = string
  default     = "v2.0.9-slim"
  nullable    = false
  description = "Tag of the Kestra image, such as \"v2.0.9-slim\", Kestra with its core tasks only, or \"v2.0.9\", with every plugin. Change image_digest with it."

  validation {
    condition     = can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]*$", var.kestra_version))
    error_message = "kestra_version must be an image tag, such as \"v2.0.9-slim\"."
  }
}

variable "image_digest" {
  type        = string
  default     = "sha256:3ee725f92e7aba3d8f11242a6b2a773702e0315ba472d4049a5e56441e9aed84"
  nullable    = false
  description = "Digest of the image for kestra_version, such as \"sha256:3ee7...\". Podman pulls by the digest, so a tag that moves upstream can't change what runs."

  validation {
    condition     = can(regex("^sha256:[a-f0-9]{64}$", var.image_digest))
    error_message = "image_digest must be a sha256 digest, such as \"sha256:\" followed by 64 hex digits."
  }
}

variable "image_repository" {
  type        = string
  default     = "docker.io/kestra/kestra"
  description = "Where to pull Kestra's image from, such as a mirror of docker.io/kestra/kestra."

  validation {
    condition     = can(regex("^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+$", var.image_repository))
    error_message = "image_repository must be a registry and path without a tag, such as \"docker.io/kestra/kestra\"."
  }
}

variable "listen_address" {
  type        = string
  default     = "127.0.0.1"
  description = "Host address Kestra's web server is published on. The default keeps it on the host for a reverse proxy in front; \"0.0.0.0\" publishes it on every address."

  validation {
    condition     = can(cidrhost("${var.listen_address}/${strcontains(var.listen_address, ":") ? 128 : 32}", 0))
    error_message = "listen_address must be an IPv4 or IPv6 address, such as \"127.0.0.1\"."
  }
}

variable "port" {
  type        = number
  default     = 8080
  description = "Host port Kestra's web server is published on."

  validation {
    condition     = var.port >= 1 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be a whole number from 1 to 65535."
  }
}

variable "public_url" {
  type        = string
  default     = null
  description = "The address people reach Kestra at, such as \"https://kestra.example.com\". Kestra uses it for links in notifications and webhook URLs. When null, the local address from listen_address and port."

  validation {
    condition     = var.public_url == null || can(regex("^https?://[^\\s/:]+(:[0-9]+)?(/[^\\s]*)?$", coalesce(var.public_url, "-")))
    error_message = "public_url must be an http or https address, such as \"https://kestra.example.com\"."
  }
}

variable "admin" {
  type = object({
    email = string
  })
  default     = null
  description = "The account to sign in with, such as { email = \"you@example.com\" }. Kestra's open-source edition has one. When null, Kestra shows a setup page to whoever opens it first."

  validation {
    condition     = var.admin == null || can(regex("^[a-zA-Z0-9_!#$%&'*+/=?`{|}~^.-]+@[a-zA-Z0-9.-]+$", try(var.admin.email, ""))) && length(try(var.admin.email, "")) <= 256
    error_message = "admin.email must be an email address."
  }
}

variable "admin_password" {
  type        = string
  default     = null
  ephemeral   = true
  sensitive   = true
  description = "Password for admin. Needed with admin. Kestra wants 8 to 256 characters with an uppercase letter, a lowercase letter and a digit. Pass it at run time with -var or TF_VAR_admin_password; it never reaches state or the plan."

  validation {
    condition = var.admin == null || (
      length(coalesce(var.admin_password, "")) >= 8 &&
      length(coalesce(var.admin_password, "")) <= 256 &&
      can(regex("[a-z]", coalesce(var.admin_password, "-"))) &&
      can(regex("[A-Z]", coalesce(var.admin_password, "-"))) &&
      can(regex("[0-9]", coalesce(var.admin_password, "-"))) &&
      !strcontains(coalesce(var.admin_password, "-"), "\n")
    )
    error_message = "admin needs an admin_password of 8 to 256 characters, on one line, with an uppercase letter, a lowercase letter and a digit."
  }
}

variable "postgres" {
  type = object({
    host     = string
    port     = optional(number, 5432)
    database = optional(string, "kestra")
    username = optional(string, "kestra")
  })
  default     = null
  description = "PostgreSQL to keep Kestra's flows, executions and queue in, such as { host = \"db1.lan\" }. The role and database must exist. When null, Kestra uses an H2 database in /var/lib/kestra/db."

  validation {
    condition     = var.postgres == null || alltrue([for k, v in coalesce(var.postgres, { host = "-" }) : can(regex("^[A-Za-z0-9_.-]+$", tostring(v)))])
    error_message = "postgres host, database and username may use letters, digits and . _ -."
  }
}

variable "postgres_password" {
  type        = string
  default     = null
  ephemeral   = true
  sensitive   = true
  description = "Password of the postgres username. Needed with postgres. Pass it at run time; it never reaches state or the plan."

  validation {
    condition     = var.postgres == null || length(coalesce(var.postgres_password, "")) > 0
    error_message = "postgres needs postgres_password."
  }

  validation {
    condition     = !strcontains(coalesce(var.postgres_password, "-"), "\n")
    error_message = "postgres_password must be on one line."
  }
}

variable "secrets" {
  type        = map(string)
  default     = {}
  ephemeral   = true
  sensitive   = true
  nullable    = false
  description = "Secrets your flows read with secret(\"NAME\"), such as { GITHUB_TOKEN = \"...\" }. The circuit base64-encodes each one into SECRET_NAME, the form Kestra reads, in a root-only env file. They never reach the plan or state."

  validation {
    condition     = alltrue([for k, v in var.secrets : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k))])
    error_message = "secrets names may use letters, digits and _, and can't start with a digit."
  }
}

variable "environment" {
  type        = map(string)
  default     = {}
  ephemeral   = true
  sensitive   = true
  nullable    = false
  description = "More environment variables for Kestra, such as { KESTRA_TASKS_TMPDIR_PATH = \"/app/storage/tmp\" }. Kestra reads any of its settings from a variable named after it. They go in the root-only env file and never reach the plan or state."

  validation {
    condition     = alltrue([for k, v in var.environment : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k)) && !strcontains(v, "\n")])
    error_message = "environment maps variable names to values on one line."
  }

  validation {
    condition     = alltrue([for k in keys(var.environment) : !startswith(k, "SECRET_") && !startswith(k, "CONN3X_")])
    error_message = "Give secrets in secrets, not as SECRET_ variables. CONN3X_ names are the circuit's own."
  }
}
