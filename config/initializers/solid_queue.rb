# The connections that bring mail and texts in seconds (MailIdler, #262) live
# in the job role's mail worker (config/queue.yml). That worker is one
# process, so an install has exactly one idler, whatever JOB_CONCURRENCY the
# shared worker runs at, and the deploy gains no role: the job role still runs
# bin/jobs. A worker that dies is replaced by Solid Queue's supervisor, and
# the idler starts with it; EmailFetchJob's minute covers the gap.
SolidQueue.on_worker_start do |worker|
  MailIdler.start if worker.queues.include?(MailIdler::QUEUE)
end

SolidQueue.on_worker_stop { MailIdler.stop }
