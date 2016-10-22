# frozen_string_literal: true
require 'pony'

module Helpers
  module BuildURL
    def build_url(request, **kwargs)
      defaults = {
        scheme: request.scheme,
        host: request.host,
        port: request.port == 80 ? nil : request.port,
        path: '/',
      }
      URI::Generic.build(defaults.merge(kwargs))
    end
  end
end
