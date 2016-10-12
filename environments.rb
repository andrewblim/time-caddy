# frozen_string_literal: true

require 'sinatra'
require 'sinatra/activerecord'
require 'sinatra/config_file'

configure :development do
  config_file 'config/app.yml'
end

configure :test do
end

configure :production do
end
