# frozen_string_literal: true
require 'spec_helper'

RSpec.describe Routes::Basic do
  it 'recognizes when you are not logged in on the home page' do
    get '/'
    expect(last_response).to be_ok
  end

  it 'recognizes when you are logged in on the home page' do
    get '/'
    expect(last_response).to be_ok
  end

  it 'allows access to the about page' do
    get '/about'
    expect(last_response).to be_ok
  end
end
