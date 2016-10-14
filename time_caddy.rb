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
    @user = User.find_by(username: session[:username]) if session[:username]
  end

  def logged_in_user
    @user
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
      flash[:signup_errors] = signup_errors
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

  get '/signup_confirmation/:username' do
    signup_errors = []
    login_alerts = []
    @activation_user = User.find_by(username: params[:username])
    if @activation_user.nil?
      signup_errors << 'It looks like you hit the signup confirmation page for a user that has not been created! '\
                       'Please try signing up again.'
    elsif @activation_user.active?
      login_alerts << "User #{@activation_user.username} has already been activated and can log in and use the app."
    elsif !@activation_user.inactive_but_fresh?
      # only destroy on signup attempt, leave this as a GET
      signup_errors << "Your signup was more than #{INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS} ago, at which point we "\
                       "deactivate it. Please try signing up again."
    end

    if !signup_errors.blank?
      flash[:signup_errors] = signup_errors
      redirect '/signup'
    elsif !login_alerts.blank?
      flash[:login_alerts] = login_alerts
      redirect '/login'
    else
      lock_info = redlock_client.lock("activation_code_email:#{@activation_user.username}", 60_000)
      if lock_info
        @activation_token = SecureRandom.hex(16)
        redis_client.set(
          "activation_code:#{@activation_user.username}",
          @activation_token,
          px: 15 * 60_000,
        )
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
          }
        )
      end
      # if you can't get the lock, just silently present the next page - the
      # lock is to prevent people from refreshing the page repeatedly and
      # generating a ton of emails
      haml :signup_confirmation
    end
  end

  post '/signup_confirmation' do
    token = redis_client.get("activation_code:#{params[:username]}")
    signup_confirmation_errors = []
    if token.nil?
      signup_confirmation_errors << 'Your confirmation code has expired. We have sent a new one.'
    elsif token != params[:activation_code]
      signup_confirmation_errors << 'Incorrect confirmation code.'
    end
    unless signup_confirmation_errors.blank?
      flash[:signup_confirmation_errors] = signup_confirmation_errors
      redirect "/signup_confirmation/#{params[:username]}"
    end
    flash[:login_alerts] = ['Your account has been activated successfully!']
    redirect '/login'
  end

  get '/login' do
    if logged_in_user
      redirect '/'
    else
      haml :login
    end
  end

  post '/login' do
    user = User.find_by(username: params[:username])
    if !user
      flash[:login] = "Unknown user #{params[:username]}"
      redirect '/login'
    elsif user.password_hash != BCrypt::Engine.hash_secret(params[:password], user.password_salt)
      flash[:login] = 'Wrong password'
      redirect '/login'
    else
      session[:username] = params[:username]
      redirect '/'
    end
  end

  post '/logout' do
    session[:username] = nil
    redirect '/'
  end
end
