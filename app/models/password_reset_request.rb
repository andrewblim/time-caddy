# frozen_string_literal: true
class PasswordResetRequest < ActiveRecord::Base
  PASSWORD_RESET_REQUEST_LIFESPAN_IN_SEC = 6 * 60 * 60

  belongs_to :user

  def usable?(as_of: Time.now)
    active && request_time.advance(seconds: PASSWORD_RESET_REQUEST_LIFESPAN_IN_SEC) > as_of
  end
end
