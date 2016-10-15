# frozen_string_literal: true
class PasswordResetRequest < ActiveRecord::Base
  belongs_to :user
end
