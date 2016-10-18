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
      signup_url_token = SecureRandom.hex(16)

      redis_client.multi do
        redis_client.set(
          "signup_confirmation_email:#{username}",
          true,
          ex: User::SIGNUP_CONFIRMATION_EMAIL_COOLDOWN_IN_SEC,
        )
        redis_client.set(
          "signup_confirmation_url_token:#{signup_url_token}",
          username,
          ex: User::SIGNUP_CONFIRMATION_LIFESPAN_IN_SEC,
        )
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
    if session[:username]
      flash.now[:warnings] = "You are already logged in as #{session[:username]}, though you can still create a new "\
        'account for some other username/email address if you want.'
    end
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
      redirect '/signup'
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
      redirect '/signup'
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
      activation_time: nil,
      disabled: false,
      default_tz: params[:default_tz],
    )
    tokens = create_signup_confirmation_tokens(username: @new_user.username)
    @signup_confirmation_token = tokens[:confirm_token]
    @signup_confirmation_url_token = tokens[:url_token]
    mail(
      to: @new_user.email,
      subject: "Confirmation of new time-caddy account for username #{@new_user.username}",
      body: erb(:signup_confirmation_email),
    )
    redirect "/signup_confirmation?token=#{@signup_confirmation_url_token}"
  end

  get '/signup_confirmation' do
    @signup_confirmation_url_token = params[:token]
    if @signup_confirmation_url_token.nil?
      flash[:errors] = 'You attempted to view the signup confirmation page with no token. If you just created a new '\
        'account, please follow the instructions in the signup confirmation email you received. If you need a new '\
        'confirmation email sent to you, fill out the form below.'
      redirect '/resend_signup_confirmation'
    elsif redis_client.get("signup_confirmation_url_token:#{@signup_confirmation_url_token}").nil?
      flash[:errors] = 'Your signup confirmation request has expired (they expire after a while for security '\
        'reasons). Please request a new one below.'
      redirect '/resend_signup_confirmation'
    else
      haml :signup_confirmation
    end
  end

  post '/signup_confirmation' do
    signup_confirmation_url_token = params[:token]
    unless signup_confirmation_url_token
      flash[:errors] = 'You attempted to view the signup confirmation with no token. If you just created a new '\
        'account, please follow the instructions in the signup confirmation email you received. If you need a new '\
        'confirmation email, fill out the form below.'
      redirect '/resend_signup_confirmation'
      return
    end
    username = redis_client.get("signup_confirmation_url_token:#{signup_confirmation_url_token}")
    unless username
      clear_signup_confirmation_tokens(url_token: signup_confirmation_url_token)
      flash[:errors] = 'Your signup confirmation request has expired (they expire after a while for security '\
        'reasons). Please request a new one below.'
      redirect '/resend_signup_confirmation'
      return
    end

    @new_user = User.find_by(username: username)
    check_time = Time.now
    if @new_user && @new_user.unconfirmed_stale?(check_time)
      # This shouldn't happen unless someone has manually edited something so
      # that confirmation URL token is valid for longer than it takes @new_user
      # to go stale.
      @new_user.destroy
      @new_user = nil
    end
    if @new_user.nil?
      # This shouldn't happen unless the above case occurs or someone has
      # manually removed the user from the database.
      flash[:errors] = 'For some reason, the user you were creating was not successfully saved into our databases at '\
        "signup. Please try signing up again. If this happens again, please contact #{settings.support_email}."
      redirect '/signup'
      return
    elsif @new_user.confirmed?(check_time)
      flash[:alerts] = 'Your account has already been confirmed! You can log in.'
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

    if token_hash != BCrypt::Engine.hash_secret(params[:signup_confirmation_token], token_salt)
      flash[:errors] = 'Incorrect confirmation code.'
      redirect "/signup_confirmation?token=#{signup_confirmation_url_token}"
    else
      user.activate
      clear_signup_confirmation_tokens(url_token: signup_confirmation_url_token)
      flash[:alerts] = 'Your account has been confirmed successfully!'
      redirect '/login'
    end
  end

  get '/resend_signup_confirmation' do
    haml :resend_signup_confirmation
  end

  post '/resend_signup_confirmation' do
    @new_user = User.find_by(email: params[:email])
    check_time = Time.now
    if @new_user && @new_user.unconfirmed_stale?(check_time)
      @new_user.destroy
      @new_user = nil
    end
    if @new_user.nil?
      flash[:errors] = "The user with email with #{params[:email]} was not found. If you signed up more than "\
        "#{User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS} days ago, your signup may have been deleted; for maintenance and "\
        'security we delete users that appear to be orphaned while awaiting confirmation. Please try signing up again.'
      redirect '/signup'
      return
    elsif @new_user.confirmed?(check_time)
      flash[:alerts] = 'Your account has already been confirmed! You can log in.'
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
      redirect "/signup_confirmation?token=#{@signup_confirmation_url_token}"
    end
  end

  get '/login' do
    if session[:username]
      flash.now[:warnings] = "You are already logged in as #{session[:username]}. If you log in successfully below, "\
                             "we will log you out as #{session[:username]} first."
    end
    haml :login
  end

  post '/login' do
    user = User.find_by_username_or_email(params[:username_or_email])
    if !user
      flash[:errors] = "No username or email address was found matching #{params[:username_or_email]}."
      redirect '/login'
    elsif !user.active?
      # todo
    elsif user.password_hash != BCrypt::Engine.hash_secret(params[:password], user.password_salt)
      flash[:errors] = 'Wrong username/password combination.'
      redirect '/login'
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

  get '/password_reset_request' do
    if session[:username]
      flash.now[:warnings] = "You are already logged in as #{session[:username]}. This page is meant for users who "\
                             "have forgotten their passwords and can't log in. If you can log in and just want to "\
                             'change your password, go to the <a href="/settings">settings</a> page.'
    end
    haml :password_reset_request
  end

  post '/password_reset_request' do
    @password_reset_user = User.find_by_username_or_email(params[:username_or_email])
    if !@password_reset_user
      flash[:errors] = "Unknown username or email address #{params[:username_or_email]}"
      redirect '/password_reset_request'
    elsif @password_reset_user.recent_password_reset_requests_count > MAX_RECENT_PASSWORD_RESET_REQUESTS
      flash[:errors] = "There have been too many password reset requests for #{params[:username_or_email]} in the "\
                       'last 24 hours. If you need your password reset sooner than that, please contact '\
                       "#{settings.support_email}."
      redirect '/password_reset_request'
    else
      # Repeatedly generate token/salt combos until we get a not-already used
      # one that is active, since collisions would be bad.
      loop do
        @password_reset_token = SecureRandom.hex(16)
        password_reset_token_salt = BCrypt::Engine.generate_salt
        password_reset_token_hash = BCrypt::Engine.hash_secret(@password_reset_token, password_reset_token_salt)
        password_reset_request = PasswordResetRequest.transaction do
          existing_request = PasswordResetRequest.where(
            password_reset_token_hash: password_reset_token_hash,
            password_reset_token_salt: password_reset_token_salt,
          ).find(&:active?)
          unless existing_request
            @password_reset_user.create(
              request_time: Time.now,
              password_reset_token_hash: password_reset_token_hash,
              password_reset_token_salt: password_reset_token_salt,
              used: false,
            )
          end
        end
        break if password_reset_request
      end

      mail(
        to: @password_reset_user.email,
        subject: "Password reset request for time-caddy username #{@password_reset_user.username}",
        body: erb(:password_reset_request_email),
      )
      redirect '/password_reset'
    end
  end

  get '/password_reset' do
    haml :password_reset
  end

  post '/password_reset' do
    # todo
  end
end
