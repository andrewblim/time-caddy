# frozen_string_literal: true
class LogEntry < ActiveRecord::Base
  belongs_to :user
  has_and_belongs_to_many :tags
end
