# frozen_string_literal: true
class Tag < ActiveRecord::Base
  has_and_belongs_to_many :log_entries
end
