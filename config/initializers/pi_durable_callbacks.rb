# The sidecar calls Rails back over the private container network, by the web
# role's network alias (AGENT_RAILS_URL, config/deploy.*.yml), not by the
# public origin config.hosts names. Those POST routes alone skip host
# authorization: they are never served to a browser, carry no cookie, and
# refuse anything without RAILS_TOKEN (Sidecar::PrivateController). Every other
# path keeps production's DNS-rebinding protection unchanged.
callbacks = %w[/agent/accesses /agent/invocations /agent/frames /agent/syncs /agent/sign_ins /agent/files /agent/uploads].freeze
previous = Rails.application.config.host_authorization[:exclude]
Rails.application.config.host_authorization = Rails.application.config.host_authorization.merge(
  exclude: ->(request) { previous&.call(request) || (request.post? && callbacks.include?(request.path)) }
)
