# frozen_string_literal: true

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
          now = Time.now
          User.destroy_unconfirmed_stale_by_username(params[:username], as_of: now)
          User.destroy_unconfirmed_stale_by_email(params[:email], as_of: now)
          @new_user = User.new_with_salted_password(
            username: params[:username],
            email: params[:email],
            password: params[:password],
            disabled: false,
            default_tz: params[:default_tz],
            signup_time: now,
            signup_confirmation_time: nil,
          )

          signup_errors = []
          unless @new_user.valid?
            signup_errors << @new_user.errors.full_messages
          end
          unless params[:password].length >= 6
            signup_errors << 'Your password must be at least 6 characters long.'
          end
          unless signup_errors.blank?
            flash[:errors] = signup_errors
            redirect back
            return
          end

          # Create user, generate tokens, send email
          unless @new_user.save
            flash[:errors] = 'Technical issue saving the new user to the database, '\
              "please contact #{settings.support_email}."
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
            flash[:errors] = 'Technical issue creating the confirmation email, '\
              "please contact #{settings.support_email}."
            redirect back
          end
        end

        get '/signup_confirmation' do
          @signup_confirmation_url_token = params[:url_token] || ''
          haml :signup_confirmation
        end

        post '/signup_confirmation' do
          unless params[:url_token]
            flash[:errors] = 'Invalid signup confirmation token'
            redirect '/resend_signup_confirmation'
            return
          end
          username = get_username_from_signup_confirmation(url_token: params[:url_token])
          unless username
            clear_signup_confirmation_tokens(url_token: params[:url_token])
            flash[:errors] = 'Your signup confirmation request has expired (they expire after a while for security '\
              'reasons). Please request a new one.'
            redirect '/resend_signup_confirmation'
            return
          end

          now = Time.now
          User.destroy_unconfirmed_stale_by_username(username, as_of: now)
          @new_user = User.find_by(username: username)
          if @new_user.nil?
            flash[:errors] = 'Technical issue retrieving user from confirmation email, '\
              "please contact #{settings.support_email}."
            redirect '/signup'
            return
          elsif @new_user.disabled
            flash[:errors] = 'Your account has been disabled.'
            redirect back
            return
          elsif @new_user.confirmed?(now)
            flash[:alerts] = 'Your account has already been confirmed!'
            redirect '/login'
            return
          end

          token_check = check_signup_confirmation_confirm_token(
            username: username,
            confirm_token: params[:confirm_token],
          )
          if token_check.nil?
            # real corner case, in case they expired between username retrieval and
            # token hash/salt retrieval
            clear_signup_confirmation_tokens(url_token: params[:url_token])
            flash[:errors] = 'Your signup confirmation request has expired (they expire after a while for security '\
              'reasons). Please request a new one below.'
            redirect '/resend_signup_confirmation'
          elsif !token_check
            flash[:errors] = 'Incorrect confirmation code.'
            redirect back
          end

          if @new_user.confirm
            clear_signup_confirmation_tokens(url_token: params[:url_token])
            flash[:alerts] = 'Your account has been confirmed successfully!'
            redirect '/login'
          else
            flash[:errors] = 'Technical issue confirming newly signed-up user, '\
              "please contact #{settings.support_email}."
            redirect back
          end
        end

        get '/resend_signup_confirmation' do
          haml :resend_signup_confirmation
        end

        post '/resend_signup_confirmation' do
          now = Time.now
          User.destroy_unconfirmed_stale_by_email(params[:email], as_of: now)
          @new_user = User.find_by(email: params[:email])

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
          elsif recent_signup_confirmation_email(username: @new_user.username)
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
