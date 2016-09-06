# frozen_string_literal: true

require 'sinatra'
require 'sinatra/activerecord'
require './environments'

class TimeCaddy < Sinatra::Base
  get '/' do
    'Hello world!!'
  end
end
