output "service" {
  description = "The systemd service that runs Kestra on each host."
  value       = "kestra.service"
}

output "image" {
  description = "The Kestra image the hosts run."
  value       = local.image
}

output "url" {
  description = "Where Kestra answers on each host itself, such as \"http://127.0.0.1:8080\". Point a reverse proxy here."
  value       = local.local_url
}

output "data_dir" {
  description = "Directory on each host holding Kestra's files and, without postgres, its H2 database. Back it up."
  value       = local.parent
}
