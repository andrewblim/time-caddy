# frozen_string_literal: true

FactoryGirl.define do
  factory :user do
    username 'test'
    email 'test@test.com'
    disabled false
    default_tz 'America/New_York'
  end
end
