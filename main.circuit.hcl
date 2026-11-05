locals {
  image   = "${var.image_repository}:${var.kestra_version}@${var.image_digest}"
  etc     = "/etc/kestra"
  config  = "/etc/kestra/application.yaml"
  parent  = "/var/lib/kestra"
  storage = "/var/lib/kestra/storage"
  db      = "/var/lib/kestra/db"

  local_host = lookup({ "0.0.0.0" = "127.0.0.1", "::" = "[::1]" }, var.listen_address, strcontains(var.listen_address, ":") ? "[${var.listen_address}]" : var.listen_address)
  local_url  = "http://${local.local_host}:${var.port}"
  publish    = strcontains(var.listen_address, ":") ? "[${var.listen_address}]" : var.listen_address

  # Passwords stay out of this file, which is in the plan and state. They
  # reach Kestra as environment variables from the root-only env file, and
  # Micronaut fills in the placeholders as Kestra starts.
  settings = merge(
    {
      kestra = merge(
        {
          url        = "${trimsuffix(coalesce(var.public_url, local.local_url), "/")}/"
          repository = { type = var.postgres == null ? "h2" : "postgres" }
          queue      = { type = var.postgres == null ? "h2" : "postgres" }
          storage    = { type = "local", local = { base-path = "/app/storage" } }
          # Kestra loads its tutorial flows and reports usage unless told not to.
          tutorial-flows            = { enabled = false }
          anonymous-usage-report    = { enabled = false }
          ui-anonymous-usage-report = { enabled = false }
        },
        var.admin == null ? {} : {
          server = { basic-auth = { username = var.admin.email, password = "$${CONN3X_ADMIN_PASSWORD}" } }
        },
      )
    },
    {
      datasources = var.postgres == null ? {
        h2 = {
          url               = "jdbc:h2:file:/app/db/kestra;DB_CLOSE_ON_EXIT=FALSE"
          username          = "kestra"
          password          = ""
          driver-class-name = "org.h2.Driver"
        }
        } : {
        postgres = {
          url               = "jdbc:postgresql://${var.postgres.host}:${var.postgres.port}/${var.postgres.database}"
          username          = var.postgres.username
          password          = "$${CONN3X_POSTGRES_PASSWORD}"
          driver-class-name = "org.postgresql.Driver"
        }
      }
    },
  )

  config_content = "# Written by Conn3x. Changes here are overwritten on the next apply.\n${yamlencode(local.settings)}"

  # Kestra wants secrets as SECRET_NAME, base64-encoded, and secret("NAME")
  # in a flow decodes them.
  secret_env = merge(
    { for k, v in var.secrets : "SECRET_${k}" => base64encode(v) },
    var.admin == null ? {} : { CONN3X_ADMIN_PASSWORD = var.admin_password },
    var.postgres == null ? {} : { CONN3X_POSTGRES_PASSWORD = var.postgres_password },
    var.environment,
  )
}

circuit "kestra" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # circuit-podman installs it too, but the config check below needs the
  # image first.
  step "podman" {
    package {
      name = "podman"
    }
  }

  step "pull" {
    command {
      command = "podman pull -q ${local.image} >/dev/null"
      unless  = "podman image exists ${local.image}"
    }
  }

  step "etc" {
    directory {
      path  = local.etc
      owner = "root"
      group = "root"
      mode  = "0755"
    }
  }

  # The config holds no secrets, so the kestra user in the container can
  # read it. Kestra's own check reads it before it replaces the old one, so
  # a file Kestra can't parse never reaches a restart.
  step "config" {
    file {
      path     = local.config
      content  = local.config_content
      owner    = "root"
      group    = "root"
      mode     = "0644"
      validate = "podman run --rm --network none -v %s:/c.yaml:ro,z ${local.image} configs validate -c /c.yaml"
    }
  }

  # The flows, executions and files Kestra stores. Podman hands them to the
  # container's kestra user, UID 1000, as it starts (the :U below). That UID
  # can be a person's account on the host, so they sit in a parent only root
  # can enter.
  step "parent" {
    directory {
      path  = local.parent
      owner = "root"
      group = "root"
      mode  = "0700"
    }
  }

  step "storage" {
    directory {
      path = local.storage
      mode = "0700"
    }
  }

  step "db" {
    directory {
      path = local.db
      mode = "0700"
    }
  }

  # Kestra reads its config only as it starts. Before the first start
  # there's nothing to restart.
  step "restart" {
    command {
      command  = "! systemctl cat kestra.service >/dev/null 2>&1 || systemctl try-restart kestra.service"
      triggers = { config = conn3x_file.kestra__config[each.key].sha256 }
    }
  }
}

# Kestra runs from its official image as a Quadlet unit, on Podman's bridge
# network with one published port. The standalone server also opens its
# management port and the gRPC port its workers connect on, and both stay
# inside the container.
module "podman" {
  source = "github.com/conn3xorg/circuit-podman?ref=v0.1.1"

  depends_on = [conn3x_command.kestra__restart]

  hosts                = var.hosts
  ssh_user             = var.ssh_user
  ssh_port             = var.ssh_port
  ssh_private_key_file = var.ssh_private_key_file
  ssh_known_hosts_file = var.ssh_known_hosts_file
  ssh_become           = var.ssh_become

  containers = {
    kestra = {
      image = local.image
      ports = ["${local.publish}:${var.port}:8080"]
      volumes = [
        "${local.config}:/etc/kestra/application.yaml:ro,z",
        "${local.storage}:/app/storage:Z,U",
        "${local.db}:/app/db:Z,U",
      ]
      extra = ["Exec=server standalone --no-tutorials -c /etc/kestra/application.yaml"]
    }
  }
  secrets = {
    kestra = local.secret_env
  }
}

circuit "ready" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Waits for Kestra after a first start and after anything that restarts
  # it. A wait_for on the port can't do it: Podman 6 publishes the port with
  # firewall rules alone, so nothing on the host listens on it. /ping
  # answers once the web server is up; curl is in the image, and the host
  # may have none.
  step "started" {
    depends_on = [module.podman]
    command {
      command  = "for _ in $(seq 900); do podman exec kestra curl -sf -o /dev/null http://127.0.0.1:8080/ping 2>/dev/null && exit 0; sleep 1; done; echo \"Kestra didn't answer in 15 minutes. See journalctl -u kestra.\" >&2; exit 1"
      triggers = { image = local.image, config = conn3x_file.kestra__config[each.key].sha256 }
    }
  }
}
