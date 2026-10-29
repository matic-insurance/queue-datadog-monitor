# Changelog

## [0.3.0] - 2026-10-29

- Queue names come from the waiting jobs the cycle already groups, not from a `DISTINCT` over the jobs table. That
  scan, finished jobs included, could outlast a statement timeout on a large table.
- A failed cycle no longer breaks the cycles after it. The cached queue list could be left `nil` for five minutes,
  raising `NoMethodError` on every report in that window.
- A queue is reported once it has had a job waiting, and stays reported as 0 for the life of the process.
- New `queue_names` option to report queues from the first cycle, before any job has waited on them.

## [0.1.0] - 2026-09-24

Initial release.

- `solid_queue.process.utilization` — share of a worker's threads holding a job, per worker
- `solid_queue.queue.latency` — seconds the oldest waiting job has waited, per queue
- `solid_queue.queue.size` — jobs waiting, per queue
- `solid_queue.scheduled.size` — jobs scheduled for later
- `solid_queue.failed.size` — failed executions
