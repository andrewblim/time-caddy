# frozen_string_literal: true
class User < ActiveRecord::Base
  INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS = 7

  has_many :password_reset_requests
  has_many :log_entries

  def self.find_by_username_or_email(username_or_email)
    if EmailValidator.valid?(username_or_email)
      find_by(email: username_or_email)
    else
      find_by(username: username_or_email)
    end
  end

  def self.find_by_username_or_email!(username_or_email)
    if EmailValidator.valid?(username_or_email)
      find_by!(email: username_or_email)
    else
      find_by!(username: username_or_email)
    end
  end

  def active?
    !activation_time.nil?
  end

  def inactive_but_fresh?(as_of = Time.now)
    !active? && signup_time.advance(days: INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS) > as_of
  end

  def activate
    return false if active?
    update(activation_time: Time.now)
  end

  def activate!
    raise 'User already activated' unless activate
    update!(activation_time: Time.now)
  end

  def n_recent_password_reset_requests(window: Time.now.advance(hours: -24)..Time.now)
    password_reset_requests.where(request_time: window).count
  end
end
