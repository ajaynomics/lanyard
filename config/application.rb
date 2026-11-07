require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module DurableAssistants
  # The deployed revision, for telemetry and error reports.
  #
  # Kamal sets KAMAL_VERSION on every container it runs. REVISION is only a
  # builder arg unless the Dockerfile promotes it, so reading REVISION alone
  # silently yields nil in production.
  def self.revision
    ENV["KAMAL_VERSION"].presence || ENV["REVISION"].presence
  end

  # Safe reader for config.x. Unset keys on config.x are truthy empty
  # OrderedOptions; this collapses nil / "" / {} / [] / empty OrderedOptions
  # to the default. false and 0 pass through.
  def self.config(*path, default: nil)
    raise ArgumentError, "config path required" if path.empty?

    value = Rails.application.config.x.public_send(path.first)
    path.drop(1).each do |key|
      return default unless value.respond_to?(:dig)
      value = value.dig(key)
    end

    return default if value.nil?
    return default if value.respond_to?(:empty?) && value.empty?
    value
  end

  # Hostnames that only redirect to APP__URL (config/routes.rb).
  def self.redirect_hosts = config(:app, :redirects).to_s.split(",").map(&:strip).compact_blank

  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.2

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    #
    # Once, not reloadable: config/initializers/ reach into lib/ at boot
    # (DurableAssistants::Glitchtip, ::Telemetry), and only the once-autoloader is
    # ready that early.
    config.autoload_lib_once(ignore: %w[assets tasks])

    # No variants, ever: without this every boot warns that the
    # image_processing gem is missing.
    config.active_storage.variant_processor = :disabled

    # Every service's configuration, read once here rather than in one-line
    # initializers (those load too late and in alphabetical order). Values are
    # read in the YAML with Rails.app.creds.option: ENV under SERVICE__KEY,
    # then encrypted credentials. config/environments/*.rb loads after this,
    # so an environment may override any of it.
    config.x.app = config_for(:app)
    config.x.glitchtip = config_for(:glitchtip)
    config.x.oidc = config_for(:oidc)
    config.x.analytics = config_for(:analytics)
    config.x.pi_durable = config_for(:pi_durable)
    config.x.access = config_for(:access)
    config.x.connectors = config_for(:connectors)
    config.x.concourse = config_for(:concourse)
    config.x.passbolt = config_for(:passbolt)
    config.x.mail = config_for(:mail)
    config.x.campfire = config_for(:campfire)
    # The install's own connectors, in a file it adds to its image beside its
    # starter agent; the template has none (docs/connectors.md).
    config.x.install_connectors = Rails.root.join("config/install_connectors.yml").exist? ? config_for(:install_connectors) : {}

    # Falcon serves each request on a fiber, and the job workers run fibers
    # too (config/queue.yml), so per-request state is per fiber everywhere.
    config.active_support.isolation_level = :fiber
  end
end
