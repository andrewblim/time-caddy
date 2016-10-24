# frozen_string_literal: true
require 'bcrypt'
require 'redis'

module Helpers
  module ConfirmationTokens
    # signup_confirmation: generates a set of Redis-based tokens that get sent
    # out in an email, and also adds a lock-like Redis token to check whether
    # such an email was generated recently

    def create_signup_confirmation_tokens(username:, confirm_token: SecureRandom.hex(16),
                                          confirm_token_salt: BCrypt::Engine.generate_salt,
                                          redis_client: settings.redis_client)
                                          
      confirm_token_hash = BCrypt::Engine.hash_secret(confirm_token, confirm_token_salt)
      url_token = nil

      redis_client.multi do
        redis_client.set(
          "signup_confirmation_email:#{username}",
          true,
          ex: User::SIGNUP_CONFIRMATION_EMAIL_COOLDOWN_IN_SEC,
        )
        loop do
          # collisions not permissible
          url_token = SecureRandom.hex(16)
          set_status = redis_client.setnx(
            "signup_confirmation_url_token:#{url_token}",
            username,
          )
          expire_status = redis_client.expire(
            "signup_confirmation_url_token:#{url_token}",
            User::SIGNUP_CONFIRMATION_LIFESPAN_IN_SEC,
          )
          break if set_status && expire_status
        end
        redis_client.set(
          "signup_confirmation_token_hash:#{username}",
          confirm_token_hash,
          ex: User::SIGNUP_CONFIRMATION_LIFESPAN_IN_SEC,
        )
        redis_client.set(
          "signup_confirmation_token_salt:#{username}",
          confirm_token_salt,
          ex: User::SIGNUP_CONFIRMATION_LIFESPAN_IN_SEC,
        )
      end

      { confirm_token: confirm_token, url_token: signup_url_token }
    end

    def recent_signup_confirmation_email(username:, redis_client: settings.redis_client)
      redis_client.get("signup_confirmation_email:#{username}")
    end

    def get_username_from_signup_confirmation(url_token:, redis_client: settings.redis_client)
      redis_client.get("signup_confirmation_url_token:#{url_token}")
    end

    def check_signup_confirmation_confirm_token(username:, confirm_token:, redis_client: settings.redis_client)
      token_hash, token_salt = redis_client.mget(
        "signup_confirmation_token_hash:#{username}",
        "signup_confirmation_token_salt:#{username}",
      )
      return nil unless token_hash && token_salt
      token_hash == BCrypt::Engine.hash_secret(confirm_token, token_salt)
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
