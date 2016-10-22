# frozen_string_literal: true
require 'pony'

module Helpers
  module BuildURL
    def build_url(request, path = '/')
      URI::Generic.build(
        scheme: request.scheme,
        host: request.host,
        port: request.port == 80 ? nil : request.port,
        path: path,
      )
    end
  end
end
