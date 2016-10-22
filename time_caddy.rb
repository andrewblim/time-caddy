# frozen_string_literal: true

require 'sinatra'
require 'sinatra/activerecord'
require 'sinatra/base'
require 'sinatra/config_file'
require 'sinatra/flash'

require 'haml'
require 'redis'

require 'require_all'
require_all 'app/helpers/**/*.rb'
require_all 'app/models/**/*.rb'
require_all 'app/routes/**/*.rb'

class TimeCaddy < Sinatra::Base
  MAX_RECENT_PASSWORD_RESET_REQUESTS = 5

  set :root, File.dirname(__FILE__)
  set :haml, format: :html5
  set :views, proc { File.join(root, 'app/views') }

  register Sinatra::ConfigFile
  configure do
    config_file 'config/app.yml'
    set :redis_client, Redis.new(
      host: settings.redis['host'],
      port: settings.redis['port'],
      db: settings.redis['db'],
    )
    enable :sessions
  end

  register Sinatra::ActiveRecordExtension
  register Sinatra::Flash

  helpers Helpers::AppMailer
  helpers Helpers::ConfirmationTokens
  helpers do
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

  register Routes::Basic
  register Routes::Signup
  register Routes::PasswordReset
  register Routes::Login
end
