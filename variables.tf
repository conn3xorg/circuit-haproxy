variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "centos", "fedora"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux, rhel, centos or fedora."
  }
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

variable "frontends" {
  type = map(object({
    bind            = string
    mode            = optional(string, "http")
    tls_pem         = optional(string)
    default_backend = string
  }))
  default     = {}
  description = "Frontends, by name. Each listens on bind, such as \"*:80\" or \"10.0.0.5:443\", in mode http or tcp, and sends traffic to default_backend. tls_pem, a PEM file or directory on the host, turns TLS on."

  validation {
    condition     = alltrue([for name in keys(var.frontends) : can(regex("^[A-Za-z0-9_.-]+$", name)) && name != "stats"])
    error_message = "Frontend names may use letters, digits, ., - and _, and can't be stats, which the stats page uses."
  }

  validation {
    condition     = alltrue([for f in values(var.frontends) : can(regex("^[^\\s]*:[0-9]{1,5}$", f.bind))])
    error_message = "A frontend's bind is an address and port, such as \"*:80\", \"10.0.0.5:443\" or \":::80\" for IPv6."
  }

  validation {
    condition     = alltrue([for f in values(var.frontends) : contains(["http", "tcp"], f.mode)])
    error_message = "A frontend's mode is http or tcp."
  }

  validation {
    condition     = alltrue([for f in values(var.frontends) : f.tls_pem == null || can(regex("^/[^\\s]*$", coalesce(f.tls_pem, "-")))])
    error_message = "A frontend's tls_pem must be an absolute path with no spaces."
  }

  validation {
    condition     = alltrue([for f in values(var.frontends) : contains(keys(var.backends), f.default_backend)])
    error_message = "Each frontend's default_backend must be one of the backends."
  }

  # HAProxy 3.3 and later refuse a frontend and a backend with one name.
  validation {
    condition     = length(setintersection(keys(var.frontends), keys(var.backends))) == 0
    error_message = "A frontend and a backend can't share a name; HAProxy 3.3 and later refuse it. Name them apart, such as frontend \"http_in\" and backend \"web\"."
  }

  # HAProxy refuses an http frontend that sends to a tcp backend, and each
  # backend takes its mode from the frontends that use it.
  validation {
    condition     = alltrue([for b in keys(var.backends) : length(distinct([for f in values(var.frontends) : f.mode if f.default_backend == b])) <= 1])
    error_message = "Frontends that share a backend must use the same mode."
  }
}

variable "backends" {
  type = map(object({
    servers    = map(string)
    balance    = optional(string, "roundrobin")
    check      = optional(bool, true)
    check_path = optional(string)
  }))
  default     = {}
  description = "Backends, by name. servers maps each server's name to its address and port. check turns health checks on; check_path makes them HTTP requests for that path instead of a TCP connect."

  validation {
    condition     = alltrue([for name in keys(var.backends) : can(regex("^[A-Za-z0-9_.-]+$", name)) && name != "stats"])
    error_message = "Backend names may use letters, digits, ., - and _, and can't be stats, which the stats page uses."
  }

  validation {
    condition     = alltrue(flatten([for b in values(var.backends) : [for name, addr in b.servers : can(regex("^[A-Za-z0-9_.-]+$", name)) && can(regex("^[^\\s]+:[0-9]{1,5}$", addr))]]))
    error_message = "Server names may use letters, digits, ., - and _, and each address is a host and port, such as \"10.0.0.11:8080\"."
  }

  validation {
    condition     = alltrue([for b in values(var.backends) : contains(["roundrobin", "static-rr", "leastconn", "first", "source", "random", "uri"], b.balance)])
    error_message = "A backend's balance is one of roundrobin, static-rr, leastconn, first, source, random or uri."
  }

  validation {
    condition     = alltrue([for b in values(var.backends) : b.check_path == null || can(regex("^/[^\\s]*$", coalesce(b.check_path, "-")))])
    error_message = "A backend's check_path starts with / and has no spaces, such as \"/healthz\"."
  }
}

variable "timeouts" {
  type = object({
    connect = optional(string, "5s")
    client  = optional(string, "30s")
    server  = optional(string, "30s")
  })
  default     = {}
  description = "How long HAProxy waits to connect to a server, and for the client or server to send something before it closes the connection. Raise client and server for long-lived TCP connections, such as databases."

  validation {
    condition     = alltrue([for t in values(var.timeouts) : can(regex("^[0-9]+(us|ms|s|m|h|d)?$", t))])
    error_message = "Timeouts are a number with an optional unit: us, ms, s, m, h or d, such as \"30s\" or \"1h\"."
  }
}

variable "stats" {
  type = object({
    bind = optional(string, "127.0.0.1:8404")
    uri  = optional(string, "/stats")
    user = optional(string, "admin")
  })
  default     = null
  description = "HAProxy's stats page. null leaves it off; {} turns it on at http://127.0.0.1:8404/stats."

  validation {
    condition     = var.stats == null || can(regex("^[^\\s]*:[0-9]{1,5}$", try(var.stats.bind, "")))
    error_message = "stats.bind is an address and port, such as \"127.0.0.1:8404\"."
  }

  validation {
    condition     = var.stats == null || can(regex("^/[^\\s]*$", try(var.stats.uri, "")))
    error_message = "stats.uri starts with / and has no spaces."
  }

  validation {
    condition     = var.stats == null || can(regex("^[A-Za-z0-9_.-]+$", try(var.stats.user, "")))
    error_message = "stats.user may use letters, digits, ., - and _."
  }
}

variable "stats_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Password for the stats page, with stats.user. When null, the page has no login, so keep it on 127.0.0.1."

  validation {
    condition     = var.stats_password == null || can(regex("^[^\\s'\\\\]{8,}$", coalesce(var.stats_password, "-")))
    error_message = "stats_password must be 8 or more characters, with no spaces, quotes ' or backslashes."
  }
}

variable "selinux_connect_any" {
  type        = bool
  default     = true
  description = "On hosts with SELinux on, turn on the haproxy_connect_any boolean, so HAProxy can listen on and connect to any port. Set false to keep the policy's port list and label ports yourself."
}
