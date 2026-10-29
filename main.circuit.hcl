# Facts give each host's distribution: the Red Hat family runs SELinux,
# which limits the ports HAProxy may use.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os         = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  rpm_hosts  = { for name, h in var.hosts : name => h if !contains(["debian", "ubuntu"], local.os[name]) }
  config     = "/etc/haproxy/haproxy.cfg"
  candidate  = "/etc/haproxy/haproxy.cfg.conn3x"
  has_secret = nonsensitive(var.stats_password != null)

  # A backend speaks whatever its frontends do. One no frontend uses is http.
  backend_mode = { for b in keys(var.backends) : b => try([for f in values(var.frontends) : f.mode if f.default_backend == b][0], "http") }

  # Logs go to stdout, which systemd sends to the journal, so there is no
  # syslog socket to set up inside the chroot.
  haproxy_cfg = join("\n", concat(
    [
      <<-EOT
      # Written by Conn3x. Changes here are overwritten on the next apply.
      global
          log stdout format raw local0
          chroot /var/lib/haproxy
          user haproxy
          group haproxy

      defaults
          log global
          option dontlognull
          option redispatch
          retries 3
          timeout connect ${var.timeouts.connect}
          timeout client ${var.timeouts.client}
          timeout server ${var.timeouts.server}
      EOT
    ],
    [for name, f in var.frontends : "${join("\n", compact([
      "frontend ${name}",
      "    bind ${f.bind}${f.tls_pem == null ? "" : " ssl crt ${f.tls_pem}${f.mode == "http" ? " alpn h2,http/1.1" : ""}"}",
      "    mode ${f.mode}",
      f.mode == "http" ? "    option httplog" : "    option tcplog",
      f.mode == "http" ? "    option forwardfor" : "",
      f.mode == "http" && f.tls_pem != null ? "    http-request set-header X-Forwarded-Proto https" : "",
      "    default_backend ${f.default_backend}",
    ]))}\n"],
    [for name, b in var.backends : "${join("\n", compact(concat(
      [
        "backend ${name}",
        "    mode ${local.backend_mode[name]}",
        "    balance ${b.balance}",
        b.check && b.check_path != null ? "    option httpchk\n    http-check send meth GET uri ${b.check_path}" : "",
      ],
      [for s, addr in b.servers : "    server ${s} ${addr}${b.check ? " check" : ""}"],
    )))}\n"],
    var.stats == null ? [] : ["${join("\n", compact([
      "listen stats",
      "    bind ${var.stats.bind}",
      "    mode http",
      "    stats enable",
      "    stats uri ${var.stats.uri}",
      "    stats refresh 10s",
      local.has_secret ? "    stats auth '${var.stats.user}:${var.stats_password}'" : "",
    ]))}\n"],
  ))
}

# SELinux lets HAProxy listen on and connect to a short list of ports, such
# as 80, 443 and 8080. haproxy_connect_any opens the rest, which backends on
# their own ports need. Hosts without SELinux on are left alone.
circuit "haproxy_selinux" {
  hosts = var.selinux_connect_any ? local.rpm_hosts : {}

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "connect_any" {
    command {
      command = "setsebool -P haproxy_connect_any 1"
      unless  = "! selinuxenabled || getsebool haproxy_connect_any | grep -q -- '--> on$'"
    }
  }
}

circuit "haproxy" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "package" {
    package {
      name = "haproxy"
    }
    depends_on = [conn3x_command.haproxy_selinux__connect_any]
  }

  # The rendered config lands beside the live one first. With a stats
  # password in it, it goes through content_wo, which keeps it out of state
  # and out of the plan; without one, the plan shows the diff.
  step "candidate" {
    for_each = local.has_secret ? [] : ["config"]
    file {
      path    = local.candidate
      content = local.haproxy_cfg
      mode    = "0600"
    }
  }

  step "candidate_secret" {
    for_each = local.has_secret ? ["config"] : []
    file {
      path       = local.candidate
      content_wo = local.haproxy_cfg
      mode       = "0600"
    }
  }

  # Copies the candidate over the live config only once haproxy -c accepts
  # it, so a typo or a missing certificate never reaches the running
  # HAProxy. Also puts it back after a hand edit to the live file.
  step "config" {
    command {
      command  = "haproxy -c -f ${local.candidate} && install -m 600 ${local.candidate} ${local.config}"
      unless   = "[ \"$(sha256sum < ${local.candidate})\" = \"$(sha256sum < ${local.config})\" ]"
      triggers = { candidate = try(conn3x_file.haproxy__candidate["${each.key}/config"].revision, conn3x_file.haproxy__candidate_secret["${each.key}/config"].revision) }
    }
    notify = [handler.reload]
  }

  step "running" {
    service {
      name    = "haproxy"
      state   = "started"
      enabled = true
    }
  }

  # A reload starts new workers on the new config and lets the old ones
  # finish their connections, so no request is dropped.
  handler "reload" {
    service {
      name   = "haproxy"
      action = "reload"
    }
  }
}
