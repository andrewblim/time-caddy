# frozen_string_literal: true
require 'spec_helper'

RSpec.describe User do
  it 'disallows two users with the same username' do
    expect(create(:user, username: 'test', email: 'test@test.com')).to be_truthy
    expect { create(:user, username: 'test', email: 'test2@test.com') }.to raise_error ActiveRecord::RecordNotUnique
    expect(create(:user, username: 'test2', email: 'test2@test.com')).to be_truthy
  end

  it 'disallows two users with the same email' do
    expect(create(:user, username: 'test', email: 'test@test.com')).to be_truthy
    expect { create(:user, username: 'test2', email: 'test@test.com') }.to raise_error ActiveRecord::RecordNotUnique
    expect(create(:user, username: 'test2', email: 'test2@test.com')).to be_truthy
  end
end
