RSpec.describe SolidQueue::Datadog::Monitor do
  let(:statsd) { instance_double(Datadog::Statsd, close: nil) }
  let(:supervisor) { instance_double(SolidQueue::Supervisor, process_id: 1) }

  before do
    described_class.send(:reset!)
    SolidQueue::Supervisor.clear_hooks
    allow(Datadog::Statsd).to receive(:new).and_return(statsd)
  end

  after do
    described_class.shutdown!
    described_class.send(:reset!)
    SolidQueue::Supervisor.clear_hooks
  end

  it 'refuses a second configuration' do
    described_class.configure!

    expect { described_class.configure! }.to raise_error(described_class::Error)
  end

  it 'registers a start hook so collection begins with the supervisor' do
    expect { described_class.configure! }
      .to change { SolidQueue::Supervisor.lifecycle_hooks[:start].size }.from(0).to(1)
  end

  it 'registers a stop hook so the timer and socket are released' do
    expect { described_class.configure! }
      .to change { SolidQueue::Supervisor.lifecycle_hooks[:stop].size }.from(0).to(1)
  end

  it 'leaves the agent location to the environment when none is configured' do
    described_class.configure!
    described_class.start!(supervisor)

    expect(Datadog::Statsd).to have_received(:new).with(single_thread: true)
  end

  it 'uses an explicitly configured agent location' do
    described_class.configure!(agent_host: 'agent.local', agent_port: 8135)
    described_class.start!(supervisor)

    expect(Datadog::Statsd).to have_received(:new).with('agent.local', 8135, single_thread: true)
  end

  it 'routes a collection failure to the configured handler' do
    handled = nil
    task = instance_double(Concurrent::TimerTask, execute: nil, shutdown: nil)
    allow(Concurrent::TimerTask).to receive(:new).and_return(task)
    allow(task).to receive(:add_observer) { |&block| block.call(Time.now, nil, StandardError.new('boom')) }

    described_class.configure!(on_error: ->(error) { handled = error })
    described_class.start!(supervisor)

    expect(handled.message).to eq('boom')
  end

  it 'closes the statsd socket on shutdown' do
    described_class.configure!
    described_class.start!(supervisor)

    described_class.shutdown!

    expect(statsd).to have_received(:close)
  end

  it 'tolerates a shutdown in a process that never started collection' do
    described_class.configure!

    expect { described_class.shutdown! }.not_to raise_error
  end
end
