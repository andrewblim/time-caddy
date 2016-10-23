# frozen_string_literal: true
require 'bcrypt'
require 'email_validator'

module Routes
  module Signup
    # h/t to https://gist.github.com/amscotti/1384524 for getting me going on the
    # basic framework here

    def self.registered(app)
      app.instance_eval do
        get '/signup' do
          haml :signup
        end

        post '/signup' do
          # verify that the form was filled out reasonably
          signup_errors = []
          if !params[:username].length.between?(1, 40)
            signup_errors << 'Your username must be 1-40 characters long.'
          elsif params[:username] !~ /^[-_0-9A-Za-z]+$/
            signup_errors << 'Your username must consist solely of alphanumeric characters, underscores, or hyphens.'
          end
          if !params[:email].length.between?(1, 60)
            signup_errors << 'Your email address must be 1-60 characters long.'
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

          # don't even bother hitting the database if we have errors at this point
          unless signup_errors.blank?
            flash[:errors] = signup_errors
            redirect back
            return
          end

          # If the user already exists and is not stale, redirect back with a helpful
          # flash error. If the user exists but is stale, destroy it.
          check_time = Time.now
          if (user = User.find_by(username: params[:username])&.destroy_and_disregard_unconfirmed_stale(check_time))
            if user.confirmed?(check_time)
              signup_errors << "There is already a user with username #{params[:username]}."
            elsif user.unconfirmed_fresh?(check_time)
              signup_errors << "There is already a not-yet-confirmed user #{params[:username]} who signed up "\
                'recently. If this is you and you need the confirmation email to be resent, '\
                '<a href="/resend_signup_confirmation">click here</a>.'
            end
          elsif (user = User.find_by(email: params[:email])&.destroy_and_disregard_unconfirmed_stale(check_time))
            if user.confirmed?(check_time)
              signup_errors << "There is already a user with email #{params[:email]}."
            elsif user.unconfirmed_fresh?(check_time)
              signup_errors << "There is already a not-yet-confirmed user #{params[:username]} who signed up "\
                'recently. If this is you and you need the confirmation email to be resent, '\
                '<a href="/resend_signup_confirmation">click here</a>.'
            end
          end
          unless signup_errors.blank?
            flash[:errors] = signup_errors
            redirect back
            return
          end

          # Create user, generate tokens, send email
          @new_user = User.create_with_salted_password(
            username: params[:username],
            email: params[:email],
            password: params[:password],
            signup_time: Time.now.utc,
            signup_confirmation_time: nil,
            disabled: false,
            default_tz: params[:default_tz],
          )
          unless @new_user
            flash[:errors] = 'Technical issue saving the new user to the database, please contact '\
              "#{settings.support_email}."
            redirect back
            return
          end

          tokens = create_signup_confirmation_tokens(username: @new_user.username)
          @signup_confirmation_token = tokens[:confirm_token]
          @signup_confirmation_url_token = tokens[:url_token]
          if @signup_confirmation_token && @signup_confirmation_url_token
            @signup_confirmation_url = build_url(
              request,
              path: '/signup_confirmation',
              query: "url_token=#{@signup_confirmation_url_token}",
            )
            mail(
              to: @new_user.email,
              subject: "time-caddy signup confirmation for username #{@new_user.username}",
              body: erb(:'emails/signup_confirmation_email'),
            )
            haml :signup_confirmation_pending, locals: { resend: false }
          else
            flash[:errors] = "Technical issue creating the new account, please contact #{settings.support_email}."
            redirect back
          end
        end

        get '/signup_confirmation' do
          @signup_confirmation_url_token = params[:url_token] || ''
          haml :signup_confirmation
        end

        post '/signup_confirmation' do
          signup_confirmation_url_token = params[:url_token]
          unless signup_confirmation_url_token
            flash[:errors] = 'Invalid signup confirmation token'
            redirect '/resend_signup_confirmation'
            return
          end
          username = settings.redis_client.get("signup_confirmation_url_token:#{signup_confirmation_url_token}")
          unless username
            clear_signup_confirmation_tokens(url_token: signup_confirmation_url_token)
            flash[:errors] = 'Your signup confirmation request has expired (they expire after a while for security '\
              'reasons). Please request a new one.'
            redirect '/resend_signup_confirmation'
            return
          end

          check_time = Time.now
          @new_user = User.find_by(username: username)&.destroy_and_disregard_unconfirmed_stale(check_time)
          if @new_user.nil?
            flash[:errors] = 'For some reason, the user you were creating was not successfully saved into our '\
              'databases at signup. Please try signing up again. If this happens again, please contact '\
              "#{settings.support_email}."
            redirect '/signup'
            return
          elsif @new_user.disabled
            flash[:errors] = 'Your account has been disabled.'
            redirect back
            return
          elsif @new_user.confirmed?(check_time)
            flash[:alerts] = 'Your account has already been confirmed!'
            redirect '/login'
            return
          end

          token_hash, token_salt = settings.redis_client.mget(
            "signup_confirmation_token_hash:#{username}",
            "signup_confirmation_token_salt:#{username}",
          )
          unless token_hash && token_salt
            # real corner case, in case they expired between username retrieval and
            # token hash/salt retrieval
            clear_signup_confirmation_tokens(url_token: signup_confirmation_url_token)
            flash[:errors] = 'Your signup confirmation request has expired (they expire after a while for security '\
              'reasons). Please request a new one below.'
            redirect '/resend_signup_confirmation'
            return
          end

          if token_hash != BCrypt::Engine.hash_secret(params[:confirm_token], token_salt)
            flash[:errors] = 'Incorrect confirmation code.'
            redirect back
          elsif @new_user.confirm_signup
            clear_signup_confirmation_tokens(url_token: signup_confirmation_url_token)
            flash[:alerts] = 'Your account has been confirmed successfully!'
            redirect '/login'
          else
            flash[:errors] = 'Sorry, we ran into a technical error saving your account confirmation! Please try '\
              "again, and if it happens again, contact #{settings.support_email}."
            redirect back
          end
        end

        get '/resend_signup_confirmation' do
          haml :resend_signup_confirmation
        end

        post '/resend_signup_confirmation' do
          check_time = Time.now
          @new_user = User.find_by(email: params[:email])&.destroy_and_disregard_unconfirmed_stale(check_time)
          if @new_user.nil?
            flash[:errors] = "The user with email with #{params[:email]} was not found. If you signed up more than "\
              "#{User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS} days ago, your signup may have been deleted; for "\
              'maintenance and security we delete users that appear to be orphaned while awaiting confirmation. '\
              'Please try signing up again.'
            redirect '/signup'
          elsif @new_user.disabled
            flash[:errors] = 'Your account has been disabled.'
            redirect back
          elsif @new_user.confirmed?(check_time)
            flash[:alerts] = 'Your account has already been confirmed!'
            redirect '/login'
          elsif settings.redis_client.get("signup_confirmation_email:#{@new_user.username}")
            flash[:alerts] = "A confirmation email has already been sent recently to #{params[:email]}. Please double-"\
              "check your email, including spam filters and other folders, and request another if it doesn't show up. "\
              "If you continue not to receive the confirmation email, contact #{settings.support_email}."
            redirect '/resend_signup_confirmation'
          else
            tokens = create_signup_confirmation_tokens(username: @new_user.username)
            @signup_confirmation_token = tokens[:confirm_token]
            @signup_confirmation_url_token = tokens[:url_token]

            if @signup_confirmation_token && @signup_confirmation_url_token
              @signup_confirmation_url = build_url(
                request,
                path: '/signup_confirmation',
                query: "url_token=#{@signup_confirmation_url_token}",
              )
              mail(
                to: @new_user.email,
                subject: "time-caddy signup confirmation for username #{@new_user.username}",
                body: erb(:'emails/signup_confirmation_email'),
              )
              haml :signup_confirmation_pending, locals: { resend: true }
            else
              flash[:errors] = "Technical issue creating the new account, please contact #{settings.support_email}."
              redirect back
            end
          end
        end
      end
    end
  end
end
