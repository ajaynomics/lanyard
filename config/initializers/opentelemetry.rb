# frozen_string_literal: true

# Traces go to the shared homeserver observability cell. That collector is a
# pass-through transport for every adopting app, so any never-emit policy this
# app has is enforced here, app-side, and never delegated to it.
return unless defined?(OpenTelemetry)

# No endpoint, no OpenTelemetry: installing instrumentation logs a line per
# library, and without a collector telemetry should change nothing.
return if ENV["OTEL_EXPORTER_OTLP_ENDPOINT"].blank?

require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "opentelemetry/instrumentation/all"

OpenTelemetry::SDK.configure do |c|
  # The Avery deploy files set OTEL_SERVICE_NAME and a destination resource
  # attribute (durable_assistants.destination=<name>; docs/deployments.md); the SDK merges
  # OTEL_RESOURCE_ATTRIBUTES into the default resource, and the keys named
  # here win on conflict. deployment.environment comes from
  # DEPLOYMENT_ENVIRONMENT rather than Rails.env, which is production on every
  # deployed host. service.version is what makes a trace attributable to a
  # deploy: Kamal sets KAMAL_VERSION on every container it runs.
  c.resource = OpenTelemetry::SDK::Resources::Resource.create(
    {
      "service.name" => ENV.fetch("OTEL_SERVICE_NAME", "ajent-durable_assistants"),
      "service.version" => DurableAssistants.revision,
      "deployment.environment" => ENV.fetch("DEPLOYMENT_ENVIRONMENT", Rails.env.to_s)
    }.compact
  )
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      DurableAssistants::Telemetry::Exporter.new(OpenTelemetry::Exporter::OTLP::Exporter.new)
    )
  )
  # Instrument requests, jobs and outbound HTTP, then restrict the export above.
  # Empty header lists alone do not prevent raw URL queries from being recorded.
  DurableAssistants::Telemetry::INSTRUMENTATIONS.each do |name, options|
    c.use name, options
  end
end
