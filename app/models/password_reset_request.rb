# frozen_string_literal: true
class PasswordResetRequest < ActiveRecord::Base
  PASSWORD_RESET_REQUEST_LIFESPAN_IN_HOURS = 24

  belongs_to :user

  def active?(as_of: Time.now)
    !used && request_time.advance(hours: PASSWORD_RESET_REQUEST_LIFESPAN_IN_HOURS) > as_of
  end
end
