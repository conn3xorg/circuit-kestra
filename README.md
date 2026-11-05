# circuit-kestra

[![Conn3x grade](https://conn3x.org/circuits/kestra/grade.svg)](https://conn3x.org/circuits/kestra/grade)

A Conn3x circuit that runs [Kestra](https://kestra.io), the workflow orchestrator, on your own hosts. You write flows in YAML (schedules, webhooks, retries, subflows, steps that wait on each other) and Kestra runs them and keeps every execution, log and output on a machine you run.

Kestra runs from its official image under Podman as a systemd service, pinned by tag and digest, as one standalone server. Its web UI and API are published on `127.0.0.1:8080` for a reverse proxy in front, and nothing else leaves the container. It keeps its data in H2 under `/var/lib/kestra` unless you point it at PostgreSQL. If you give it an admin, the first apply sets up that account, so nobody else can claim the instance from Kestra's setup page. It runs on Debian, Ubuntu, Fedora and Rocky Linux.

Kestra's tutorial flows and its anonymous usage reports, both on by default, are off.

## Usage

```hcl
variable "admin_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

variable "github_token" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "kestra" {
  source = "github.com/conn3xorg/circuit-kestra?ref=v0.1.0"

  hosts                = { orchestrator = "192.168.1.60" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  public_url     = "https://kestra.example.com"
  admin          = { email = "you@example.com" }
  admin_password = var.admin_password
  secrets        = { GITHUB_TOKEN = var.github_token }
}
```

Then run `conn3x init` and `conn3x apply` with the secrets in the environment:

```sh
export TF_VAR_admin_password='...' TF_VAR_github_token='...'
conn3x apply
```

A second `conn3x plan` says `No changes.` Every plan needs the secrets too, since Conn3x checks the file they're kept in on the host against them. Kestra wants the password to have 8 to 256 characters, with an uppercase letter, a lowercase letter and a digit, and the circuit checks that before it connects to anything.

A flow reads the secret with `{{ secret('GITHUB_TOKEN') }}`.

To try it on a throwaway container first, see [examples/local](examples/local).

### Behind a reverse proxy

Kestra speaks plain HTTP on `127.0.0.1:8080`. Put a proxy in front for TLS, such as [circuit-caddy](https://github.com/conn3xorg/circuit-caddy) on the same host:

```hcl
module "caddy" {
  source = "github.com/conn3xorg/circuit-caddy?ref=v0.3.0"

  hosts                = { orchestrator = "192.168.1.60" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  sites = {
    "kestra.example.com" = { reverse_proxy = ["127.0.0.1:8080"] }
  }
}
```

Set `public_url` to the address people type. Kestra puts it in the links it sends in notifications and in the webhook URLs it shows.

Without a proxy, you can still reach the UI over SSH: `ssh -L 8080:127.0.0.1:8080 root@192.168.1.60`, then open `http://localhost:8080`.

### With PostgreSQL

H2 suits one person trying things out. Kestra's own advice is PostgreSQL for anything you rely on, and it carries the queue between Kestra's parts as well as the flows and executions:

```hcl
module "kestra" {
  source = "github.com/conn3xorg/circuit-kestra?ref=v0.1.0"

  hosts                = { orchestrator = "192.168.1.60" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  admin             = { email = "you@example.com" }
  admin_password    = var.admin_password
  postgres          = { host = "db1.lan" }
  postgres_password = var.db_password
}
```

`postgres` takes `host`, and optionally `port` (`5432`), `database` (`"kestra"`) and `username` (`"kestra"`). The role and the database must exist. Kestra runs on Podman's bridge network, so `127.0.0.1` would be the container itself: for a PostgreSQL on the same host, use `host.containers.internal` and make sure PostgreSQL listens on Podman's bridge address and lets the container's subnet in. The password reaches Kestra as an environment variable from a root-only file, written from the ephemeral value, so it's never in the plan or state.

Switching an existing instance from H2 to PostgreSQL doesn't move its data. Kestra starts on the empty database as a new instance.

### The admin account

Kestra's open-source edition has one account, and Kestra won't run its UI or API without it. With `admin` and `admin_password` set, the config names the account and Kestra creates it as it starts, so its setup page never appears. Change `admin_password` and the next apply restarts Kestra with the new one.

Leave `admin` out and Kestra shows its setup page to the first person who opens it. Do that before the UI is on a public address.

## Why a container, and why the bridge network

Kestra ships as a Docker image and as a JAR. The image carries the Java runtime Kestra is built against, and `kestra_version` and `image_digest` go into the unit together, so a tag that's re-pushed upstream can't change what your hosts run. Upgrades are a diff: change both inputs, and the apply restarts Kestra on the new image, which migrates its database as it starts.

The standalone server opens three ports: the web server on 8080, a management port on 8081, and since 2.0, a gRPC port on 50051 that its workers connect to. Kestra has no setting to bind that last one to one address, and its own authentication is off by default. On the host's network it would listen on every address. So the container stays on Podman's bridge network, and only the web server is published, on `listen_address`. The other two can't be reached from outside the container.

The circuit uses the `-slim` image by default: Kestra with its core tasks, such as logging, HTTP requests, subflows, schedules and webhooks, at about 250 MB. The image without the suffix, such as `v2.0.9`, has every plugin, at several gigabytes. Set `kestra_version` and `image_digest` to that one if your flows need plugins, or install the ones you need with `kestra plugins install`.

## What it does

On each host, in order:

1. Installs Podman and pulls `docker.io/kestra/kestra:VERSION@DIGEST`.
2. Writes `/etc/kestra/application.yaml`, mode `0644`, and checks it with `kestra configs validate` in the image before it replaces the old one. It holds the database, the storage paths, `public_url` and the admin's email, and no passwords: those are placeholders, filled in from the environment as Kestra starts. A change restarts Kestra.
3. Creates `/var/lib/kestra`, mode `0700`, owned by root, with `storage` and `db` inside for Kestra's files and its H2 database.
4. Through [circuit-podman](https://github.com/conn3xorg/circuit-podman) v0.1.1, runs the image as `kestra.service`: a Quadlet unit that runs `server standalone --no-tutorials` with the config, publishes port 8080 on `listen_address`, and mounts the two data directories. `admin_password`, `postgres_password`, `secrets` and `environment` go to `/etc/containers/env/kestra.env`, mode `0600`, written from ephemeral values so they never reach the plan or state.
5. Waits up to 15 minutes for Kestra to answer on `/ping`, after a first start and after any change that restarts it.

A change to any input restarts Kestra. Executions running at that moment are cut off.

### Secrets

Kestra reads a flow's secrets from environment variables named `SECRET_NAME`, holding the value in base64. `secrets` takes the plain values by name; the circuit encodes them and adds the prefix. In a flow, `{{ secret('NAME') }}` gives the value back.

Secrets aren't hidden from the flows themselves: a flow that runs a script inside the container can read every environment variable Kestra has. That's how Kestra's open-source edition works.

### Who owns the data

Kestra runs in the container as its `kestra` user, UID 1000, and Podman hands `/var/lib/kestra/storage` and `/var/lib/kestra/db` to that UID each time the container starts. On a host where UID 1000 is a person's account, that account owns Kestra's files on paper, but can't reach them: only root can enter `/var/lib/kestra`.

### Script tasks

Kestra's script tasks, such as Python or Shell scripts, start a Docker container for each run by default. This circuit doesn't give Kestra a container engine socket: that would hand anyone who can edit a flow root on the host. Set `taskRunner: { type: io.kestra.plugin.core.runner.Process }` on a script task to run it inside Kestra's own container instead, with what the image has installed.

### What it doesn't do

- It doesn't set up TLS or a reverse proxy, and it doesn't open a port in a firewall.
- It doesn't back anything up. Back up `/var/lib/kestra` or PostgreSQL (see [circuit-restic](https://github.com/conn3xorg/circuit-restic)).
- It doesn't split Kestra into separate webserver, executor and worker services. One standalone server does everything.
- It doesn't give Kestra a container socket for script tasks, as above.
- Deleting the module leaves Podman, the container, `/etc/kestra` and `/var/lib/kestra` in place.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"192.168.1.60"`, or a host object such as `{ address = "192.168.1.60", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file` and `jump_hosts`. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `public_url` | string | `null` | The address people reach Kestra at, such as `"https://kestra.example.com"`. Sets `kestra.url`. When null, the local address. |
| `admin` | object | `null` | The account to sign in with: `email`. When null, Kestra shows its setup page to the first person who opens it. |
| `admin_password` | string | `null` | Password for `admin`. Needed with `admin`. 8 to 256 characters with an uppercase letter, a lowercase letter and a digit. Ephemeral and sensitive: it reaches a root-only file on the host but never the plan or state. |
| `secrets` | map(string) | `{}` | Secrets flows read with `secret("NAME")`, by name. Encoded into `SECRET_NAME` variables. Ephemeral and sensitive. |
| `postgres` | object | `null` | PostgreSQL to keep Kestra's data in: `host`, and optionally `port` (`5432`), `database` (`"kestra"`) and `username` (`"kestra"`). When null, H2 in `/var/lib/kestra/db`. |
| `postgres_password` | string | `null` | Password of the PostgreSQL user. Needed with `postgres`. Ephemeral and sensitive. |
| `environment` | map(string) | `{}` | More environment variables for Kestra. Kestra reads any setting from a variable named after it, such as `KESTRA_TASKS_TMPDIR_PATH`. Ephemeral and sensitive. `SECRET_` and `CONN3X_` names aren't allowed here. |
| `kestra_version` | string | `"v2.0.9-slim"` | Tag of Kestra's image. Change `image_digest` with it. |
| `image_digest` | string | `"sha256:3ee725f9..."` | Digest of the image for `kestra_version`. Podman pulls by the digest. Find it on [Docker Hub](https://hub.docker.com/r/kestra/kestra/tags) or with `skopeo inspect docker://docker.io/kestra/kestra:TAG`. |
| `image_repository` | string | `"docker.io/kestra/kestra"` | Where to pull the image from, such as a mirror of Docker Hub. |
| `listen_address` | string | `"127.0.0.1"` | Host address the web server is published on. `"0.0.0.0"` publishes it on every address. |
| `port` | number | `8080` | Host port the web server is published on. |

## Outputs

| Name | Description |
| --- | --- |
| `service` | The systemd service that runs Kestra, `kestra.service`. |
| `image` | The image the hosts run, with its tag and digest. |
| `url` | Where Kestra answers on the host itself, such as `http://127.0.0.1:8080`. Point a reverse proxy here. |
| `data_dir` | `/var/lib/kestra`, the directory to back up. |

## Requirements

Requires Conn3x v0.7.0 or later and systemd on each host. The image is built for amd64 and arm64. Each host needs to reach its package mirror and Docker Hub. `conn3x init` fetches circuit-podman from GitHub.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64, with H2, an admin and a secret, first at v2.0.8-slim and then upgrading to the default, and checks the next plan has no changes and the secrets aren't in state. [check.sh](examples/local/check.sh) then signs in as the admin, checks a wrong password and no password are refused, saves a flow through the API and runs it. The flow fails unless `secret('CI_GREETING')` is the value the example passed in, so a pass shows the secret made it through. CI restarts the host, checks the flow and its earlier run are still there, runs it again, and plans clean once more.

The same runs passed by hand on arm64 in rootful Podman on a Mac. By hand on DigitalOcean droplets with 4 GB of memory, Ubuntu 24.04 and Rocky Linux 10 with SELinux enforcing: the apply, the clean plan and check.sh passed, ports 8080, 8081 and 50051 didn't answer on the public address, and neither password nor secret was in state. After a reboot Kestra came back on its own, the flow and its run were still there, and the plan was clean. Changing `admin_password` restarted Kestra, the new password signed in and the old one was refused. The Rocky audit log had no denials. PostgreSQL hasn't been tried yet.

## License

MPL-2.0. See [LICENSE](LICENSE).

Kestra's open-source edition is under the Apache License 2.0.
