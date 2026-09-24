require 'solid_queue'
require 'datadog/statsd'
require 'concurrent'

require 'solid_queue/datadog/monitor/metrics'

module SolidQueue
  module Datadog
    module Monitor
      class Error < StandardError; end

      DEFAULT_ERROR_HANDLER = ->(error) { warn("[queue-datadog-monitor] #{error.class}: #{error.message}") }

      class << self
        attr_reader :agent_host, :agent_port, :tags, :error_handler, :statsd

        def configure!(options = {})
          raise Error, "Can't configure two times" if configured?

          @agent_host = options[:agent_host]
          @agent_port = options[:agent_port]
          @tags = options[:tags] || []
          @error_handler = options[:on_error] || DEFAULT_ERROR_HANDLER
          @configured = true

          register_lifecycle_hooks
        end

        def configured?
          @configured == true
        end

        def start!(supervisor)
          @statsd = build_statsd
          metrics = Metrics.new(statsd: @statsd, supervisor: supervisor, tags: tags)

          @task = Concurrent::TimerTask.new(execution_interval: SolidQueue.process_heartbeat_interval) do
            metrics.report
          end
          @task.add_observer { |_time, _result, error| error_handler.call(error) if error }
          @task.execute
        end

        def shutdown!
          return if @task.nil?

          @task.shutdown
          @task = nil
          @statsd.close
          @statsd = nil
        end

        private

        def register_lifecycle_hooks
          SolidQueue.on_start { |supervisor| start!(supervisor) }
          SolidQueue.on_stop { shutdown! }
        end

        def build_statsd
          return ::Datadog::Statsd.new(single_thread: true) if agent_host.nil?

          ::Datadog::Statsd.new(agent_host, agent_port, single_thread: true)
        end

        def reset!
          @configured = false
          @agent_host = nil
          @agent_port = nil
          @tags = nil
          @error_handler = nil
          @task = nil
          @statsd = nil
        end
      end
    end
  end
end
