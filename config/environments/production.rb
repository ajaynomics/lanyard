require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings.
  config.eager_load = true

  # In Rake tasks, the previous assignment is ignored, config.eager_load is set
  # from config.rake_eager_load.
  config.rake_eager_load = false

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local
  # Cloudflare Tunnel terminates TLS. kamal-proxy forwards plain HTTP.
  config.assume_ssl = true
  config.force_ssl = true
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag. Docker
  # reads stdout through a pipe, where Ruby buffers by the block and Logger
  # leaves an IO it did not open as it found it: unsynced, a request's lines
  # arrived minutes late and in batches, and a 1.5s call looked hung for four.
  STDOUT.sync = true
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates. Derived from
  # APP__URL below, like config.hosts, so a destination states its origin once.

  # The agents' outgoing mail (config/mail.yml, docs/email.md).
  # Mail arrives by IMAP (EmailFetchJob): no Action Mailbox ingress is set, so its routes answer 404.
  if (smtp = config.x.mail)[:smtp_address].present?
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = { address: smtp[:smtp_address], port: smtp[:smtp_port], user_name: smtp[:smtp_user_name],
                                           password: smtp[:smtp_password], authentication: :plain, enable_starttls: true }
  end

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # DNS rebinding protection. The origin this destination answers on is stated
  # once, as APP__URL in its deploy file — so a new destination is one line of
  # YAML there rather than a hostname edited into this file. kamal-proxy
  # forwards the public Host header through, and only the health path it polls
  # may skip the check.
  if (app_url = Rails.app.creds.option(:app, :url)).present?
    origin = URI.parse(app_url)
    config.hosts = [ origin.host, *DurableAssistants.redirect_hosts ]
    config.action_mailer.default_url_options = { host: origin.host, protocol: origin.scheme }
  end
  # Campfire may call its webhook from inside the host, by container name; the
  # token in the path is what admits it (CampfireWebhooksController).
  config.host_authorization = { exclude: ->(request) { request.path == "/up" || request.path.start_with?("/campfire/") } }
end
