# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/flash'
require 'haml'
require './environments'

require 'bcrypt'
require 'email_validator'

require 'require_all'
require_all 'app/models/**/*.rb'

class TimeCaddy < Sinatra::Base
  register Sinatra::ActiveRecordExtension
  register Sinatra::Flash
  enable :sessions

  set :haml, format: :html5
  set :public_folder, 'public'

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
    if params[:username].blank? || params[:email].blank?
      signup_errors << 'You must specify a username and an email address.'
    elsif params[:username].length > 40
      signup_errors << 'Your username cannot be longer than 40 characters.'
    elsif params[:username] !~ /^[-_0-9A-Za-z]+$/
      signup_errors << 'Your username must consist solely of alphanumeric characters, underscores, or hyphens.'
    elsif params[:email].length > 60
      signup_errors << 'Your email address cannot be longer than 60 characters.'
    elsif !EmailValidator.valid?(params[:email])
      signup_errors << 'Your email address was not recognized as a valid address.'
    elsif params[:password].length < 6
      signup_errors << 'Your password must be at least 6 characters long.'
    elsif User.find_by(username: params[:username])
      signup_errors << "There is already a user with username #{params[:username]}."
    elsif User.find_by(email: params[:email])
      signup_errors << "There is already a user with email #{params[:email]}."
    end

    unless signup_errors.blank?
      flash[:signup_error] = signup_errors.join("\n")
      redirect '/signup'
    end

    password_salt = BCrypt::Engine.generate_salt
    password_hash = BCrypt::Engine.hash_secret(params[:password], password_salt)
    User.create(
      username: params[:username],
      email: params[:email],
      password_hash: password_hash,
      password_salt: password_salt,
      default_tz: params[:default_tz],
    )
    session[:username] = params[:username]
    flash[:login] = "User creation for username #{params[:username]} was successful!"
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
