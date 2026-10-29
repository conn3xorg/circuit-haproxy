# Local example

Applies circuit-haproxy to a throwaway Rocky Linux 10 container with systemd. You need Conn3x and Podman.

The frontend on `:8080` balances across two small web servers on `9001` and `9002`, checking each with `GET /`. The stats page is on `127.0.0.1:8404/stats`, with the login `admin` / `example-only`. A second circuit in `main.tf` writes a page for each web server and installs python3 and curl.

Debian's and Ubuntu's haproxy unit sets up a mount namespace, which only a privileged container allows, and that's simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` HAProxy is up, but the web servers aren't yet. Start them as transient units and send a few requests:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1
systemd-run --unit web1 -p WorkingDirectory=/srv/web1 python3 -m http.server --bind 127.0.0.1 9001
systemd-run --unit web2 -p WorkingDirectory=/srv/web2 python3 -m http.server --bind 127.0.0.1 9002
for i in 1 2 3 4; do curl -s localhost:8080; done
```

The answers alternate between web1 and web2. Run `systemctl stop web2`, wait a few seconds for the health check to notice, and every answer comes from web1.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
