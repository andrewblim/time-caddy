# frozen_string_literal: true
ENV['RACK_ENV'] ||= 'test'
require_relative '../time_caddy'
require 'factory_girl'
require 'pry'
require 'rspec'
require 'rack/test'

module RSpecMixin
  include Rack::Test::Methods
  def app
    TimeCaddy
  end
end

RSpec.configure do |config|
  config.include FactoryGirl::Syntax::Methods
  config.before(:suite) do
    FactoryGirl.find_definitions
  end

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
