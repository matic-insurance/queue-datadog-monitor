# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
bin/setup                                   # bundle install
bundle exec rspec                           # all specs
bundle exec rspec path/to/file_spec.rb:42   # one spec
bundle exec rubocop                         # lint (-a autocorrects)
bin/console                                 # IRB with the gem loaded
```

## What this gem is

Datadog metrics for background job queues, shared across Matic applications. It emits two gauges:

| Metric | Tags |
| --- | --- |
| `solid_queue.process.utilization` | `process_id`, `process_tag` |
| `solid_queue.queue.latency` | `queue_name` |

Throughput and duration are out of scope — APM already reports them as `trace.active_job.perform`.

## Layout

The gem name and the namespace differ on purpose. `Queue` is a Ruby core class and raises `TypeError` when
reopened as a module, so the code lives under the queue backend's own namespace instead:

```
lib/solid_queue/datadog/monitor.rb          SolidQueue::Datadog::Monitor  — config + lifecycle
lib/solid_queue/datadog/monitor/metrics.rb  the collection and emission
lib/queue_datadog_monitor/version.rb        VERSION only, for the gemspec; 0.0.0 in git, set from the release tag
```

A second backend gets `lib/sidekiq/...` beside it, with its own `configure!`. Keep backend code out of
`lib/queue_datadog_monitor/`.

`Monitor` is a configured singleton: `configure!` registers the Solid Queue lifecycle hooks, `start!` builds the
statsd client and the timer, `shutdown!` tears both down. `Metrics` is a plain object constructed per `start!` and
holds no lifecycle state.

## Invariants

Each of these fails silently when broken — no exception, no log, just wrong or missing metrics.

- **`statsd.flush(sync: true)` ends every cycle.** `dogstatsd-ruby` buffers to 1432 bytes and sends only once
  that fills; a cycle this small takes many minutes to reach it.
- **Workers are scoped by `supervisor_id`.** A process killed past its grace period keeps its row until
  `process_alive_threshold` prunes it. Reporting rows this supervisor does not own gauges dead workers.
- **`fetch` the worker's thread count, never `to_f` on a possibly-nil value.** A nil ships `NaN` into a metric
  consumers autoscale on. Solid Queue 1.6 renamed the key from `thread_pool_size` to `pool_size`; both are read.
- **The queue list is read per cycle**, never memoised, or a queue created after boot is never reported.
- **`queue.latency` keeps its `queue_name` tag.** Consumers alert per queue; dropping the tag makes those
  monitors go quiet rather than fail.
- **Collection runs inside `wrap_in_app_executor`**, or the long-lived timer thread leaks its database connection
  and will not reconnect after a failover.
- **Errors go to the configured `on_error`.** `Concurrent::TimerTask` swallows exceptions.

Anything host-application-specific stays in the host application — notably the Solid Queue startup probe file,
which must not end up behind this gem's Datadog configuration.

## Specs

`spec_helper` boots a minimal `Rails::Application` against SQLite in memory and loads Solid Queue's own schema
from the installed gem. Load order matters: `require 'solid_queue'` must precede `TestApplication.initialize!` or
the engine's models never autoload.

Each example runs in a transaction that is rolled back.

`json` is pinned to `~> 2.21` in the Gemfile. ActiveSupport 8.1 calls `JSON.parse` with an argument list json 3.x
rejects, which surfaces as `ArgumentError: wrong number of arguments` from `create!` on any model with a
serialized column.

Cover behaviour by deleting it: a change to one of the invariants above should fail a spec.
