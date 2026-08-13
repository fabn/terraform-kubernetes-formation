output "cron_job_name" {
  description = "Name of the created CronJob (`<deployment>-<name>`)."
  value       = kubernetes_cron_job_v1.cron.metadata[0].name
}

output "schedule" {
  description = "Cron expression the CronJob was created with."
  value       = kubernetes_cron_job_v1.cron.spec[0].schedule
}
