# frozen_string_literal: true
module Routes
  module Basic
    def self.registered(app)
      app.instance_eval do
        get '/' do
          haml :index
        end

        get '/about' do
          haml :about
        end
      end
    end
  end
end
