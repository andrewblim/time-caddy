# frozen_string_literal: true

configure :development do
  ActiveRecord::Base.establish_connection(
    adapter: 'sqlite3',
    database: 'db/time_caddy.sqlite3.db'
  )
end

configure :production do
  # TODO
end
