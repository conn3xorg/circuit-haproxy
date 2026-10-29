variable "port" {
  type    = number
  default = 2222
}

module "haproxy" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  # :8080 balances across two small web servers on 9001 and 9002, which the
  # circuit below gets ready. HAProxy checks each with GET /.
  frontends = {
    http_in = { bind = "*:8080", default_backend = "web" }
  }

  backends = {
    web = {
      servers    = { web1 = "127.0.0.1:9001", web2 = "127.0.0.1:9002" }
      check_path = "/"
    }
  }

  stats          = {}
  stats_password = "example-only"
}

# A page for each web server to serve, plus python3 to serve it and curl
# to fetch it with. It runs after the module, so its package runs don't
# overlap the module's.
circuit "content" {
  hosts = { box = "127.0.0.1" }

  ssh {
    user             = "root"
    port             = var.port
    private_key_file = "./id_ed25519"
    known_hosts_file = "./known_hosts"
  }

  step "tools" {
    for_each = ["python3", "curl"]
    package {
      name = item.value
    }
    depends_on = [module.haproxy]
  }

  step "page" {
    for_each = ["web1", "web2"]
    file {
      path    = "/srv/${item.value}/index.html"
      content = "Hello from ${item.value}.\n"
    }
  }
}
