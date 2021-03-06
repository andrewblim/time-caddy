# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# Note that this schema.rb definition is the authoritative source for your
# database schema. If you need to create the application database on another
# system, you should be using db:schema:load, not running all the migrations
# from scratch. The latter is a flawed and unsustainable approach (the more migrations
# you'll amass, the slower it'll run and the greater likelihood for issues).
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema.define(version: 20161015205224) do

  create_table "log_entries", force: :cascade do |t|
    t.integer  "user_id"
    t.datetime "start_at",                  null: false
    t.datetime "finish_at",                 null: false
    t.string   "description", limit: 65535, null: false
    t.index ["user_id"], name: "index_log_entries_on_user_id"
  end

  create_table "log_entries_tags", id: false, force: :cascade do |t|
    t.integer "log_entry_id"
    t.integer "tag_id"
    t.index ["log_entry_id"], name: "index_log_entries_tags_on_log_entry_id"
    t.index ["tag_id"], name: "index_log_entries_tags_on_tag_id"
  end

  create_table "password_reset_requests", force: :cascade do |t|
    t.integer  "user_id"
    t.datetime "request_time",              null: false
    t.string   "password_reset_token_hash", null: false
    t.string   "password_reset_token_salt", null: false
    t.string   "password_reset_url_token",  null: false
    t.boolean  "active",                    null: false
    t.index ["password_reset_url_token"], name: "index_password_reset_requests_on_password_reset_url_token", unique: true
    t.index ["user_id"], name: "index_password_reset_requests_on_user_id"
  end

  create_table "tags", force: :cascade do |t|
    t.string "name", limit: 80, null: false
    t.index ["name"], name: "index_tags_on_name", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.string   "username",                 limit: 40, null: false
    t.string   "email",                    limit: 60
    t.string   "password_hash",                       null: false
    t.string   "password_salt",                       null: false
    t.datetime "signup_time",                         null: false
    t.datetime "signup_confirmation_time"
    t.boolean  "disabled",                            null: false
    t.string   "default_tz",               limit: 60, null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["username"], name: "index_users_on_username", unique: true
  end

end
