module SolidQueue
  module Datadog
    module Monitor
      class Metrics
        include SolidQueue::AppExecutor

        PROCESS_TAG = 'process_tag:solid_queue'.freeze

        def initialize(statsd:, supervisor:, tags: [])
          @statsd = statsd
          @supervisor = supervisor
          @common_tags = tags
        end

        def report
          wrap_in_app_executor do
            report_worker_utilization
            report_queue_latency
          end

          statsd.flush(sync: true)
        end

        private

        attr_reader :statsd, :supervisor, :common_tags

        def report_worker_utilization
          own_workers.find_each do |worker|
            record_current_value('solid_queue.process.utilization', utilization_of(worker), tags_for(worker))
          end
        end

        def report_queue_latency
          SolidQueue::ReadyExecution.group(:queue_name).minimum(:created_at).each do |queue_name, enqueued_at|
            record_current_value('solid_queue.queue.latency', seconds_since(enqueued_at), ["queue_name:#{queue_name}"])
          end
        end

        def record_current_value(metric, value, tags = [])
          statsd.gauge(metric, value, tags: tags + common_tags)
        end

        def own_workers
          SolidQueue::Process.where(kind: 'Worker', supervisor_id: supervisor.process_id)
        end

        def utilization_of(worker)
          claimed = SolidQueue::ClaimedExecution.where(process_id: worker.id).count

          ((claimed / worker.metadata.fetch('thread_pool_size').to_f) * 100).round(2)
        end

        def tags_for(worker)
          ["process_id:#{worker.hostname}_#{worker.name}", PROCESS_TAG]
        end

        def seconds_since(time)
          return 0 if time.blank?

          (Time.current - time).to_i
        end
      end
    end
  end
end
