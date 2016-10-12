# frozen_string_literal: true
class User < ActiveRecord::Base
  has_many :log_entries

  INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS = 7

  def active?
    !signup_time.nil?
  end

  def inactive_but_fresh?(as_of = Time.now)
    signup_time.advance(days: INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS) > as_of
  end
end
