# Memcached addon (Rails :mem_cache_store). Deliberately ephemeral: no PVC,
# a pod restart cold-starts an empty cache and Rails treats it as a miss.
# No ingress/probes — the kubelet restarts the pod on process exit, the only
# failure mode that matters for a cache. Extracted from modules/annamode/cache.tf.

module "memcached" {
  source  = "fabn/workload/kubernetes"
  version = "~> 0.5"

  name      = var.name
  namespace = var.namespace
  image     = var.image

  # `-m` caps item memory (MB); limits sized for slab + connection overhead.
  command = ["memcached", "-m", tostring(var.max_memory)]
  ports   = { memcache = 11211 }

  cpu_requests    = var.cpu_requests
  memory_requests = var.memory_requests
  memory_limits   = "${ceil(var.max_memory * 1.25)}Mi"
}
