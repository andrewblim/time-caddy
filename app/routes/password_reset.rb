# frozen_string_literal: true
module Routes
  module PasswordReset
    def self.registered(app)
      app.instance_eval do
        get '/password_reset_request' do
          haml :password_reset_request
        end

        post '/password_reset_request' do
          check_time = Time.now
          @password_reset_user = User.find_by(email: params[:email])&.destroy_and_disregard_unconfirmed_stale(check_time)
          if @password_reset_user.nil?
            flash[:errors] = "No user with email #{params[:email]} was found. If you signed up more than "\
              "#{User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS} days ago, your signup may have been deleted; for maintenance and "\
              'security we delete users that appear to be orphaned while awaiting confirmation. Please try signing up again.'
            redirect '/signup'
          elsif @password_reset_user.disabled
            flash[:errors] = 'Your account has been disabled.'
            redirect back
          elsif @password_reset_user.unconfirmed_fresh?
            flash[:errors] = "Your account is created but still not activated, which is why you can't log in. Please follow "\
              "the instructions in the email that was sent to you. If it's been a while and you haven't received the email, "\
              '<a href="/resend_signup_confirmation">click here</a>.'
            redirect back
          elsif @password_reset_user.recent_password_reset_requests_count > MAX_RECENT_PASSWORD_RESET_REQUESTS
            flash[:errors] = "There have been too many recent password reset requests for #{params[:email]}. "\
              "You can either wait a while, or contact #{settings.support_email} for help."
            redirect back
          else
            @password_reset_token = SecureRandom.hex(16)
            password_reset_token_salt = BCrypt::Engine.generate_salt
            password_reset_token_hash = BCrypt::Engine.hash_secret(@password_reset_token, password_reset_token_salt)

            reset_request = PasswordResetRequest.transaction do
              loop do
                @password_reset_url_token = SecureRandom.hex(16)
                break unless PasswordResetRequest.find_by(password_reset_url_token: @password_reset_url_token)
              end
              @password_reset_user.password_reset_requests.update_all(active: false)
              @password_reset_user.password_reset_requests.create(
                request_time: Time.now,
                password_reset_token_hash: password_reset_token_hash,
                password_reset_token_salt: password_reset_token_salt,
                password_reset_url_token: @password_reset_url_token,
                active: true,
              )
            end

            if reset_request.nil?
              mail(
                to: @password_reset_user.email,
                subject: "Password reset request for time-caddy username #{@password_reset_user.username}",
                body: erb(:'emails/password_reset_request'),
              )
              haml :password_reset_pending
            else
              flash[:errors] = "Technical issue creating a password reset request, please contact #{settings.support_email}."
              redirect back
            end
          end
        end

        get '/password_reset' do
          @password_reset_url_token = params[:url_token] || ''
          haml :password_reset
        end

        post '/password_reset' do
          @password_reset_url_token = params[:url_token]
          if @password_reset_url_token.nil?
            flash[:errors] = 'Invalid password reset token, please re-request a password reset if you need one.'
            redirect '/password_reset_request'
            return
          end
          reset_request = PasswordResetRequest.find(password_reset_url_token: @password_reset_url_token, active: true)
          if reset_request.nil? || !reset_request.usable?
            reset_request.update(active: false) if reset_request
            flash[:errors] = 'Invalid password reset token, please re-request a password reset if you need one.'
            redirect '/password_reset_request'
            return
          end
          user = reset_request.user
          if user.disabled
            reset_request.update(active: false)
            flash[:errors] = 'The user associated with this password reset request has been disabled.'
            redirect '/login'
            return
          end
          submitted_token_hash = BCrypt::Engine.hash_secret(params[:confirm_token], reset_request.password_reset_token_salt)
          if reset_request.password_reset_token_hash != submitted_token_hash
            reset_request.update(active: false)
            flash[:errors] = 'Invalid password reset confirmation code.'
            redirect back
          end

          password_salt = BCrypt::Engine.generate_salt
          password_hash = BCrypt::Engine.hash_secret(params[:new_password], password_salt)
          if user.update(password_hash: password_hash, password_salt: password_salt)
            reset_request.update(active: false)
            flash[:alerts] = 'Your password has been successfully reset.'
            redirect '/login'
          else
            flash[:errors] = "Technical issue resetting password, please contact #{settings.support_email}."
            redirect back
          end
        end
      end
    end
  end
end
