# frozen_string_literal: true

require_relative '../time_caddy'
require 'pry'
require 'rspec'
require 'rack/test'

RSpec.describe TimeCaddy do
  it 'should allow accessing the home page' do
    get '/'
    expect(last_response).to be_ok
    get '/signup'
    expect(last_response).to be_ok
  end
end
