module SolidQueue
  module Datadog
    module Monitor
      class Metrics
        include SolidQueue::AppExecutor

        PROCESS_TAG = 'process_tag:solid_queue'.freeze

        QUEUE_NAMES_TTL = 5.minutes

        def initialize(statsd:, supervisor:, tags: [])
          @statsd = statsd
          @supervisor = supervisor
          @common_tags = tags
        end

        def report
          wrap_in_app_executor do
            report_worker_utilization
            report_queues
            report_scheduled_size
            report_failed_size
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

        def report_queues
          sizes = SolidQueue::ReadyExecution.group(:queue_name).count
          oldest = SolidQueue::ReadyExecution.group(:queue_name).minimum(:created_at)

          known_queue_names.each do |queue_name|
            tags = ["queue_name:#{queue_name}"]

            record_current_value('solid_queue.queue.size', sizes.fetch(queue_name, 0), tags)
            record_current_value('solid_queue.queue.latency', seconds_since(oldest[queue_name]), tags)
          end
        end

        def known_queue_names
          return @known_queue_names if @known_queue_names_read_at && @known_queue_names_read_at > QUEUE_NAMES_TTL.ago

          @known_queue_names_read_at = Time.current
          @known_queue_names = SolidQueue::Job.distinct.pluck(:queue_name)
        end

        def report_scheduled_size
          record_current_value('solid_queue.scheduled.size', SolidQueue::ScheduledExecution.count)
        end

        def report_failed_size
          record_current_value('solid_queue.failed.size', SolidQueue::FailedExecution.count)
        end

        def record_current_value(metric, value, tags = [])
          statsd.gauge(metric, value, tags: tags + common_tags)
        end

        def own_workers
          SolidQueue::Process.where(kind: 'Worker', supervisor_id: supervisor.process_id)
        end

        def utilization_of(worker)
          claimed = SolidQueue::ClaimedExecution.where(process_id: worker.id).count

          ((claimed / pool_size_of(worker).to_f) * 100).round(2)
        end

        def pool_size_of(worker)
          worker.metadata.fetch('pool_size') { worker.metadata.fetch('thread_pool_size') }
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
