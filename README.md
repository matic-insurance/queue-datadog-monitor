# queue-datadog-monitor

Datadog metrics for background job queues — how loaded the workers are, and how long work has been waiting to
start. Enough to alert on a backlog and to autoscale workers on a real number.

Solid Queue today. The gem is laid out so another backend gets its own entry point beside it, which is why it is
not named after any one queue library.

## Installation

Published to Matic's GitHub Packages registry:

```ruby
gem 'queue-datadog-monitor', '~> 0.1', source: 'https://rubygems.pkg.github.com/matic-insurance'
```

Give Bundler the credentials through its config, never in the Gemfile:
`bundle config set rubygems.pkg.github.com <user>:<token>`, or `BUNDLE_RUBYGEMS__PKG__GITHUB__COM` in CI.

Requiring the gem by its own name loads nothing but the version. Require the backend you use, in the initializer
that configures it — an application on a different queue never loads Solid Queue support.

## Usage

```ruby
require 'solid_queue/datadog/monitor'

SolidQueue::Datadog::Monitor.configure!(
  tags: ['team:payments'],
  on_error: ->(error) { Sentry.capture_exception(error) }
)
```

Call `configure!` once at boot, in an initializer. It registers `SolidQueue.on_start` and `on_stop` hooks and does
nothing in a process that never starts Solid Queue.

| Option | Default | |
| --- | --- | --- |
| `tags` | `[]` | Appended to every metric |
| `on_error` | warns on stderr | Called with anything raised while collecting |
| `agent_host` | `DD_AGENT_HOST`, else `127.0.0.1` | |
| `agent_port` | `DD_DOGSTATSD_PORT`, else `8125` | |

Pass `agent_host` and `agent_port` only when the agent is somewhere other than where `dogstatsd-ruby` already
looks. On a deployment that injects the standard Datadog environment, no argument is needed at all.

Do not pass `service`, `env` or `product` as tags. The agent already attaches them, and passing them again
duplicates the tag rather than setting it. Use `tags` for dimensions nothing else supplies.

## Metrics

| Metric | Tags | Means |
| --- | --- | --- |
| `solid_queue.process.utilization` | `process_id`, `process_tag` | Share of a worker's threads holding a job, as a percentage |
| `solid_queue.queue.latency` | `queue_name` | Seconds the oldest job waiting on that queue has waited |
| `solid_queue.queue.size` | `queue_name` | Jobs waiting on that queue |
| `solid_queue.scheduled.size` | — | Jobs scheduled for later, whether or not they are due |
| `solid_queue.failed.size` | `cause` | Failed executions, split into `process_termination` and `other` |

Read them together. Utilization answers "are the threads busy", latency answers "is anything waiting". Utilization
saturates at 100 — Solid Queue caps claims at the number of idle threads, so ten queued jobs and a hundred
thousand both read 100%.

A queue with nothing waiting emits no point for either `queue.latency` or `queue.size`. Read them as
`max:...{...} by {queue_name}` and treat gaps as idle rather than filling them with zero — a zero would make a
dead emitter look like a healthy idle queue.

`failed.size` is reported as two series that sum to the total, so use `sum:` rather than `avg:` for an overall
count. The `process_termination` half counts jobs whose worker was killed before they finished, which is the
cost of terminating a pod while it holds work — worth watching if you autoscale.

Throughput, duration and error rate per job class are not here — APM reports them as `trace.active_job.perform`.

Planned: the age of a worker's longest-running job, and dispatcher lag measured as the oldest scheduled job that
is already due.

## How it works

A `Concurrent::TimerTask` collects once per `SolidQueue.process_heartbeat_interval`, started from the
`SolidQueue.on_start` hook. That hook runs in the supervisor, once per process, before it forks its workers.
Collection runs inside Solid Queue's app executor, so the timer thread returns its database connection and
reconnects cleanly after a failover.

Each supervisor reports only the workers it owns, scoped by `supervisor_id`. A process killed past its grace
period leaves its row in the database until `process_alive_threshold` prunes it several minutes later; reporting
rows you do not own means gauging that dead worker for those minutes.

**The flush is load-bearing.** Each cycle ends with `statsd.flush(sync: true)`. `dogstatsd-ruby` holds metrics in
a 1432-byte buffer and sends only once it fills, which a cycle this small takes many minutes to do. Without the
flush, metrics arrive late and in clumps, and nothing reports an error. Do not remove it.

**Pass `on_error`.** `Concurrent::TimerTask` swallows exceptions. Without a reporter, a persistent database error
stops the metrics silently and the series goes stale.

**Keep your Solid Queue startup probe in your own `on_start` hook**, not behind this gem's configuration, or the
probe ends up depending on Datadog being enabled.

## Development

```bash
bin/setup
bundle exec rspec
bundle exec rubocop
```

Specs run against SQLite in memory, booting a minimal Rails application and loading Solid Queue's own schema.

## Release

Publish a GitHub release named after the version, e.g. `0.2.0` (no `v`). CircleCI sets the version from the tag,
builds the gem and pushes it to GitHub Packages. `version.rb` stays `0.0.0` in git.
