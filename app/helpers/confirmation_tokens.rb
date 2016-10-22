# frozen_string_literal: true
require 'bcrypt'
require 'redis'

module Helpers
  module ConfirmationTokens
    def create_signup_confirmation_tokens(username:, redis_client: settings.redis_client)
      signup_token = SecureRandom.hex(16)
      signup_token_salt = BCrypt::Engine.generate_salt
      signup_token_hash = BCrypt::Engine.hash_secret(signup_token, signup_token_salt)
      signup_url_token = nil

      redis_client.multi do
        redis_client.set(
          "signup_confirmation_email:#{username}",
          true,
          ex: User::SIGNUP_CONFIRMATION_EMAIL_COOLDOWN_IN_SEC,
        )
        loop do
          # collisions not permissible
          signup_url_token = SecureRandom.hex(16)
          set_status = redis_client.setnx(
            "signup_confirmation_url_token:#{signup_url_token}",
            username,
          )
          expire_status = redis_client.expire(
            "signup_confirmation_url_token:#{signup_url_token}",
            User::SIGNUP_CONFIRMATION_LIFESPAN_IN_SEC,
          )
          break if set_status && expire_status
        end
        redis_client.set(
          "signup_confirmation_token_hash:#{username}",
          signup_token_hash,
          ex: User::SIGNUP_CONFIRMATION_LIFESPAN_IN_SEC,
        )
        redis_client.set(
          "signup_confirmation_token_salt:#{username}",
          signup_token_salt,
          ex: User::SIGNUP_CONFIRMATION_LIFESPAN_IN_SEC,
        )
      end

      { confirm_token: signup_token, url_token: signup_url_token }
    end

    def clear_signup_confirmation_tokens(url_token:, redis_client: settings.redis_client)
      username = redis_client.get("signup_confirmation_url_token:#{url_token}")
      redis_client.del("signup_confirmation_url_token:#{url_token}")
      return unless username
      redis_client.del("signup_confirmation_email:#{username}")
      redis_client.del("signup_confirmation_token_hash:#{username}")
      redis_client.del("signup_confirmation_token_salt:#{username}")
    end
  end
end
