class CreateUsers < ActiveRecord::Migration
  def change
    create_table :users do |t|
      t.string :username, limit: 40, null: false
      t.string :email, limit: 60
      t.string :password_hash, null: false
      t.string :password_salt, null: false
    end
    add_index :users, :username, unique: true
    add_index :users, :email, unique: true
  end
end
