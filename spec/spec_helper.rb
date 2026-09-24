require 'logger'
require 'rails'
require 'active_record/railtie'
require 'active_job/railtie'
require 'solid_queue'

ENV['RAILS_ENV'] = 'test'

class TestApplication < Rails::Application
  config.eager_load = false
  config.logger = Logger.new(IO::NULL)
  config.root = File.expand_path('..', __dir__)
  config.paths['config/database'] = File.expand_path('database.yml', __dir__)
  config.active_job.queue_adapter = :test
end

TestApplication.initialize!
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')

require 'solid_queue/datadog/monitor'

ActiveRecord::Schema.verbose = false
load "#{Gem.loaded_specs['solid_queue'].full_gem_path}/lib/generators/solid_queue/install/templates/db/queue_schema.rb"

require 'active_support/testing/time_helpers'

RSpec.configure do |config|
  config.include ActiveSupport::Testing::TimeHelpers

  config.expect_with(:rspec) { |expectations| expectations.include_chain_clauses_in_custom_matcher_descriptions = true }
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }
  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.order = :random

  config.around do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end
end
