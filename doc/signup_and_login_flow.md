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
  - If user does not exist, or exists and is stale (destroy if so):
    - Create new user in an inactive state
    - Create activation_token and salt, store hashed activation_token and salt in Redis with username-based keys and a short expiry
    - Create signup_confirmation_url_token, store username in Redis with signup_confirmation_url_token-based key and the same short expiry
    - Send email with activation_token and link to `/signup_confirmation?url_token=<signup_confirmation_url_token>`
    - Display page instructing user to follow instructions in email (no redirection)
  - If user exists and is not active and not stale, redirect back
  - If user exists and is already active, redirect back
- GET `/signup_confirmation?url_token=<signup_confirmation_url_token>`
  - Display signup confirmation token form
- POST `/signup_confirmation`
  - If signup_confirmation_url_token is not provided, redirect to `/resend_signup_confirmation`
  - If signup_confirmation_url_token key does not exist (i.e. expired), redirect to `/resend_signup_confirmation`
  - Otherwise, get username from signup_confirmation_url_token
  - If user does not exist, or exists and is stale (destroy if so), redirect to `/signup`
  - If user exists and is not active and not stale:
    - If the activation_token and salt do not exist (i.e. expired):
      - Expire all signup confirmation token Redis keys, just in case
      - Redirect to `/resend_signup_confirmation`
    - If the submitted token does not match activation_token and salt, redirect back
    - If the submitted token matches:
      - Activate user
      - Expire all signup confirmation token Redis keys
      - Redirect to `/login`
  - If user exists and is already active, redirect to `/login`

Resending signup confirmation, in case the normal one didn't work or something:

- GET `/resend_signup_confirmation`
  - Display form asking for the email address (not username) to which to send a new confirmation
- POST `/resend_signup_confirmation`
  - If user does not exist, or exists and is stale (destroy if so), redirect to `/signup`
  - If user exists and is not active and not stale:
    - Same stuff as POST `/signup` when user does not exist/exists and is stale, except for user creation
  - If user exists and is already active, redirect to `/login`

Password resets:

- GET `/password_reset_request`
  - Display form asking for the email address (not username) to which to send a new password reset request
- POST `/password_reset_request`
  - If user does not exist, or exists and is stale (destroy if so), redirect to `/signup`
  - If user exists and is not active and not stale, redirect to `/resend_signup_confirmation` (don't reset an inactive user)
  - If user exists and is active:
    - If there have been too many recent password reset requests, redirect to `/password_reset_request`
    - Expire all pre-existing Redis keys
    - Create password_reset_token and salt
    - Create active password reset request entry with token and salt
    - Create password_reset_url_token, store email in Redis with password_reset_url_token-based key and a short expiry
    - Send email with password_reset_token and link to `/password_reset?url_token=<password_reset_url_token>`
    - Display page instructing user to follow instructions in email (no redirection)
- GET `/password_reset?url_token=<password_reset_url_token>`
  - Display password reset token form, which has fields for the token and the new password
- POST `/password_reset`
  - If password_reset_url_token key does not exist (i.e. expired), redirect to `/password_reset_request`
  - Otherwise, get username from password_reset_url_token
  - If user does not exist, or exists and is stale (destroy if so), redirect to `/signup`
  - If user exists and is not active and not stale, redirect to `/password_reset_request` (don't reset an inactive user)
  - If user exists and is active:
    - Retrieve the most recent active password request
    - If the submitted token does not match this request's token and salt, redirect back
    - If the submitted token matches:
      - Create salt, set user's password hash and salt to new values
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

## Token emails

There are two places above where we send email confirmation requests before permitting site visitors to take the next step:

1. when confirming a new signup
2. when trying to reset a password

In both cases, the email contains a randomly generated confirmation token `confirm_token` and a URL with a randomly generated token `url_token` parameter. The user needs to visit the URL and enter the confirmation token. This provides two levels of security:

- You need a valid `url_token` to begin with.
- Even if someone gets a valid `url_token` somehow, maybe by guessing, maybe because the actual user clicked the link and someone intercepted the request (as it's a GET, the `url_token` is stored right there in the URL), you still can't confirm the account without the `confirm_token`.

If someone has both the link and the token, they can reset the password or confirm the account. However, there is a very slight additional layer of protection in that if they don't know the associated username or email address, they still can't log in, because the app does not display it at any point after the user visits the URL in the email.

If someone has the link, the token, and the username or email address, as would happen if an unauthorized user had access to the user's email account, then there are no further safeguards (other than that we disallow too many confirmation emails to go out within a short period of time). The ability to read a user's email will break through all of these safeguards.

## Logged-in users

Although the signup and password reset flows would typically be done by a user who is not logged in, it is OK to do it while logged in as a user. However, a warning will appear on all of the GET responses that suggest visiting the user settings page instead.
