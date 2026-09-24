require_relative 'lib/queue_datadog_monitor/version'

Gem::Specification.new do |spec|
  spec.name = 'queue-datadog-monitor'
  spec.version = QueueDatadogMonitor::VERSION
  spec.authors = ['Andrii Kozubenko']
  spec.email = ['andrii.k@matic.com']

  spec.summary = 'Datadog metrics for background job queues'
  spec.description = 'Reports worker utilization and queue latency to Datadog. ' \
                     'Solid Queue today; one entry point per queue backend.'
  spec.homepage = 'https://github.com/matic-insurance/queue-datadog-monitor'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == File.basename(__FILE__)) || f.match(%r{\A(?:(?:bin|spec|features)/|\.(?:git|github|rspec|rubocop|tool))})
    end
  end
  spec.require_paths = ['lib']

  spec.add_dependency 'concurrent-ruby', '>= 1.1'
  spec.add_dependency 'dogstatsd-ruby', '>= 5.0'
  spec.add_dependency 'solid_queue', '>= 1.0'
end
