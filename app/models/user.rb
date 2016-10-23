# frozen_string_literal: true
require 'bcrypt'
require 'email_validator'

class User < ActiveRecord::Base
  SIGNUP_CONFIRMATION_EMAIL_COOLDOWN_IN_SEC = 5 * 60
  SIGNUP_CONFIRMATION_LIFESPAN_IN_SEC = 60 * 60
  INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS = 7

  has_many :password_reset_requests
  has_many :log_entries

  validates :username, uniqueness: true, length: { minimum: 1, maximum: 40 }
  validates :email, uniqueness: true, email: true, length: { minimum: 1, maximum: 60 }
  validate :default_tz_is_valid

  def self.find_by_username_or_email(username_or_email)
    if EmailValidator.valid?(username_or_email)
      find_by(email: username_or_email)
    else
      find_by(username: username_or_email)
    end
  end

  def self.create_with_salted_password(**kwargs)
    return false unless kwargs[:password].is_a?(String)
    kwargs[:password_salt] ||= BCrypt::Engine.generate_salt
    kwargs[:password_hash] = BCrypt::Engine.hash_secret(kwargs[:password], kwargs[:password_salt])
    create(**kwargs.except(:password))
  end

  def reset_password(password:, salt: BCrypt::Engine.generate_salt)
    password_salt = salt
    password_hash = BCrypt::Engine.hash_secret(password, salt)
    save
  end

  def check_password(password)
    password_hash == BCrypt::Engine.hash_secret(password, password_salt)
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

  private

  def default_tz_is_valid
    begin
      TZInfo::Timezone.get(default_tz)
    rescue TZInfo::InvalidTimezoneIdentifier
      errors.add(:default_tz, "Time zone #{default_tz} not recognized as a valid time zone")
    end
  end
end
