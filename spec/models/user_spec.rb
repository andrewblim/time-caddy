# frozen_string_literal: true
require 'spec_helper'

RSpec.describe User do
  let(:user) { build(:user) }
  it 'make sure factorygirl is working' do
    expect(user.username).to eq('test')
  end
end
