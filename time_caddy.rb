# frozen_string_literal: true

require 'bcrypt'
require 'haml'
require 'sinatra/base'
require 'sinatra/flash'
require './environments'

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

  # h/t to https://gist.github.com/amscotti/1384524 for getting me going on the
  # basic framework here

  get '/signup' do
    haml :signup
  end

  post '/signup' do
    if params[:username].blank? || params[:email].blank?
      flash[:signup] = "You must specify a username and an email address"
      redirect '/signup'
    elsif User.find_by(username: params[:username])
      flash[:signup] = "There is already a user with username #{params[:username]}"
      redirect '/signup'
    elsif User.find_by(email: params[:email])
      flash[:signup] = "There is already a user with email #{params[:email]}"
      redirect '/signup'
    else
      password_salt = BCrypt::Engine.generate_salt
      password_hash = BCrypt::Engine.hash_secret(params[:password], password_salt)
      User.create(
        username: params[:username],
        email: params[:email],
        password_hash: password_hash,
        password_salt: password_salt,
      )
      session[:username] = params[:username]
      flash[:login] = "User creation for username #{params[:username]} was successful!"
      redirect '/login'
    end
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
