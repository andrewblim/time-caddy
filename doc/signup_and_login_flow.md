# Signup and login flow

## Guidelines

Usernames and email addresses are unique across all users. The existence or non-existence of usernames and email addresses is public information. We do not attempt to hide whether a given username or email address does or does not exist.

However, it should be impossible to determine a user's email address from her username alone or vice versa, unless she has explicitly enabled a flag to make this information public, and any such flag should always default to hiding this mapping from everyone.

Flash notifications are very helpful to guide users when they follow an unexpected path through the workflow, such as if they allow a token to expire, or if they somehow try to skip a step. We use them whenever possible, but we always have to be careful not to inadvertently give away information to which a site user should not be privy. For example, if you submit a form by email address only, you should not be able to see a username in a flash notification, or vice versa.

## Workflows

Main workflow:

- GET `/signup`
  - Displays new account form
- POST `/signup`
  - If user does not exist, or exists and is stale:
    - Destroy user if it exists
    - Create new user in an inactive state
    - Expire all pre-existing Redis keys
    - Create activation_token and salt, store hashed activation_token and salt in Redis with username-based keys and a short expiry
    - Create signup_confirmation_url_token, store username in Redis with signup_confirmation_url_token-based key and the same short expiry
    - Send email with activation_token and link to `/signup_confirmation?token=<signup_confirmation_url_token>`
    - Redirect to `/signup_confirmation?token=<signup_token>`
  - If user exists and is not active and not stale, redirect to `/resend_signup_confirmation`
  - If user exists and is already active, redirect to `/login`
- GET `/signup_confirmation?token=<signup_confirmation_url_token>`
  - If signup_confirmation_url_token key does not exist (i.e. expired), redirect to `/resend_signup_confirmation`
  - If signup_confirmation_url_token key exists, display signup confirmation token form
- POST `/signup_confirmation`
  - If signup_confirmation_url_token key does not exist (i.e. expired), redirect to `/resend_signup_confirmation`
  - Otherwise, get username from signup_confirmation_url_token
  - If user does not exist, or exists and is stale:
    - Destroy user if it exists
    - Redirect to `/signup`
  - If user exists and is not active and not stale:
    - If the activation_token and salt do not exist (i.e. expired):
      - Expire all Redis keys
      - Redirect to `/resend_signup_confirmation`
    - If the submitted token does not match activation_token and salt, redirect to `/signup_confirmation?token=<signup_token>`
    - If the submitted token matches:
      - Activate user
      - Expire all Redis keys
      - Redirect to `/login`
  - If user exists and is already active, redirect to `/login`

Resending signup confirmation, in case the normal one didn't work or something:

- GET `/resend_signup_confirmation`
  - Display form asking for the email address (not username) to which to send a new confirmation
- POST `/resend_signup_confirmation`
  - If user does not exist, or exists and is stale:
    - Destroy user if it exists
    - Redirect to `/signup`
  - If user exists and is not active and not stale:
    - Same stuff as POST `/signup`, when user does not exist/exists and is stale, except for user creation
  - If user exists and is already active, redirect to `/login`

Password resets:

- GET `/password_reset_request`
  - Display form asking for the email address (not username) to which to send a new password reset request
- POST `/password_reset_request`
  - If user does not exist, or exists and is stale:
    - Destroy user if it exists
    - Redirect to `/signup`
  - If user exists and is not active and not stale, redirect to `/resend_signup_confirmation` (don't reset an inactive user)
  - If user exists and is active:
    - If there have been too many recent password reset requests, redirect to `/password_reset_request`
    - Expire all pre-existing Redis keys
    - Create password_reset_token and salt
    - Create active password reset request entry with token and salt
    - Create password_reset_url_token, store email in Redis with password_reset_url_token-based key and a short expiry
    - Send email with password_reset_token and link to `/password_reset?token=<password_reset_url_token>`
    - Don't redirect them, just display a notice telling them to check their email
- GET `/password_reset?token=<password_reset_url_token>`
  - If password_reset_url_token key does not exist (i.e. expired), redirect to `/password_reset_request`
  - If password_reset_url_token key exists, display password reset token form, which has fields for the token and the new password
- POST `/password_reset`
  - If password_reset_url_token key does not exist (i.e. expired), redirect to `/password_reset_request`
  - Otherwise, get username from password_reset_url_token
  - If user does not exist, or exists and is stale:
    - Destroy user if it exists
    - Redirect to `/signup`
  - If user exists and is not active and not stale, redirect to `/resend_signup_confirmation` (don't reset an inactive user)
  - If user exists and is active:
    - Retrieve the most recent active password request
    - If the submitted token does not match this request's token and salt, redirect to `/password_reset?token=<password_reset_url_token>`
    - If the submitted token matches:
      - Create salt, set user's password hash and salt to new values
      - Expire all pre-existing Redis keys
      - Redirect to `/login` (don't actually log in ourselves)

Logins:

- GET `/login` (a form that does the same thing is usually visible in the navbar)
  - Display form asking for username or email and password
- POST `/login`
  - If user does not exist, or exists and is stale, redirect to `/login`
  - If user exists and is not active and not stale, redirect to `/resend_signup_confirmation`
  - If user exists and is active:
    - If password is wrong, redirect to `/login`
    - If password is right, log user in and redirect to `/`
- POST `/logout`
  - Log user out and redirect to `/`

## User states

As can be seen by the above workflows, the user states that we have to worry about are:

1. No such user exists
2. User exists, is not activated, and was created more than a certain time ago ("stale")
3. User exists, is not activated, and is not stale ("fresh")
4. User exists and is activated

Stale users effectively don't exist, and every time we have the opportunity to destroy them on a POST we do so.

## Logged-in users

Although the signup and password reset flows would typically be done by a user who is not logged in, it is OK to do it while logged in as a user. However, a flash warning will appear on all of the GET responses that point this out and suggest visiting the user settings page instead.

## To-do

- Add user flag for disabling access, which when toggled should forcibly log users out on their next request and should prevent logins, signup confirmations, and password resets.
- Add more robust configuration for what to do when email is not available. 
