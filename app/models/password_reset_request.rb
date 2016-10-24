# frozen_string_literal: true
require 'bcrypt'

class PasswordResetRequest < ActiveRecord::Base
  PASSWORD_RESET_REQUEST_LIFESPAN_IN_SEC = 6 * 60 * 60

  belongs_to :user

  def self.create_with_tokens_for(user:, confirm_token: SecureRandom.hex(16),
                                  confirm_token_salt: BCrypt::Engine.generate_salt)

    confirm_token_hash = BCrypt::Engine.hash_secret(confirm_token, confirm_token_salt)
    transaction do
      loop do
        url_token = SecureRandom.hex(16)
        break unless find_by(password_reset_url_token: url_token)
      end
      user.password_reset_requests.update_all(active: false)
      user.password_reset_requests.create(
        request_time: Time.now,
        password_reset_token_hash: confirm_token_hash,
        password_reset_token_salt: confirm_token_salt,
        password_reset_url_token: url_token,
        active: true,
      )
    end
  end

  def check_token(token)
    password_reset_token_hash == BCrypt::Engine.hash_secret(token, password_reset_token_salt)
  end

  def usable?(as_of: Time.now)
    active && request_time.advance(seconds: PASSWORD_RESET_REQUEST_LIFESPAN_IN_SEC) > as_of
  end
end
