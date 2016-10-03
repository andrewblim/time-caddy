# frozen_string_literal: true
class CreateTags < ActiveRecord::Migration[4.2]
  def change
    create_table :tags do |t|
      t.string :name, null: false, limit: 80
    end
    add_index :tags, :name, unique: true

    create_table :log_entries_tags, id: false do |t|
      t.belongs_to :log_entry, index: true
      t.belongs_to :tag, index: true
    end
  end
end
