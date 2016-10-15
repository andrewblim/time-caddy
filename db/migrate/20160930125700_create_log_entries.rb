# frozen_string_literal: true
class CreateLogEntries < ActiveRecord::Migration[4.2]
  def change
    create_table :log_entries do |t|
      t.belongs_to :user, index: true
      t.datetime :start_at, null: false
      t.datetime :finish_at, null: false
      t.string :description, null: false, limit: 65535
    end
  end
end
