# frozen_string_literal: true
require 'bcrypt'

module Routes
  module Login
    def self.registered(app)
      app.instance_eval do
        get '/login' do
          haml :login
        end

        post '/login' do
          now = Time.now
          User.destroy_unconfirmed_stale_by_username(params[:username], as_of: now)
          User.destroy_unconfirmed_stale_by_email(params[:email], as_of: now)
          if user.nil?
            flash[:errors] = "No username or email address was found matching #{params[:username_or_email]}."
            redirect '/login'
          elsif user.disabled
            flash[:errors] = 'Your account has been disabled.'
            redirect back
          elsif user.unconfirmed_fresh?
            flash[:errors] = 'Your account has been created, but you have not yet confirmed it. Please follow the '\
              'instructions in the email that was sent to you, or <a href="/resend_signup_confirmation">request '\
              'a new confirmation email</a> if needed.'
            redirect back
          elsif !user.check_password(params[:password])
            flash[:errors] = 'Wrong username/password combination'
            redirect back
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
      end
    end
  end
end
