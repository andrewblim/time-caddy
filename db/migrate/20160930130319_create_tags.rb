# frozen_string_literal: true
class CreateTags < ActiveRecord::Migration[4.2]
  def change
    create_table :tags do |t|
      t.string :name, null: false, limit: 80
    end
    add_index :tags, :name, unique: true
  end
end
