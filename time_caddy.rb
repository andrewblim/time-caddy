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
require 'redlock'

require 'require_all'
require_all 'app/models/**/*.rb'

class TimeCaddy < Sinatra::Base
  MAX_RECENT_PASSWORD_RESET_REQUESTS = 5
  SIGNUP_CONFIRMATION_EMAIL_COOLDOWN_IN_SEC = 5 * 60
  SIGNUP_CONFIRMATION_LIFESPAN_IN_SEC = 30 * 60

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
    set :redlock_client, Redlock::Client.new([redis_client])
  end

  helpers AppMailer
  helpers do
    def redis_client
      settings.redis_client
    end

    def redlock_client
      settings.redlock_client
    end

    def base_url(request)
      URI::Generic.build(
        scheme: request.scheme,
        host: request.host,
        port: request.port == 80 ? nil : request.port,
        path: '/',
      )
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
                         "#{User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS} days ago. If this is you and you need the "\
                         "confirmation email to be resent, <a href='/resend_signup_confirmation'>click here</a>."
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

    # Create user
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

    # Generate URL token for signup_confirmation and send email with token
    # and confirmation instructions. The redlock prevents too many emails from
    # going out at once.
    lock_info = redlock_client.lock(
      "signup_confirmation_email:#{@activation_user.username}",
      SIGNUP_CONFIRMATION_EMAIL_COOLDOWN_IN_SEC * 1000,
    )
    if lock_info
      @signup_confirmation_token = SecureRandom.hex(16)
      signup_confirmation_token_salt = BCrypt::Engine.generate_salt
      signup_confirmation_token_hash = BCrypt::Engine.hash_secret(@signup_confirmation_token_hash, signup_confirmation_token_salt)
      @signup_confirmation_url_token = SecureRandom.hex(16)

      redis_client.multi do
        redis_client.set(
          "signup_confirmation_url_token:#{signup_confirmation_url_token}",
          @new_user.username,
          ex: SIGNUP_CONFIRMATION_LIFESPAN_IN_SEC,
        )
        redis_client.set(
          "signup_confirmation_token_hash:#{@new_user.username}",
          signup_confirmation_token_hash,
          ex: SIGNUP_CONFIRMATION_LIFESPAN_IN_SEC,
        )
        redis_client.set(
          "signup_confirmation_token_salt:#{@new_user.username}",
          signup_confirmation_token_salt,
          ex: SIGNUP_CONFIRMATION_LIFESPAN_IN_SEC,
        )
      end

      mail(
        to: @new_user.email,
        subject: "Confirmation of new time-caddy account for username #{@new_user.username}",
        body: erb(:signup_confirmation_email),
      )
    end

    redirect "/signup_confirmation?token=#{@signup_confirmation_url_token}"
  end

  get '/resend_signup_confirmation' do
    haml :resend_signup_confirmation
  end

  post '/resend_signup_confirmation' do
  end

  get '/signup_confirmation/:username' do |username|
    @activation_user = User.find_by(username: username)
    if @activation_user.nil?
      flash[:errors] = 'It looks like you hit the signup confirmation page for a user that has not been created! '\
                       'Please try signing up again.'
      redirect '/signup'
    elsif @activation_user.active?
      flash[:alerts] = "User #{@activation_user.username} has already been activated and can log in and use the app."
      redirect '/login'
    elsif !@activation_user.inactive_but_fresh?
      # only destroy the User on next signup attempt so that this can remain a GET
      flash[:errors] = 'Your original signup was too long ago and we have deactivated it. Please try '\
                       '<a href="/signup">signing up</a> again if you would like an account.'
      redirect '/signup'
    else

      # if you can't get the lock, just silently present the next page - the
      # lock is to prevent people from refreshing the page repeatedly and
      # generating a ton of emails
      haml :signup_confirmation
    end
  end

  post '/signup_confirmation' do
    user = User.find_by(username: params[:username])
    unless user
      flash[:errors] = "User #{params[:username]} was not found - try signing up for an account again."
      redirect '/signup'
    end

    token = redis_client.get("activation_token:#{params[:username]}")
    if token.nil?
      flash[:errors] = 'Your confirmation code has expired. We have sent a new one.'
      redirect "/signup_confirmation/#{params[:username]}"
    elsif token != params[:activation_token]
      flash[:errors] = 'Incorrect confirmation code.'
      redirect "/signup_confirmation/#{params[:username]}"
    else
      user.activate
      flash[:alerts] = 'Your account has been activated successfully!'
      redirect '/login'
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
