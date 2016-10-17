# frozen_string_literal: true
module AppMailer
  def mail(**kwargs)
    if settings.email_enabled
      Pony.mail(
        **kwargs.merge(
          via: :smtp,
          via_options: {
            address: settings.smtp['host'],
            port: settings.smtp['port'],
            user_name: settings.smtp['username'],
            password: settings.smtp['password'],
            authentication: settings.smtp['authentication'].to_sym,
            domain: settings.smtp['domain'],
          },
        )
      )
    end
  end
end
