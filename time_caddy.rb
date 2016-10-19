# frozen_string_literal: true

require 'sinatra'
require 'sinatra/activerecord'
require 'sinatra/base'
require 'sinatra/config_file'
require 'sinatra/flash'
require 'haml'

require 'bcrypt'
require 'email_validator'
require 'pony'
require 'redis'

require 'require_all'
require_all 'app/models/**/*.rb'

class TimeCaddy < Sinatra::Base
  MAX_RECENT_PASSWORD_RESET_REQUESTS = 5

  register Sinatra::ActiveRecordExtension
  register Sinatra::ConfigFile
  register Sinatra::Flash

  enable :sessions

  set :haml, format: :html5
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

  ### routes

  get '/' do
    haml :index
  end

  get '/about' do
    haml :about
  end

  # h/t to https://gist.github.com/amscotti/1384524 for getting me going on the
  # basic framework here

  get '/signup' do
    haml :signup
  end

  post '/signup' do
    # verify that the form was filled out reasonably
    signup_errors = []
    if !params[:username].length.between?(1, 40)
      signup_errors << 'Your username must be 1-40 characters long.'
    elsif params[:username] !~ /^[-_0-9A-Za-z]+$/
      signup_errors << 'Your username must consist solely of alphanumeric characters, underscores, or hyphens.'
    end
    if !params[:email].length.between?(1, 60)
      signup_errors << 'Your email address must be 1-60 characters long.'
    elsif !EmailValidator.valid?(params[:email])
      signup_errors << 'Your email address was not recognized as a valid address.'
    end
    if params[:password].length < 6
      signup_errors << 'Your password must be at least 6 characters long.'
    end

    # this shouldn't happen if the tz form is working properly, but just in case
    begin
      TZInfo::Timezone.get(params[:default_tz])
    rescue TZInfo::InvalidTimezoneIdentifier
      signup_errors << "The timezone #{params[:default_tz]} was not recognized as a valid tz timezone."
    end

    # don't even bother hitting the database if we have errors at this point
    unless signup_errors.blank?
      flash[:errors] = signup_errors
      redirect back
      return
    end

    # If the user already exists and is not stale, redirect back with a helpful
    # flash error. If the user exists but is stale, destroy it.
    check_time = Time.now
    if (user = User.find_by(username: params[:username]))
      if user.confirmed?(check_time)
        signup_errors << "There is already a user with username #{params[:username]}."
      elsif user.unconfirmed_fresh?(check_time)
        signup_errors << "There is already a not-yet-confirmed user #{params[:username]} who signed up less than "\
          "#{User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS} days ago. If this is you and you need the confirmation email to "\
          "be resent, <a href='/resend_signup_confirmation'>click here</a>."
      else
        user.destroy
      end
    elsif (user = User.find_by(email: params[:email]))
      if user.confirmed?(check_time)
        signup_errors << "There is already a user with email #{params[:email]}."
      elsif user.unconfirmed_fresh?(check_time)
        signup_errors << "There is already a not-yet-activated user with email #{params[:email]} created less than "\
          "than #{User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS} days ago. If you need the activation email "\
          "to be resent, <a href='/signup_confirmation/#{user.username}'>click here</a>."
      else
        user.destroy
      end
    end
    unless signup_errors.blank?
      flash[:errors] = signup_errors
      redirect back
      return
    end

    # Create user, generate tokens, send email
    password_salt = BCrypt::Engine.generate_salt
    password_hash = BCrypt::Engine.hash_secret(params[:password], password_salt)
    @new_user = User.create(
      username: params[:username],
      email: params[:email],
      password_hash: password_hash,
      password_salt: password_salt,
      signup_time: Time.now.utc,
      signup_confirmation_time: nil,
      disabled: false,
      default_tz: params[:default_tz],
    )
    unless @new_user
      flash[:errors] = "Technical issue saving the new user to the database, please contact #{settings.support_email}."
      redirect back
      return
    end
    tokens = create_signup_confirmation_tokens(username: @new_user.username)
    @signup_confirmation_token = tokens[:confirm_token]
    @signup_confirmation_url_token = tokens[:url_token]
    mail(
      to: @new_user.email,
      subject: "Confirmation of new time-caddy account for username #{@new_user.username}",
      body: erb(:signup_confirmation_email),
    )
    redirect "/signup_confirmation?url_token=#{@signup_confirmation_url_token}"
  end

  get '/signup_confirmation' do
    @signup_confirmation_url_token = params[:url_token] || ''
    haml :signup_confirmation
  end

  post '/signup_confirmation' do
    signup_confirmation_url_token = params[:url_token]
    unless signup_confirmation_url_token
      flash[:errors] = 'Invalid signup confirmation token'
      redirect '/resend_signup_confirmation'
      return
    end
    username = redis_client.get("signup_confirmation_url_token:#{signup_confirmation_url_token}")
    unless username
      clear_signup_confirmation_tokens(url_token: signup_confirmation_url_token)
      flash[:errors] = 'Your signup confirmation request has expired (they expire after a while for security '\
        'reasons). Please request a new one.'
      redirect '/resend_signup_confirmation'
      return
    end

    check_time = Time.now
    @new_user = User.find_by(username: username)&.destroy_and_disregard_unconfirmed_stale(check_time)
    if @new_user.nil?
      flash[:errors] = 'For some reason, the user you were creating was not successfully saved into our databases at '\
        "signup. Please try signing up again. If this happens again, please contact #{settings.support_email}."
      redirect '/signup'
      return
    elsif @new_user.disabled
      flash[:errors] = 'Your account has been disabled.'
      redirect back
      return
    elsif @new_user.confirmed?(check_time)
      flash[:alerts] = 'Your account has already been confirmed!'
      redirect '/login'
      return
    end

    token_hash, token_salt = redis_client.mget(
      redis_client.get("signup_confirmation_token_hash:#{username}"),
      redis_client.get("signup_confirmation_token_salt:#{username}"),
    )
    unless token_hash && token_salt
      # real corner case, in case they expired between username retrieval and
      # token hash/salt retrieval
      clear_signup_confirmation_tokens(url_token: signup_confirmation_url_token)
      flash[:errors] = 'Your signup confirmation request has expired (they expire after a while for security '\
        'reasons). Please request a new one below.'
      redirect '/resend_signup_confirmation'
      return
    end

    if token_hash != BCrypt::Engine.hash_secret(params[:confirm_token], token_salt)
      flash[:errors] = 'Incorrect confirmation code.'
      redirect back
    elsif user.confirm_signup
      clear_signup_confirmation_tokens(url_token: signup_confirmation_url_token)
      flash[:alerts] = 'Your account has been confirmed successfully!'
      redirect '/login'
    else
      flash[:errors] = 'Sorry, we ran into a technical error saving your account confirmation! Please try again, and '\
        "if it happens again, contact #{settings.support_email}."
      redirect back
    end
  end

  get '/resend_signup_confirmation' do
    haml :resend_signup_confirmation
  end

  post '/resend_signup_confirmation' do
    check_time = Time.now
    @new_user = User.find_by(email: params[:email])&.destroy_and_disregard_unconfirmed_stale(check_time)
    if @new_user.nil?
      flash[:errors] = "The user with email with #{params[:email]} was not found. If you signed up more than "\
        "#{User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS} days ago, your signup may have been deleted; for maintenance and "\
        'security we delete users that appear to be orphaned while awaiting confirmation. Please try signing up again.'
      redirect '/signup'
    elsif @new_user.disabled
      flash[:errors] = 'Your account has been disabled.'
      redirect back
    elsif @new_user.confirmed?(check_time)
      flash[:alerts] = 'Your account has already been confirmed!'
      redirect '/login'
    elsif redis_client.get("signup_confirmation_email:#{@new_user.username}")
      flash[:alerts] = 'A confirmation email has already been sent within the last '\
        "#{User::SIGNUP_CONFIRMATION_EMAIL_COOLDOWN_IN_SEC / 60} minutes. Please check your email, double-check your "\
        "spam filters and other email folders, and request again if it doesn't show up. If you continue not to "\
        "receive the confirmation email, contact #{settings.support_email}."
      redirect '/login'
    else
      tokens = create_signup_confirmation_tokens(username: @new_user.username)
      @signup_confirmation_token = tokens[:confirm_token]
      @signup_confirmation_url_token = tokens[:url_token]
      mail(
        to: @new_user.email,
        subject: "Confirmation of new time-caddy account for username #{@new_user.username}",
        body: erb(:signup_confirmation_email),
      )
      redirect "/signup_confirmation?url_token=#{@signup_confirmation_url_token}"
    end
  end

  get '/password_reset_request' do
    haml :password_reset_request
  end

  post '/password_reset_request' do
    check_time = Time.now
    @password_reset_user = User.find_by(email: params[:email])&.destroy_and_disregard_unconfirmed_stale(check_time)
    if @password_reset_user.nil?
      flash[:errors] = "No user with email #{params[:email]} was found. If you signed up more than "\
        "#{User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS} days ago, your signup may have been deleted; for maintenance and "\
        'security we delete users that appear to be orphaned while awaiting confirmation. Please try signing up again.'
      redirect '/signup'
    elsif @password_reset_user.disabled
      flash[:errors] = 'Your account has been disabled.'
      redirect back
    elsif @password_reset_user.unconfirmed_fresh?
      flash[:errors] = "Your account is created but still not activated, which is why you can't log in. Please follow "\
        "the instructions in the email that was sent to you. If it's been a while and you haven't received the email, "\
        '<a href="/resend_signup_confirmation">click here</a>.'
      redirect back
    elsif @password_reset_user.recent_password_reset_requests_count > MAX_RECENT_PASSWORD_RESET_REQUESTS
      flash[:errors] = "There have been too many recent password reset requests for #{params[:email]}. "\
        "You can either wait a while, or contact #{settings.support_email} for help."
      redirect back
    else
      @password_reset_token = SecureRandom.hex(16)
      password_reset_token_salt = BCrypt::Engine.generate_salt
      password_reset_token_hash = BCrypt::Engine.hash_secret(@password_reset_token, password_reset_token_salt)

      reset_request = PasswordResetRequest.transaction do
        loop do
          @password_reset_url_token = SecureRandom.hex(16)
          break unless PasswordResetRequest.find_by(password_reset_url_token: @password_reset_url_token)
        end
        @password_reset_user.password_reset_requests.update_all(active: false)
        @password_reset_user.password_reset_requests.create(
          request_time: Time.now,
          password_reset_token_hash: password_reset_token_hash,
          password_reset_token_salt: password_reset_token_salt,
          password_reset_url_token: @password_reset_url_token,
          active: true,
        )
      end

      if reset_request.nil?
        mail(
          to: @password_reset_user.email,
          subject: "Password reset request for time-caddy username #{@password_reset_user.username}",
          body: erb(:password_reset_request_email),
        )
        # no redirect, just tell them to check email and follow link
        haml :password_reset_request_complete
      else
        flash[:errors] = "Technical issue creating a password reset request, please contact #{settings.support_email}."
        redirect back
      end
    end
  end

  get '/password_reset' do
    @password_reset_url_token = params[:url_token] || ''
    haml :password_reset
  end

  post '/password_reset' do
    @password_reset_url_token = params[:url_token]
    if @password_reset_url_token.nil?
      flash[:errors] = 'Invalid password reset token, please re-request a password reset if you need one.'
      redirect '/password_reset_request'
      return
    end

    reset_request = PasswordResetRequest.find(password_reset_url_token: @password_reset_url_token, active: true)
    if reset_request.nil? || !reset_request.usable?
      reset_request.update(active: false) if reset_request
      flash[:errors] = 'Invalid password reset token, please re-request a password reset if you need one.'
      redirect '/password_reset_request'
      return
    end

    user = reset_request.user
    if user.disabled
      reset_request.update(active: false)
      flash[:errors] = 'The user associated with this password reset request has been disabled.'
      redirect '/login'
      return
    end

    submitted_token_hash = BCrypt::Engine.hash_secret(params[:confirm_token], reset_request.password_reset_token_salt)
    if reset_request.password_reset_token_hash != submitted_token_hash
      reset_request.update(active: false)
      flash[:errors] = 'Invalid password reset confirmation code.'
      redirect back
    end

    password_salt = BCrypt::Engine.generate_salt
    password_hash = BCrypt::Engine.hash_secret(params[:new_password], password_salt)
    if user.update(password_hash: password_hash, password_salt: password_salt)
      reset_request.update(active: false)
      flash[:alerts] = 'Your password has been successfully reset.'
      redirect '/login'
    else
      flash[:errors] = "Technical issue resetting password, please contact #{settings.support_email}."
      redirect back
    end
  end

  get '/login' do
    haml :login
  end

  post '/login' do
    user = User.find_by_username_or_email(params[:username_or_email])
    if user.nil?
      flash[:errors] = "No username or email address was found matching #{params[:username_or_email]}."
      redirect '/login'
    elsif user.disabled
      flash[:errors] = 'Your account has been disabled.'
      redirect back
    elsif user.password_hash != BCrypt::Engine.hash_secret(params[:password], user.password_salt)
      flash[:errors] = 'Wrong username/password combination'
      redirect back
    else
      session[:username] = user.username
      redirect '/'
    end
  end

  post '/logout' do
    session[:username] = nil
    flash.discard # just making sure nothing makes its way out of here
    redirect '/'
  end
end
