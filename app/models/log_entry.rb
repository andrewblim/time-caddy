# frozen_string_literal: true
class LogEntry < ActiveRecord::Base
  belongs_to :user
end
