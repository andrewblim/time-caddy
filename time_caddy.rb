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

  def redis_client
    settings.redis_client
  end

  def redlock_client
    settings.redlock_client
  end

  before do
    if session[:username].nil?
      @user = nil
    elsif !@user || @user.username != session[:username]
      @user = User.find_by(username: session[:username])
    end
  end

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
      flash.now[:warnings] = "You are already logged in as #{session[:username]}. If you log in "\
                             'successfully below, you will be logged out as the previous user.'
    end
    haml :signup
  end

  post '/signup' do
    signup_errors = []
    if params[:username].blank?
      signup_errors << 'You must specify a username.'
    elsif params[:username].length > 40
      signup_errors << 'Your username cannot be longer than 40 characters.'
    elsif params[:username] !~ /^[-_0-9A-Za-z]+$/
      signup_errors << 'Your username must consist solely of alphanumeric characters, underscores, or hyphens.'
    end

    if params[:email].blank?
      signup_errors << 'You must specify an email address.'
    elsif params[:email].length > 60
      signup_errors << 'Your email address cannot be longer than 60 characters.'
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

    # if a created but inactivated user is found with the same username or
    # email, but the user is old, destroy them and carry on

    if (user = User.find_by(username: params[:username]))
      if user.active?
        signup_errors << "There is already a user with username #{params[:username]}."
      elsif user.inactive_but_fresh?
        signup_errors << "There is already a not-yet-activated user with username #{params[:username]} created less "\
                         "than #{User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS} days ago. If you need the activation email "\
                         "to be resent, <a href='/signup_confirmation/#{user.username}'>click here</a>."
      else
        user.destroy
      end
    elsif (user = User.find_by(email: params[:email]))
      if user.active?
        signup_errors << "There is already a user with email #{params[:email]}."
      elsif user.inactive_but_fresh?
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
    end

    password_salt = BCrypt::Engine.generate_salt
    password_hash = BCrypt::Engine.hash_secret(params[:password], password_salt)
    user = User.create(
      username: params[:username],
      email: params[:email],
      password_hash: password_hash,
      password_salt: password_salt,
      signup_time: Time.now.utc,
      activation_time: nil,
      default_tz: params[:default_tz],
    )
    redirect "/signup_confirmation/#{user.username}"
  end

  get '/signup_confirmation/:username' do |username|
    @activation_user = User.find_by(username: username)
    if @activation_user.nil?
      flash[:errors] = 'It looks like you hit the signup confirmation page for a user that has '\
                       'not been created! Please try signing up again.'
      redirect '/signup'
    elsif @activation_user.active?
      flash[:alerts] = "User #{@activation_user.username} has already been activated and can log "\
                       'in and use the app.'
      redirect '/login'
    elsif !@activation_user.inactive_but_fresh?
      # only destroy on signup attempt, leave this as a GET
      flash[:errors] = "Your signup was more than #{INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS} ago, at "\
                       'which point we consider it inactive. Please try signing up again.'
      redirect '/signup'
    else
      lock_info = redlock_client.lock("activation_token_email:#{@activation_user.username}", 60_000)
      if lock_info
        @activation_token = SecureRandom.hex(16)
        redis_client.set(
          "activation_token:#{@activation_user.username}",
          @activation_token,
          px: 15 * 60_000,
        )
        if settings.email_enabled
          Pony.mail(
            to: @activation_user.email,
            subject: "Confirmation of new time-caddy account for username #{@activation_user.username}",
            body: erb(:activation_email),
            via: :smtp,
            via_options: {
              address: settings.smtp['host'],
              port: settings.smtp['port'],
              user_name: settings.smtp['username'],
              password: settings.smtp['password'],
              authentication: settings.smtp['authentication'].to_sym,
              domain: settings.smtp['domain'],
            },
          )
        end
      end
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
      flash.now[:warnings] = "You are already logged in as #{session[:username]}. If you log in "\
                             'successfully below, you will be logged out as the previous user.'
    end
    haml :login
  end

  post '/login' do
    user = User.find_by_username_or_email(params[:username_or_email])
    if !user
      flash[:errors] = "Unknown username or email address #{params[:username_or_email]}"
      redirect '/login'
    elsif user.password_hash != BCrypt::Engine.hash_secret(params[:password], user.password_salt)
      flash[:errors] = 'Wrong username/password combination'
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
      flash.now[:warnings] = "You are already logged in as #{session[:username]}. This page is "\
                             "meant for users who have forgotten their passwords and can't log "\
                             'in. If you can log in and just want to change your password, go to '\
                             'the <a href="/settings/">settings</a> page.'
    end
    haml :password_reset_request
  end

  post '/password_reset_request' do
    @password_reset_user = User.find_by_username_or_email(params[:username_or_email])
    if !@password_reset_user
      flash[:errors] = "Unknown username or email address #{params[:username_or_email]}"
      redirect '/password_reset_request'
    elsif @password_reset_user.n_recent_password_reset_requests > MAX_RECENT_PASSWORD_RESET_REQUESTS
      flash[:errors] = 'There have been too many recent password reset requests for '\
                       "#{params[:username_or_email]} in the last 24 hours. If you need your "\
                       "password reset sooner than that, please contact #{settings.support_email}."
      redirect '/password_reset_request'
    else
      loop do
        @password_reset_token = SecureRandom.hex(16)
        password_reset_token_salt = BCrypt::Engine.generate_salt
        password_reset_token_hash = BCrypt::Engine.hash_secret(@password_reset_token, password_reset_token_salt)
        # ensure that this is the only unused token/salt combo
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

      if settings.email_enabled
        Pony.mail(
          to: @password_reset_user.email,
          subject: "Password reset request for time-caddy username #{@password_reset_user.username}",
          body: erb(:password_reset_request_email),
          via: :smtp,
          via_options: {
            address: settings.smtp['host'],
            port: settings.smtp['port'],
            user_name: settings.smtp['username'],
            password: settings.smtp['password'],
            authentication: settings.smtp['authentication'].to_sym,
            domain: settings.smtp['domain'],
          },
        )
      end
      redirect '/password_reset_confirmation'
    end
  end

  get '/password_reset_confirmation' do
    haml :password_reset_confirmation
  end

  post '/password_reset_confirmation' do
    # todo
  end
end
