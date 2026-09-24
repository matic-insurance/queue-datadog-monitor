RSpec.describe SolidQueue::Datadog::Monitor::Metrics do
  let(:statsd) { instance_double(Datadog::Statsd, gauge: nil, flush: nil) }
  let(:own_supervisor) { create_process(kind: 'Supervisor', name: 'supervisor-a', hostname: 'pod-a') }
  let(:foreign_supervisor) { create_process(kind: 'Supervisor', name: 'supervisor-b', hostname: 'pod-b') }
  let(:supervisor) { instance_double(SolidQueue::Supervisor, process_id: own_supervisor.id) }

  let(:own_worker) do
    create_process(kind: 'Worker', name: 'worker-a', hostname: 'pod-a',
                   supervisor_id: own_supervisor.id, metadata: worker_metadata(threads: 10))
  end

  let(:foreign_worker) do
    create_process(kind: 'Worker', name: 'worker-b', hostname: 'pod-b',
                   supervisor_id: foreign_supervisor.id, metadata: worker_metadata(threads: 10))
  end

  def create_process(attributes)
    SolidQueue::Process.create!({ pid: SecureRandom.random_number(10_000), last_heartbeat_at: Time.current }
                                 .merge(attributes))
  end

  # What the installed Solid Queue actually registers, so a renamed key fails here
  def worker_metadata(threads:)
    SolidQueue::Worker.new(queues: '*', threads: threads).metadata
  end

  def enqueue_job(queue_name: 'default')
    SolidQueue::Job.create!(class_name: 'SomeJob', queue_name: queue_name)
  end

  def claim_jobs(process, count)
    count.times { enqueue_job }
    SolidQueue::ReadyExecution.claim('*', count, process.id)
  end

  def fail_job(exception)
    SolidQueue::FailedExecution.create!(job: enqueue_job, exception: exception)
  end

  def report(tags: [])
    described_class.new(statsd: statsd, supervisor: supervisor, tags: tags).report
  end

  before do
    claim_jobs(own_worker, 3)
    claim_jobs(foreign_worker, 3)
  end

  it 'reports thread utilization for the workers of its own supervisor only' do
    report

    expect(statsd).to have_received(:gauge)
      .with('solid_queue.process.utilization', 30.0, { tags: array_including('process_tag:solid_queue') })
      .once
  end

  it 'reads the thread count Solid Queue before 1.6 registered as thread_pool_size' do
    own_worker.update!(metadata: { thread_pool_size: 10 })

    report

    expect(statsd).to have_received(:gauge).with('solid_queue.process.utilization', 30.0, anything)
  end

  it 'reports the age of the oldest waiting job for each queue separately' do
    enqueue_job(queue_name: 'sourcing').ready_execution.update!(created_at: 90.seconds.ago)

    report

    expect(statsd).to have_received(:gauge).with('solid_queue.queue.latency', 90, { tags: ['queue_name:sourcing'] })
  end

  it 'reports nothing for a queue with no jobs waiting' do
    report

    expect(statsd).not_to have_received(:gauge).with('solid_queue.queue.latency', anything, anything)
  end

  it 'reports how many jobs are waiting on each queue' do
    2.times { enqueue_job(queue_name: 'sourcing') }

    report

    expect(statsd).to have_received(:gauge).with('solid_queue.queue.size', 2, { tags: ['queue_name:sourcing'] })
  end

  it 'reports how many jobs are scheduled for later' do
    SolidQueue::Job.create!(class_name: 'SomeJob', queue_name: 'default', scheduled_at: 1.hour.from_now)

    report

    expect(statsd).to have_received(:gauge).with('solid_queue.scheduled.size', 1, { tags: [] })
  end

  it 'counts the jobs their process was killed underneath separately from other failures' do
    fail_job(SolidQueue::Processes::ProcessPrunedError.new(2.minutes.ago))
    fail_job(StandardError.new('something else'))

    report

    expect(statsd).to have_received(:gauge)
      .with('solid_queue.failed.size', 1, { tags: ['cause:process_termination'] })
  end

  it 'counts the remaining failures under the other cause' do
    fail_job(SolidQueue::Processes::ProcessPrunedError.new(2.minutes.ago))
    fail_job(StandardError.new('something else'))

    report

    expect(statsd).to have_received(:gauge).with('solid_queue.failed.size', 1, { tags: ['cause:other'] })
  end

  it 'appends the configured common tags to every metric' do
    enqueue_job(queue_name: 'sourcing')

    report(tags: ['env:production', 'product:my-app'])

    expect(statsd).to have_received(:gauge)
      .with('solid_queue.queue.latency', 0, { tags: ['queue_name:sourcing', 'env:production', 'product:my-app'] })
  end

  it 'flushes the gauges, which a cycle this small leaves buffered otherwise' do
    report

    expect(statsd).to have_received(:flush).with(sync: true)
  end
end
