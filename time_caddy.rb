# frozen_string_literal: true

require 'sinatra/base'

class TimeCaddy < Sinatra::Base
  get '/' do
    'Hello world!!'
  end
end
