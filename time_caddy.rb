# frozen_string_literal: true

require 'sinatra'
require 'sinatra/activerecord'
require 'sinatra/base'
require 'sinatra/config_file'
require 'sinatra/flash'

require 'bcrypt'
require 'email_validator'
require 'haml'
require 'pony'
require 'redis'

require 'require_all'
require_all 'app/models/**/*.rb'
require_all 'app/routes/**/*.rb'

class TimeCaddy < Sinatra::Base
  MAX_RECENT_PASSWORD_RESET_REQUESTS = 5

  set :root, File.dirname(__FILE__)
  set :haml, format: :html5
  set :views, proc { File.join(root, 'app/views') }

  register Sinatra::ActiveRecordExtension
  register Sinatra::ConfigFile
  register Sinatra::Flash

  enable :sessions

  configure  do
    config_file 'config/app.yml'
    redis_client = Redis.new(
      host: settings.redis['host'],
      port: settings.redis['port'],
      db: settings.redis['db'],
    )
    set :redis_client, redis_client
  end

  helpers AppMailer
  helpers do
    def redis_client
      settings.redis_client
    end

    def base_url(request)
      URI::Generic.build(
        scheme: request.scheme,
        host: request.host,
        port: request.port == 80 ? nil : request.port,
        path: '/',
      )
    end

    def create_signup_confirmation_tokens(username:)
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

    def clear_signup_confirmation_tokens(url_token:)
      username = redis_client.get("signup_confirmation_url_token:#{url_token}")
      redis_client.del("signup_confirmation_url_token:#{url_token}")
      return unless username
      redis_client.del("signup_confirmation_email:#{username}")
      redis_client.del("signup_confirmation_token_hash:#{username}")
      redis_client.del("signup_confirmation_token_salt:#{username}")
    end
  end

  before do
    if session[:username].nil?
      @user = nil
    elsif !@user || @user.username != session[:username]
      @user = User.find_by(username: session[:username])
    end
  end

  register Routes::Basic
  register Routes::Signup
  register Routes::PasswordReset
  register Routes::Login
end
