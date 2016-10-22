# frozen_string_literal: true

ENV['RACK_ENV'] ||= 'test'
require 'rspec'
require 'rack/test'

module RSpecMixin
  include Rack::Test::Methods
  def app
    described_class
  end
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups

  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.example_status_persistence_file_path = 'spec/examples.txt'

  if config.files_to_run.one?
    config.default_formatter = 'doc'
  end

  config.include RSpecMixin
end
