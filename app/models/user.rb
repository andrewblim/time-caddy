# frozen_string_literal: true
class User < ActiveRecord::Base
  has_many :log_entries

  INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS = 7

  def active?
    !activation_time.nil?
  end

  def inactive_but_fresh?(as_of = Time.now)
    !active? && signup_time.advance(days: INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS) > as_of
  end
end
