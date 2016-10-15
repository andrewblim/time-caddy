# frozen_string_literal: true
class CreatePasswordResetRequests < ActiveRecord::Migration[4.2]
  def change
    create_table :password_reset_requests do |t|
      t.belongs_to :user, index: true
      t.datetime :requested_at, null: false
    end
  end
end
