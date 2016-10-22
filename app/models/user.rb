# frozen_string_literal: true
require 'email_validator'

class User < ActiveRecord::Base
  SIGNUP_CONFIRMATION_EMAIL_COOLDOWN_IN_SEC = 5 * 60
  SIGNUP_CONFIRMATION_LIFESPAN_IN_SEC = 60 * 60
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

  # User signup states:
  #
  #   - signed up, not confirmed, but signed up recently (fresh)
  #   - signed up, not confirmed, and signup happened a while ago (stale)
  #   - signup up and confirmed
  #
  # Additionally, the disabled flag may be set to true in any of these states.

  def unconfirmed_fresh?(as_of = Time.now)
    (signup_confirmation_time.nil? || signup_confirmation_time > as_of) &&
      signup_time.advance(days: INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS) > as_of
  end

  def unconfirmed_stale?(as_of = Time.now)
    (signup_confirmation_time.nil? || signup_confirmation_time > as_of) &&
      signup_time.advance(days: INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS) <= as_of
  end

  def confirmed?(as_of = Time.now)
    !signup_confirmation_time.nil? && signup_confirmation_time <= as_of
  end

  def confirm_signup(as_of = Time.now)
    return false if confirmed?(as_of)
    update(signup_confirmation_time: as_of)
  end

  def confirm_signup!(as_of = Time.now)
    raise 'User already confirmed' if confirmed?(as_of)
    update!(signup_confirmation_time: as_of)
  end

  # Convenience, as unconfirmed_stale users are destroyed at first opportunity
  def destroy_and_disregard_unconfirmed_stale(as_of = Time.now)
    return self unless unconfirmed_stale?(as_of)
    destroy
    nil
  end

  # Used to stop too many password reset requests from happening at once
  def recent_password_reset_requests_count(window: Time.now.advance(hours: -24)..Time.now)
    password_reset_requests.where(request_time: window).count
  end

  def disable
    update(disabled: true)
  end

  def enable
    update(disabled: false)
  end
end
