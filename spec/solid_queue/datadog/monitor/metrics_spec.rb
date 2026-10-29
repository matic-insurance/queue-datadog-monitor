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

  def build_metrics(tags: [], queue_names: [])
    described_class.new(statsd: statsd, supervisor: supervisor, tags: tags, queue_names: queue_names)
  end

  def report(tags: [])
    build_metrics(tags: tags).report
  end

  def sql_issued_by(&block)
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    statements
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
    enqueue_job(queue_name: 'mailers').ready_execution.update!(created_at: 90.seconds.ago)

    report

    expect(statsd).to have_received(:gauge).with('solid_queue.queue.latency', 90, { tags: ['queue_name:mailers'] })
  end

  it 'reports zero rather than nothing for a queue whose jobs have all been picked up' do
    metrics = build_metrics
    enqueue_job(queue_name: 'mailers')
    metrics.report
    SolidQueue::ReadyExecution.claim('mailers', 1, own_worker.id)

    metrics.report

    expect(statsd).to have_received(:gauge).with('solid_queue.queue.size', 0, { tags: ['queue_name:mailers'] })
  end

  it 'keeps reporting a queue that has gone quiet, so consumers see zero rather than no data' do
    metrics = build_metrics
    enqueue_job(queue_name: 'mailers').ready_execution.update!(created_at: 90.seconds.ago)
    metrics.report
    SolidQueue::ReadyExecution.claim('mailers', 1, own_worker.id)

    metrics.report

    expect(statsd).to have_received(:gauge).with('solid_queue.queue.latency', 0, { tags: ['queue_name:mailers'] })
  end

  it 'reports a configured queue as zero before any job has waited on it' do
    build_metrics(queue_names: ['reports']).report

    expect(statsd).to have_received(:gauge).with('solid_queue.queue.size', 0, { tags: ['queue_name:reports'] })
  end

  it 'finds queues without scanning the jobs table, which holds every finished job too' do
    enqueue_job(queue_name: 'mailers')

    statements = sql_issued_by { report }

    expect(statements.grep(/solid_queue_jobs/)).to be_empty
  end

  it 'reports queues again on the cycle after one whose query failed' do
    metrics = build_metrics
    enqueue_job(queue_name: 'mailers')
    allow(SolidQueue::ReadyExecution).to receive(:group).and_raise(ActiveRecord::QueryCanceled)
    expect { metrics.report }.to raise_error(ActiveRecord::QueryCanceled)
    allow(SolidQueue::ReadyExecution).to receive(:group).and_call_original

    metrics.report

    expect(statsd).to have_received(:gauge).with('solid_queue.queue.size', 1, { tags: ['queue_name:mailers'] })
  end

  it 'reports how many jobs are waiting on each queue' do
    2.times { enqueue_job(queue_name: 'mailers') }

    report

    expect(statsd).to have_received(:gauge).with('solid_queue.queue.size', 2, { tags: ['queue_name:mailers'] })
  end

  it 'reports how many jobs are scheduled for later' do
    SolidQueue::Job.create!(class_name: 'SomeJob', queue_name: 'default', scheduled_at: 1.hour.from_now)

    report

    expect(statsd).to have_received(:gauge).with('solid_queue.scheduled.size', 1, { tags: [] })
  end

  it 'reports how many executions have failed' do
    2.times { fail_job(StandardError.new('boom')) }

    report

    expect(statsd).to have_received(:gauge).with('solid_queue.failed.size', 2, { tags: [] })
  end

  it 'appends the configured common tags to every metric' do
    enqueue_job(queue_name: 'mailers')

    report(tags: ['env:production', 'product:my-app'])

    expect(statsd).to have_received(:gauge)
      .with('solid_queue.queue.size', 1, { tags: ['queue_name:mailers', 'env:production', 'product:my-app'] })
  end

  it 'picks up a new queue on the first cycle a job waits on it' do
    metrics = build_metrics
    metrics.report
    enqueue_job(queue_name: 'appeared-later')

    metrics.report

    expect(statsd).to have_received(:gauge)
      .with('solid_queue.queue.size', 1, { tags: ['queue_name:appeared-later'] })
  end

  it 'flushes the gauges, which a cycle this small leaves buffered otherwise' do
    report

    expect(statsd).to have_received(:flush).with(sync: true)
  end
end
