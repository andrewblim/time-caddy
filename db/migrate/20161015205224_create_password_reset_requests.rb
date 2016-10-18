# frozen_string_literal: true
class CreatePasswordResetRequests < ActiveRecord::Migration[4.2]
  def change
    create_table :password_reset_requests do |t|
      t.belongs_to :user, index: true
      t.datetime :request_time, null: false
      t.string :password_reset_token_hash, null: false
      t.string :password_reset_token_salt, null: false
      t.string :password_reset_url_token, null: false
      t.boolean :active, null: false
    end
    add_index :password_reset_requests, :password_reset_url_token, unique: true
  end
end
