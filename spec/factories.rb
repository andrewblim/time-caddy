# frozen_string_literal: true

FactoryGirl.define do
  factory :user do
    username 'test'
    email 'test@test.com'
    disabled false
    password_hash 'abcdefg'
    password_salt 'abcdefg'
    default_tz 'America/New_York'
    signup_time Time.local(2101)
  end
end
