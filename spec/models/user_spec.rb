# frozen_string_literal: true
require 'spec_helper'
require 'bcrypt'

RSpec.describe User do
  it 'disallows two users with the same username' do
    expect(create(:user, username: 'test', email: 'test@test.com')).to be_a described_class
    expect { create(:user, username: 'test', email: 'test2@test.com') }.to raise_error ActiveRecord::RecordInvalid
    expect(create(:user, username: 'test2', email: 'test2@test.com')).to be_a described_class
  end

  it 'disallows two users with the same email' do
    expect(create(:user, username: 'test', email: 'test@test.com')).to be_a described_class
    expect { create(:user, username: 'test2', email: 'test@test.com') }.to raise_error ActiveRecord::RecordInvalid
    expect(create(:user, username: 'test2', email: 'test2@test.com')).to be_a described_class
  end

  it 'disallows users with bad email addresses' do
    expect { create(:user, email: 'not_an_email') }.to raise_error ActiveRecord::RecordInvalid
  end

  it 'disallows users with bad time zones' do
    expect { create(:user, default_tz: 'not_a_tz') }.to raise_error ActiveRecord::RecordInvalid
  end

  it 'creates password hashes and salts for new users' do
    user = described_class.new_with_salted_password(
      username: 'test',
      email: 'test@test.com',
      password: 'foo',
      disabled: false,
      default_tz: 'America/New_York',
      signup_time: Time.now,
    )
    expect(user).to be_a described_class
    expect(user.save).to be true
    expect(user.check_password('foo')).to be true
    expect(user.check_password('foo2')).to be false

    custom_salt = BCrypt::Engine.generate_salt
    user = described_class.new_with_salted_password(
      username: 'test2',
      email: 'test2@test.com',
      password: 'foo',
      password_salt: custom_salt,
      disabled: false,
      default_tz: 'America/New_York',
      signup_time: Time.now,
    )
    expect(user).to be_a described_class
    expect(user.save).to be true
    expect(user.password_salt).to eq(custom_salt)
    expect(user.check_password('foo')).to be true
    expect(user.check_password('foo2')).to be false
  end

  it 'updates password hashes and salts' do
    user = described_class.new_with_salted_password(
      username: 'test',
      email: 'test@test.com',
      password: 'foo',
      disabled: false,
      default_tz: 'America/New_York',
      signup_time: Time.now,
    )
    user.save
    expect(user.check_password('foo')).to be true
    expect(user.check_password('foo2')).to be false
    user.change_password('foo2')
    expect(user.check_password('foo')).to be false
    expect(user.check_password('foo2')).to be true
  end

  it 'transitions between states' do
    user = create(:user, signup_time: Time.now)
    expect(user.unconfirmed_fresh?).to be true
    expect(user.unconfirmed_stale?).to be false
    expect(user.confirmed?).to be false
    expect(user.unconfirmed_fresh?(Time.now.advance(days: User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS + 1))).to be false
    expect(user.unconfirmed_stale?(Time.now.advance(days: User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS + 1))).to be true
    expect(user.confirmed?(Time.now.advance(days: User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS + 1))).to be false
    user.confirm
    expect(user.unconfirmed_fresh?).to be false
    expect(user.unconfirmed_stale?).to be false
    expect(user.confirmed?).to be true

    user.signup_confirmation_time = nil
    user.confirm(Time.now.advance(days: User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS + 10))
    expect(user.unconfirmed_fresh?).to be true
    expect(user.unconfirmed_stale?).to be false
    expect(user.confirmed?).to be false
    expect(user.unconfirmed_fresh?(Time.now.advance(days: User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS + 1))).to be false
    expect(user.unconfirmed_stale?(Time.now.advance(days: User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS + 1))).to be true
    expect(user.confirmed?(Time.now.advance(days: User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS + 1))).to be false
    expect(user.unconfirmed_fresh?(Time.now.advance(days: User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS + 10))).to be false
    expect(user.unconfirmed_stale?(Time.now.advance(days: User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS + 10))).to be false
    expect(user.confirmed?(Time.now.advance(days: User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS + 10))).to be true
  end

  it 'correctly destroys unconfirmed stale users by username when requested' do
    user_fresh = create(:user, username: 'fresh', email: 'fresh@test.com', signup_time: Time.now)
    user_stale1 = create(
      :user,
      username: 'stale1',
      email: 'stale1@test.com',
      signup_time: Time.now.advance(days: -User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS - 1),
    )
    user_stale2 = create(
      :user,
      username: 'stale2',
      email: 'stale2@test.com',
      signup_time: Time.now.advance(days: -User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS - 1),
    )

    # destroy nothing
    User.destroy_unconfirmed_stale_by_username(
      'stale1',
      as_of: Time.now.advance(days: -User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS),
    )
    expect(described_class.find(user_fresh.id)).to be_a described_class
    expect(described_class.find(user_stale1.id)).to be_a described_class
    expect(described_class.find(user_stale2.id)).to be_a described_class

    # destroy something
    User.destroy_unconfirmed_stale_by_username('stale1') # default Time.now
    expect(described_class.find(user_fresh.id)).to be_a described_class
    expect { described_class.find(user_stale1.id) }.to raise_error  ActiveRecord::RecordNotFound
    expect(described_class.find(user_stale2.id)).to be_a described_class
    User.destroy_unconfirmed_stale_by_username('stale2') # default Time.now
    expect(described_class.find(user_fresh.id)).to be_a described_class
    expect { described_class.find(user_stale1.id) }.to raise_error  ActiveRecord::RecordNotFound
    expect { described_class.find(user_stale2.id) }.to raise_error  ActiveRecord::RecordNotFound
  end

  it 'correctly destroys unconfirmed stale users by email when requested' do
    user_fresh = create(:user, username: 'fresh', email: 'fresh@test.com', signup_time: Time.now)
    user_stale1 = create(
      :user,
      username: 'stale1',
      email: 'stale1@test.com',
      signup_time: Time.now.advance(days: -User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS - 1),
    )
    user_stale2 = create(
      :user,
      username: 'stale2',
      email: 'stale2@test.com',
      signup_time: Time.now.advance(days: -User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS - 1),
    )

    # destroy nothing
    User.destroy_unconfirmed_stale_by_email(
      'stale1@test.com',
      as_of: Time.now.advance(days: -User::INACTIVE_ACCOUNT_LIFESPAN_IN_DAYS),
    )
    expect(described_class.find(user_fresh.id)).to be_a described_class
    expect(described_class.find(user_stale1.id)).to be_a described_class
    expect(described_class.find(user_stale2.id)).to be_a described_class

    # destroy something
    User.destroy_unconfirmed_stale_by_email('stale1@test.com') # default Time.now
    expect(described_class.find(user_fresh.id)).to be_a described_class
    expect { described_class.find(user_stale1.id) }.to raise_error  ActiveRecord::RecordNotFound
    expect(described_class.find(user_stale2.id)).to be_a described_class
    User.destroy_unconfirmed_stale_by_email('stale2@test.com') # default Time.now
    expect(described_class.find(user_fresh.id)).to be_a described_class
    expect { described_class.find(user_stale1.id) }.to raise_error  ActiveRecord::RecordNotFound
    expect { described_class.find(user_stale2.id) }.to raise_error  ActiveRecord::RecordNotFound
  end

  it 'counts password resets'
end
