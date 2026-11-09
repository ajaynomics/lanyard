source "https://rubygems.org"

# Edge Rails, one pinned commit for every app (STANDARDS.md S2). Upgrade the
# ref in the template and in all apps together.
gem "rails", github: "rails/rails", ref: "c9e85dbe297e248dd2f217d04f84a94881ac046a"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use sqlite3 as the database for Active Record
gem "sqlite3", ">= 2.1"
# Fiber-per-request server (S1). Replaces Puma and Thruster.
gem "falcon", ">= 0.57.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", ">= 1.24.1", require: false

# Ajent is the sign-in boundary. The app stores no passwords.
gem "omniauth_openid_connect", "~> 0.8.0"
gem "omniauth-rails_csrf_protection", "~> 2.0"

# Traces to the install's collector. Inert without an endpoint.
gem "opentelemetry-sdk"
gem "opentelemetry-exporter-otlp"
gem "opentelemetry-instrumentation-all"

# First-party visits and the events that matter, in the app's own database
# (config/initializers/ahoy.rb).
gem "ahoy_matey", "~> 5.5"

# A tool's one JSON Schema checks the arguments the model sent (app/models/tool.rb).
gem "json_schemer", "~> 2.4"

# Outside tools: Rails is the client of an agent's remote MCP servers (app/models/mcp_server.rb).
# The SDK loads Faraday and the SSE parser on demand without declaring either.
gem "mcp", "~> 1.7"
gem "faraday", "~> 2.0"
gem "event_stream_parser"

# Renders the assistant's committed Markdown; the result is sanitized (ui/_markdown).
gem "commonmarker", "~> 2.0"

# Page numbers for the conversation list, 30 at a time (Basecamp's).
gem "geared_pagination", "~> 1.2"

# The agent's screen: Rails relays the page's websocket to the sidecar (Conversations::ScreensController).
gem "async-websocket", "~> 0.30.2"

# Calendar events and tasks, read and written over CalDAV (lib/durable_assistants/caldav.rb).
gem "icalendar", "~> 2.13"

# Notifications to the person's devices, encrypted to each browser (app/models/push/subscription.rb).
gem "web-push", "~> 3.1"

# Errors to the shared GlitchTip. Inert without a DSN.
gem "sentry-rails"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
  gem "kamal", require: false

  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"

  # Tests cannot reach the network (S6); see test/test_helper.rb.
  gem "webmock"
end
