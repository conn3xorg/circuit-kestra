# Local example

Applies circuit-kestra to a throwaway Rocky Linux 10 container with systemd, with H2, the admin `owner@example.com` and one flow secret. You need Conn3x and Podman.

Kestra runs under Podman inside that container, so the host container is privileged, which is simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The first apply takes a few minutes: it installs Podman, pulls Kestra's image, checks the config with it and waits for Kestra to start. The second plan says `No changes.` The admin password and the secret are defaults in `main.tf`, which you'd never keep on a real host.

To try it the way CI does, run [check.sh](check.sh). It signs in, saves a flow that reads the secret, and runs it:

```sh
podman exec -i circuit-kestra sh < check.sh
```

Kestra is published on `127.0.0.1:8080` inside the container. To see the UI, forward that port over SSH, then open `http://localhost:8080` and sign in as `owner@example.com` with `Correct-horse-battery-9`:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts -L 8080:127.0.0.1:8080 root@127.0.0.1
```

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINER_NAME` to name the container something else, and `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
