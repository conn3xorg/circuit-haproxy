# circuit-haproxy

A Conn3x circuit that installs HAProxy from the distribution and writes its config from a map of frontends and backends. You describe what listens where and which servers sit behind it; the circuit turns that into `/etc/haproxy/haproxy.cfg`, checks it with `haproxy -c` before it goes live, and reloads HAProxy without dropping a connection.

That check is the part you'd otherwise script yourself. A typo in a server line, or a certificate path that doesn't exist yet, stops the apply with HAProxy's own error message, and the running HAProxy keeps the config it had.

It runs on Debian, Ubuntu, Fedora and Rocky Linux. On Fedora and Rocky Linux it also turns on the SELinux boolean HAProxy needs to reach backends on ports of their own, which is the first thing that bites when you move a working config from Ubuntu to a Red Hat host.

## Usage

```hcl
module "haproxy" {
  source = "github.com/conn3xorg/circuit-haproxy?ref=v0.1.0"

  hosts                = { lb1 = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  frontends = {
    http_in  = { bind = "*:80", default_backend = "app" }
    https_in = { bind = "*:443", tls_pem = "/etc/haproxy/certs/example.com.pem", default_backend = "app" }
    pg_in    = { bind = "10.0.0.5:5432", mode = "tcp", default_backend = "postgres" }
  }

  backends = {
    app = {
      servers    = { app1 = "10.0.0.11:8080", app2 = "10.0.0.12:8080" }
      check_path = "/healthz"
    }
    postgres = {
      servers = { pg1 = "10.0.0.21:5432" }
      balance = "first"
    }
  }

  timeouts = { client = "1h", server = "1h" }

  stats          = {}
  stats_password = var.haproxy_stats_password
}
```

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.`

Each frontend sends everything to its `default_backend`. A backend takes its mode, `http` or `tcp`, from the frontends that use it, so two frontends of different modes can't share one. HAProxy 3.3 and later refuse a frontend and a backend with the same name, so the circuit does too: call them `http_in` and `app`, not `app` and `app`.

`tls_pem` is a path on the host, to a PEM file holding the certificate chain and private key, or a directory of them. The circuit doesn't put it there. If you get certificates from Let's Encrypt, [circuit-certbot](https://github.com/conn3xorg/circuit-certbot) is the place to look; certbot writes the chain and key as separate files, so they need joining into one PEM for HAProxy, for instance in a deploy hook.

For hosts created in the same plan, pass host objects with the host key you generated, and their distribution in `os`, since the circuit decides about SELinux by distribution and can't ask a host that doesn't exist yet. Set `os` as well when you put `depends_on` on this module.

```hcl
hosts = {
  for name, d in digitalocean_droplet.lb : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
    os       = "rocky"
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

### The stats page

`stats = {}` turns on HAProxy's stats page at `http://127.0.0.1:8404/stats`, which shows each server's state, health checks and traffic. It listens on loopback only, so reach it through an SSH tunnel:

```sh
ssh -L 8404:127.0.0.1:8404 root@203.0.113.10
```

Set `stats_password` to put a login on it, with `stats.user` (default `admin`). If you bind it anywhere but loopback, set one. The password is a sensitive variable, and with it set, the circuit writes the config through `content_wo`, so the password stays out of the state and the plan. The price is that the plan then shows a config change as a changed hash rather than a diff.

## What it does

On each host, in order:

1. On Fedora, Rocky Linux, AlmaLinux and RHEL with SELinux on, turns on the `haproxy_connect_any` boolean, persistently. The policy otherwise lets HAProxy reach a short list of ports, such as 80, 443 and 8080; on a Rocky Linux 10 droplet with the boolean off, connections to a backend on port 9001 were denied and every request got a 503. Set `selinux_connect_any = false` to leave the boolean alone and label ports yourself with `semanage port`.
2. Installs the `haproxy` package from the distribution's own repositories.
3. Writes the rendered config to `/etc/haproxy/haproxy.cfg.conn3x`, runs `haproxy -c` on it, and copies it over `/etc/haproxy/haproxy.cfg` only if the check passes. A hand edit to the live file is put back on the next apply.
4. Starts HAProxy now and at boot, and reloads it when the config changes. A reload starts new workers on the new config and lets the old ones finish their connections. In a test with `curl` running against the frontend in a loop during an apply that changed the config, all 1,055 requests succeeded.

The config logs to the systemd journal (`journalctl -u haproxy`), chroots HAProxy to `/var/lib/haproxy` and runs it as the `haproxy` user. HTTP frontends log with `option httplog` and add `X-Forwarded-For`; with TLS they also set `X-Forwarded-Proto: https` and offer HTTP/2. TCP frontends log with `option tcplog`. With `check` on, which is the default, HAProxy checks each server every two seconds, by TCP connect or, with `check_path`, by `GET` on that path, and takes a server out after three failures. A request that can't connect to a server is retried on another.

### HAProxy versions

The circuit uses each distribution's package, so the version follows the distribution, and there's no version to pin. On the hosts tested:

| Distribution | HAProxy |
| --- | --- |
| Ubuntu 24.04 | 2.8 |
| Debian 13 | 3.0 |
| Rocky Linux 10 | 3.0 |
| Fedora 45 | 3.4 |

Ubuntu 24.04's 2.8 is the oldest, but it's a long-term branch upstream supports until 2028, and everything the circuit writes works on it.

### What it doesn't do

- It doesn't write ACLs, redirects, `use_backend` rules, rate limits or per-server weights. Each frontend has one backend.
- It doesn't redirect HTTP to HTTPS. Bind a second frontend on port 80 if you want one there.
- It doesn't create certificates or open the firewall. See [circuit-firewall](https://github.com/conn3xorg/circuit-firewall) for that.
- Deleting the module leaves HAProxy installed and running with the last config.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan needs. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `frontends` | map(object) | `{}` | Frontends, by name. Each takes `bind`, an address and port such as `"*:80"`, `"10.0.0.5:443"` or `":::80"`; `default_backend`; optional `mode`, `http` (default) or `tcp`; and optional `tls_pem`, an absolute path to a PEM file or directory on the host, which turns TLS on. |
| `backends` | map(object) | `{}` | Backends, by name. Each takes `servers`, a map of server names to `"address:port"`; optional `balance`, one of `roundrobin` (default), `static-rr`, `leastconn`, `first`, `source`, `random` or `uri`; optional `check` (default `true`); and optional `check_path`, which makes the health check an HTTP `GET` on that path. |
| `timeouts` | object | `{}` | `connect` (default `"5s"`), `client` and `server` (default `"30s"`). Raise `client` and `server` for long-lived TCP connections, such as databases. |
| `stats` | object | `null` | The stats page. `null` leaves it off; `{}` turns it on. Takes optional `bind` (default `"127.0.0.1:8404"`), `uri` (default `"/stats"`) and `user` (default `"admin"`). |
| `stats_password` | string, sensitive | `null` | Password for the stats page. When null, the page has no login. 8 or more characters, with no spaces, `'` or `\`. |
| `selinux_connect_any` | bool | `true` | On hosts with SELinux on, turn on `haproxy_connect_any`, so HAProxy can listen on and connect to any port. |

## Outputs

| Name | Description |
| --- | --- |
| `config_file` | Path of the config the circuit writes, `/etc/haproxy/haproxy.cfg`. |

## Requirements

Requires Conn3x v0.6.5 or later and systemd on each host, with a package mirror the host can reach.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64, checks the second plan has no changes, starts two small web servers behind the frontend, checks requests reach both, then stops one and checks every request still succeeds from the other, that the stats page asks for a login, and that it shows the stopped server as down.

By hand on the Rocky Linux 10 container: a `tls_pem` pointing at a missing file stopped the apply with HAProxy's error and left the live config and the running HAProxy as they were; with the file in place, the TLS frontend answered; a tcp frontend with `balance leastconn` passed traffic; and the config change reloaded HAProxy under load with no failed requests.

On Ubuntu 24.04 and Rocky Linux 10 droplets (1 vCPU, 1 GB), the same balance-and-failover check passed. Rocky Linux ran with SELinux enforcing: HAProxy ran confined as `haproxy_t` and the audit log had no denials. Turning `haproxy_connect_any` off by hand brought back denials and 503s, the next plan showed the change, and the apply put it back. After a reboot, both droplets came back with HAProxy running, the boolean still on, and a plan with no changes.

## License

MPL-2.0. See [LICENSE](LICENSE). HAProxy itself is GPL-2.0.
