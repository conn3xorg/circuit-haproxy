output "config_file" {
  description = "Path of the HAProxy config the circuit writes on each host."
  value       = local.config
}
