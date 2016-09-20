# frozen_string_literal: true

require 'sinatra/base'
require './environments'

class TimeCaddy < Sinatra::Base

  register Sinatra::ActiveRecordExtension

  get '/' do
    'Hello world!!'
  end

end
