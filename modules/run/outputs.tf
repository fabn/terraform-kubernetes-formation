output "job_name" {
  description = "Name of the created Job (`<deployment>-<name>-` plus a server-generated suffix)."
  value       = kubernetes_job_v1.run.metadata[0].name
}
